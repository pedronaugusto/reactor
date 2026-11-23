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
//! read as well. With no task to spare, a stream socket's read or write is
//! bounded on the calling thread instead (`bounded.zig`).
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
/// to be had, a stream socket's read or write is bounded on the calling
/// thread (`bounded.zig`): a read waits for the socket to be readable until
/// the deadline, a write sends what the socket takes without waiting, and
/// may be short. Anything else (a datagram send, a pipe's operation)
/// returns `ConcurrencyUnavailable` before it starts, never run unbounded.
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
        // No task to race it in: a stream socket's read or write is bounded
        // on the calling thread instead.
        error.ConcurrencyUnavailable => switch (w.target) {
            .socket => |socket| bounded.operate(io, socket, operation, deadline) catch |e| switch (e) {
                error.Canceled => error.Canceled,
                error.ConcurrencyUnavailable => error.ConcurrencyUnavailable,
                error.Timeout => w.expire(io),
            },
            .pipe => error.ConcurrencyUnavailable,
        },
        error.Timeout => w.expire(io),
    };
}
