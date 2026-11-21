//! Bounded operations over any Io: a native batch where supported, else
//! an operation raced against a timer. Both tasks end before storage leaves.
const std = @import("std");
const Io = std.Io;

pub const Error = Io.Cancelable || Io.ConcurrentError || error{Timeout};

/// A result completed before cancellation keeps its bytes, even when the
/// timer is delivered first. A Timeout leaves no operation holding storage.
pub fn operate(io: Io, operation: Io.Operation, timeout: Io.Timeout) Error!Io.Operation.Result {
    if (timeout == .none) return io.operate(operation);
    const deadline = timeout.toDeadline(io);
    return io.operateTimeout(operation, deadline) catch |err| switch (err) {
        error.ConcurrencyUnavailable => race(io, operation, deadline),
        else => |e| e,
    };
}

/// `operation` raced against `deadline` on any `Io`: the operation runs in
/// a task of its own, and a deadline that comes first cancels it through
/// the `Io`'s own cancel, which ends a wait on any handle (a datagram
/// socket's receive as well as a stream's read) without touching the
/// handle.
pub fn race(io: Io, operation: Io.Operation, deadline: Io.Timeout) Error!Io.Operation.Result {
    const Result = union(enum) { completed: Io.Cancelable!Io.Operation.Result, expired: Io.Cancelable!void };
    var storage: [2]Result = undefined;
    var select: Io.Select(Result) = .init(io, &storage);
    defer while (select.cancel()) |_| {};
    try select.concurrent(.expired, Io.Timeout.sleep, .{ deadline, io });
    // Reserve the timer first: failure to start the operation cannot
    // consume bytes and then report that no bounded operation was started.
    try select.concurrent(.completed, Io.operate, .{ io, operation });
    return switch (try select.await()) {
        .completed => |result| try canceledInside(try result),
        .expired => |result| expired: {
            try result;
            while (select.cancel()) |late| switch (late) {
                // A late operation that failed, or that the cancel ended with
                // nothing moved, gave no value: the timeout stands.
                .completed => |completed| {
                    const value = completed catch break :expired error.Timeout;
                    break :expired canceledInside(value) catch error.Timeout;
                },
                .expired => {},
            };
            break :expired error.Timeout;
        },
    };
}

/// `result`, with a cancel the `Io` reports inside it read as the cancel it
/// is. Windows' `Io.Threaded` gives a canceled datagram receive or send as
/// `.{ error.Canceled, n }` in the result, where POSIX's returns
/// `error.Canceled`: with nothing moved it is `error.Canceled`, and after
/// some messages moved it keeps their count, as POSIX's send does.
fn canceledInside(result: Io.Operation.Result) Io.Cancelable!Io.Operation.Result {
    switch (result) {
        inline .net_receive, .net_send => |moved, tag| if (moved[0]) |err| if (err == error.Canceled) {
            if (moved[1] == 0) return error.Canceled;
            return @unionInit(Io.Operation.Result, @tagName(tag), .{ null, moved[1] });
        },
        else => {},
    }
    return result;
}
