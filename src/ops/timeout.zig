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

fn race(io: Io, operation: Io.Operation, deadline: Io.Timeout) Error!Io.Operation.Result {
    const Result = union(enum) { completed: Io.Cancelable!Io.Operation.Result, expired: Io.Cancelable!void };
    var storage: [2]Result = undefined;
    var select: Io.Select(Result) = .init(io, &storage);
    defer while (select.cancel()) |_| {};
    try select.concurrent(.expired, Io.Timeout.sleep, .{ deadline, io });
    // Reserve the timer first: failure to start the operation cannot
    // consume bytes and then report that no bounded operation was started.
    try select.concurrent(.completed, Io.operate, .{ io, operation });
    return switch (try select.await()) {
        .completed => |result| result,
        .expired => |result| expired: {
            try result;
            while (select.cancel()) |late| switch (late) {
                .completed => |completed| if (completed) |value| break :expired value else |_| {},
                .expired => {},
            };
            break :expired error.Timeout;
        },
    };
}
