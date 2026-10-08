//! The kernel's completion engines behind one interface: `submit`,
//! `cancel`, the batch hooks, `poll` (which delivers to a sink), `wake`
//! and `handle`. The loop dispatches on the union; backends never import
//! one another.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;

pub const op = @import("backend/op.zig");
pub const pending = @import("backend/pending.zig");
pub const Wait = @import("backend/wait.zig").Wait;
pub const Custom = @import("backend/Custom.zig");

const has_uring = builtin.os.tag == .linux;
const uring_file = @import("backend/Uring.zig");
pub const Uring = if (has_uring) uring_file else void;

/// The kernel mechanisms a loop can run on.
pub const Kind = enum { io_uring, epoll, kqueue, iocp };

pub const SubmitError = error{ SystemResources, Unexpected };
pub const PollError = error{ SystemResources, Unexpected };

/// What an operation keeps for its backend while the kernel holds it.
pub const Scratch = union {
    custom: Custom.Scratch,
    io_uring: if (has_uring) Uring.Scratch else void,
};

pub const Backend = union(enum) {
    /// Absent (void) where the system has no io_uring.
    io_uring: Uring,
    custom: Custom,

    pub fn kind(b: *const Backend) ?Kind {
        return switch (b.*) {
            .io_uring => .io_uring,
            .custom => null,
        };
    }

    pub fn deinit(b: *Backend, gpa: std.mem.Allocator) void {
        switch (b.*) {
            .io_uring => |*u| if (has_uring) u.deinit(gpa),
            .custom => {},
        }
        b.* = undefined;
    }

    /// Hands `o` (a `*Loop.Op`) to the kernel. Its completion reaches the
    /// sink of a later `poll`.
    pub fn submit(b: *Backend, o: anytype) SubmitError!void {
        switch (b.*) {
            .io_uring => |*u| if (has_uring) try u.submit(o) else unreachable, // unreachable: no such backend here
            .custom => |c| c.vtable.submit(c.context, o),
        }
    }

    /// Asks the kernel to end `o`; its completion still arrives.
    pub fn cancel(b: *Backend, o: anytype) void {
        switch (b.*) {
            .io_uring => |*u| if (has_uring) u.cancel(o) else unreachable, // unreachable: no such backend here
            .custom => |c| c.vtable.cancel(c.context, o),
        }
    }

    /// A batch's operation, kept packed in its storage (see `pending`);
    /// its completion comes back to the sink under `token`.
    pub fn submitPending(b: *Backend, token: pending.Token, operation: Io.Operation) SubmitError!void {
        switch (b.*) {
            .io_uring => |*u| if (has_uring) try u.submitPending(token, operation) else unreachable, // unreachable: no such backend here
            .custom => |c| c.vtable.submitPending(c.context, token, operation),
        }
    }

    pub fn cancelPending(b: *Backend, token: pending.Token) void {
        switch (b.*) {
            .io_uring => |*u| if (has_uring) u.cancelPending(token) else unreachable, // unreachable: no such backend here
            .custom => |c| c.vtable.cancelPending(c.context, token),
        }
    }

    /// Submits what is queued and delivers completions to `sink`
    /// (`complete(*Loop.Op)`, `completePending(pending.Token, pending.Outcome)`),
    /// waiting as `wait` allows; a `wake` ends the wait.
    pub fn poll(b: *Backend, wait: Wait, sink: anytype) PollError!void {
        switch (b.*) {
            .io_uring => |*u| if (has_uring) try u.poll(wait, sink) else unreachable, // unreachable: no such backend here
            .custom => |c| c.vtable.poll(c.context, wait, CustomSink(@TypeOf(sink)).of(sink)),
        }
    }

    /// From any thread.
    pub fn wake(b: *Backend) void {
        switch (b.*) {
            .io_uring => |*u| if (has_uring) u.wake() else unreachable, // unreachable: no such backend here
            .custom => |c| c.vtable.wake(c.context),
        }
    }

    /// A descriptor that is readable when `poll` has work, for a host's own
    /// poller; null for a custom backend.
    pub fn handle(b: *Backend) error{ SystemResources, Unexpected }!?Io.File.Handle {
        return switch (b.*) {
            .io_uring => |*u| if (has_uring) try u.handle() else unreachable, // unreachable: no such backend here
            .custom => null,
        };
    }
};

/// The untyped sink a custom backend delivers to, over a typed one: the
/// loop, whose `complete` takes its own `*Op`.
fn CustomSink(comptime SinkPtr: type) type {
    const Sink = @typeInfo(SinkPtr).pointer.child;
    const op_pointer = @typeInfo(@TypeOf(Sink.complete)).@"fn".param_types[1].?;
    return struct {
        fn of(sink: SinkPtr) Custom.Sink {
            return .{ .context = sink, .complete = complete, .completePending = completePending };
        }

        fn complete(context: *anyopaque, o: *anyopaque) void {
            const sink: SinkPtr = @ptrCast(@alignCast(context)); // safe: `of` stored this sink
            sink.complete(@as(op_pointer, @ptrCast(@alignCast(o)))); // safe: a custom backend returns the ops it was given
        }

        fn completePending(context: *anyopaque, token: pending.Token, outcome: pending.Outcome) void {
            const sink: SinkPtr = @ptrCast(@alignCast(context)); // safe: `of` stored this sink
            sink.completePending(token, outcome);
        }
    };
}
