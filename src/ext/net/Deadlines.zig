//! An operation on a socket or a named pipe ended at its deadline, on any
//! `Io`: one call, `operate`, on the target's `Watch`.
//!
//! On a runtime each operation carries its own deadline into the kernel
//! (`operateTimeout`, which never returns while the kernel holds the
//! buffer). Any other `Io` cannot always bound an operation itself
//! (`Io.Threaded` refuses a timed read or write on Windows, and on POSIX a
//! timed write waits only for the socket to take bytes, then blocks in
//! `sendmsg` while the peer keeps its window shut), so there the operation
//! runs in a task of its own, raced against its deadline, and a deadline
//! that comes first ends it by the `Io`'s own cancel: a signal that breaks
//! the blocked call on POSIX, the pending request canceled on Windows. That
//! ends a wait on any socket, a datagram socket's receive as well as a
//! stream's read, where a shutdown ends only a connection's, and a pipe's
//! read as well. With no task to spare, the `Io` bounds the operation where
//! it can, and where it cannot (`Io.Threaded` on Windows) a stream socket's
//! read or write is bounded on the calling thread (`bounded.zig`).
//!
//! Either way a deadline that fires poisons the target: every later
//! operation on it reports the deadline, and a socket's connection is shut
//! down (`abort`) so its peer sees it ended too.
const std = @import("std");
const Io = std.Io;

const native = @import("../native.zig");
const abort = @import("abort.zig").abort;
const timeout = @import("../../ops/timeout.zig");
const bounded = @import("bounded.zig");
const Raised = @import("../../sync/Raised.zig");

/// One socket's or named pipe's operations under deadlines: whether one
/// fired. It owns nothing: the target is named by its handle.
pub const Watch = struct {
    target: Target,
    /// Raised once a deadline fired: the target is poisoned.
    fired: Raised = .{},

    /// What the operations are on.
    pub const Target = union(enum) {
        socket: Io.net.Socket.Handle,
        /// A named pipe, Windows'.
        pipe: Io.File.Handle,
    };

    pub fn init(socket: Io.net.Socket.Handle) Watch {
        return .{ .target = .{ .socket = socket } };
    }

    pub fn initPipe(pipe: Io.File) Watch {
        return .{ .target = .{ .pipe = pipe.handle } };
    }

    /// Poisons the target once its deadline fired: a socket's connection
    /// is shut down; a pipe's is left to `fired`, which refuses the
    /// operations after.
    fn end(w: *const Watch, io: Io) void {
        switch (w.target) {
            .socket => |socket| abort(io, socket),
            .pipe => {},
        }
    }

    /// The deadline fired: the target poisoned and ended.
    fn expire(w: *Watch, io: Io) error{Timeout} {
        _ = w.fired.raise(.acq_rel);
        w.end(io);
        return error.Timeout;
    }
};

/// `Timeout` when the deadline ended the operation, or one fired before on
/// the target. `ConcurrencyUnavailable` off a runtime when no task could be
/// had to run the operation in and it is none the calling thread can bound:
/// it was not started.
pub const OperateError = Io.Cancelable || error{ Timeout, ConcurrencyUnavailable };

/// One operation on `w`'s target, ended at `deadline`: `Timeout` when the
/// deadline ended it, else its result. A result the operation reached
/// before the deadline is returned even when the deadline fired, though
/// the target is poisoned then.
///
/// Off a runtime it races the operation in a task of its own. With no task
/// to be had, the `Io` bounds it where it can (`operateTimeout`, a write
/// sent a piece at a time, and so short), and where it cannot, a stream
/// socket's read or write is bounded on the calling thread (`bounded.zig`).
/// Anything else (a datagram send, a pipe's operation the `Io` cannot
/// bound) returns `ConcurrencyUnavailable` before it starts, never run
/// unbounded.
pub fn operate(io: Io, w: *Watch, operation: Io.Operation, deadline: Io.Clock.Timestamp) OperateError!Io.Operation.Result {
    if (w.fired.raised(.acquire)) return error.Timeout;
    if (native.runtimeOf(io) != null) {
        return io.operateTimeout(operation, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Canceled => error.Canceled,
            // Device control has no evented form: unbounded, as std's.
            error.ConcurrencyUnavailable => io.operate(operation),
            error.Timeout => {
                return w.expire(io);
            },
        };
    }
    return timeout.race(io, operation, .{ .deadline = deadline }) catch |err| switch (err) {
        error.Canceled => error.Canceled,
        error.ConcurrencyUnavailable => alone(io, w, operation, deadline),
        error.Timeout => w.expire(io),
    };
}

/// The most a write sends with no task to race it in, where the `Io`
/// bounds it: a socket reported writable takes this much at once on every
/// system reactor targets (at least `SO_SNDLOWAT`'s 2048 bytes on Darwin
/// and the BSDs; on Linux one segment, which a send that saw room is never
/// held for), so the send after the wait cannot block.
const alone_write_max = 1024;

/// `operation` with no task to race it in: bounded by the `Io` itself
/// (`operateTimeout`, a write capped at `alone_write_max`), which keeps an
/// `Io` that is no system's (a simulation) to its own sockets; where the
/// `Io` cannot (`Io.Threaded` on Windows), a stream socket's operation is
/// bounded on the calling thread (`bounded.zig`).
fn alone(io: Io, w: *Watch, operation: Io.Operation, deadline: Io.Clock.Timestamp) OperateError!Io.Operation.Result {
    var first: [1][]const u8 = undefined;
    const asked: Io.Operation = switch (operation) {
        .net_write => |o| capped: {
            first[0] = bounded.firstChunk(o);
            first[0] = first[0][0..@min(first[0].len, alone_write_max)];
            break :capped .{ .net_write = .{ .socket_handle = o.socket_handle, .data = &first, .control = o.control } };
        },
        else => operation,
    };
    if (io.operateTimeout(asked, .{ .deadline = deadline })) |result| return result else |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Timeout => return w.expire(io),
        error.ConcurrencyUnavailable => {},
    }
    return switch (w.target) {
        .socket => |socket| bounded.operate(io, socket, operation, deadline) catch |err| switch (err) {
            error.Canceled => error.Canceled,
            error.ConcurrencyUnavailable => error.ConcurrencyUnavailable,
            error.Timeout => w.expire(io),
        },
        .pipe => error.ConcurrencyUnavailable,
    };
}
