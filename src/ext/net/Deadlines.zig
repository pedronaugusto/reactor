//! Per-operation deadlines over many sockets, on any `Io`.
//!
//! On a runtime each operation carries its own deadline into the kernel
//! (`operateTimeout`, which never returns while the kernel holds the
//! buffer). Any other `Io` cannot always bound a socket operation itself
//! (`Io.Threaded` refuses a timed read or write on Windows, and on POSIX a
//! timed write waits only for the socket to take bytes, then blocks in
//! `sendmsg` while the peer keeps its window shut), so there the operation
//! runs in a task of its own, raced against its deadline, and a deadline
//! that comes first ends it by the `Io`'s own cancel: a signal that breaks
//! the blocked call on POSIX, the pending request canceled on Windows. That
//! ends a wait on any socket, a datagram socket's receive as well as a
//! stream's read, where a shutdown ends only a connection's.
//!
//! Either way a deadline that fires poisons the socket: every later
//! operation on it reports the deadline, and a connection is shut down
//! (`abort`) so its peer sees it ended too.
const Deadlines = @This();

const std = @import("std");
const Io = std.Io;

const native = @import("../native.zig");
const abort = @import("abort.zig").abort;
const timeout = @import("../../ops/timeout.zig");
const Raised = @import("../../sync/Raised.zig");

/// One socket's or named pipe's operation deadline.
pub const Watch = struct {
    target: Target,
    /// Raised once a deadline fired: the socket is poisoned.
    fired: Raised = .{},

    /// What the operations are on.
    pub const Target = union(enum) {
        socket: Io.net.Socket.Handle,
        /// A named pipe, Windows': its deadlines are kept on a runtime,
        /// where each operation carries its own; off one `add` refuses it.
        /// Named by its handle: the watch does not own the pipe.
        pipe: Io.File.Handle,
    };

    pub fn init(socket: Io.net.Socket.Handle) Watch {
        return .{ .target = .{ .socket = socket } };
    }

    pub fn initPipe(pipe: Io.File) Watch {
        return .{ .target = .{ .pipe = pipe.handle } };
    }

    /// Poisons the target once its deadline fired: a socket's connection
    /// is shut down; a pipe's operation was ended by its own deadline, and
    /// `fired` refuses the ones after it.
    fn end(w: *const Watch, io: Io) void {
        switch (w.target) {
            .socket => |socket| abort(io, socket),
            .pipe => {},
        }
    }
};

/// Deadlines no shorter than `shortest`, which nothing needs any more:
/// each operation ends at its own.
pub fn init(shortest: Io.Duration) Deadlines {
    _ = shortest;
    return .{};
}

/// Nothing to do: each operation ends at its own deadline.
pub fn tighten(d: *Deadlines, io: Io, shorter: Io.Duration) void {
    _ = .{ d, io, shorter };
}

pub fn deinit(d: *Deadlines, io: Io) void {
    _ = io;
    d.* = undefined;
}

/// Watches `w`. False when `w` is a pipe's off a runtime: std's own wait
/// on an overlapped call is not one a race can end, and its operations run
/// unbounded.
pub fn add(d: *Deadlines, io: Io, w: *Watch) bool {
    _ = d;
    return native.runtimeOf(io) != null or w.target != .pipe;
}

/// Stops watching `w`, which has no operation under way.
pub fn remove(d: *Deadlines, io: Io, w: *Watch) void {
    _ = .{ d, io, w };
}

/// `Timeout` when the deadline ended the operation; `ConcurrencyUnavailable`
/// off a runtime when no task could be had to run it in, and it was not
/// started.
pub const OperateError = Io.Cancelable || error{ Timeout, ConcurrencyUnavailable };

/// One operation on `w`'s socket, ended at `deadline`: `Timeout` when the
/// deadline ended it, else its result. A result the operation reached
/// before the deadline is returned even when the deadline fired, though
/// the socket is aborted then.
pub fn operate(d: *Deadlines, io: Io, w: *Watch, operation: Io.Operation, deadline: Io.Clock.Timestamp) OperateError!Io.Operation.Result {
    if (w.fired.raised(.acquire)) return error.Timeout;
    if (native.runtimeOf(io) != null) {
        return io.operateTimeout(operation, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Canceled => error.Canceled,
            // Device control has no evented form: unbounded, as std's.
            error.ConcurrencyUnavailable => io.operate(operation),
            error.Timeout => {
                _ = w.fired.raise(.acq_rel);
                w.end(io);
                return error.Timeout;
            },
        };
    }
    // A pipe's operation off a runtime runs unbounded, as `add` said.
    if (w.target == .pipe) return io.operate(operation);
    _ = d;
    // The operation in a task of its own, ended at the deadline by the
    // `Io`'s cancel: a wait on any socket ends so, a datagram socket's
    // receive too, which no shutdown can end.
    return timeout.race(io, operation, .{ .deadline = deadline }) catch |err| switch (err) {
        error.Canceled => error.Canceled,
        error.ConcurrencyUnavailable => error.ConcurrencyUnavailable,
        error.Timeout => {
            _ = w.fired.raise(.acq_rel);
            w.end(io);
            return error.Timeout;
        },
    };
}
