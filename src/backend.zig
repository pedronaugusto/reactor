//! The kernel's completion engines behind one interface: `submit`,
//! `cancel`, the batch hooks, `poll` (which delivers to a sink), `wake`
//! and `handle`. The loop dispatches on the union; backends never import
//! one another (epoll and kqueue share the readiness core, which imports
//! neither).
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

pub const readiness = @import("backend/readiness.zig");
const epoll_poller = @import("backend/readiness/Epoll.zig");
const kqueue_poller = @import("backend/readiness/Kqueue.zig");
const has_epoll = builtin.os.tag == .linux;
pub const Epoll = if (has_epoll) readiness.Readiness(epoll_poller) else void;
const has_kqueue = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};
pub const Kqueue = if (has_kqueue) readiness.Readiness(kqueue_poller) else void;

/// The kernel mechanisms a loop can run on.
pub const Kind = enum { io_uring, epoll, kqueue, iocp };

pub const SubmitError = error{ SystemResources, Unexpected };
pub const PollError = error{ SystemResources, Unexpected };

/// What an operation keeps for its backend while the kernel holds it.
pub const Scratch = union {
    custom: Custom.Scratch,
    io_uring: if (has_uring) Uring.Scratch else void,
    epoll: if (has_epoll) Epoll.Scratch else void,
    kqueue: if (has_kqueue) Kqueue.Scratch else void,
};

pub const Backend = union(enum) {
    /// Absent (void) where the system has no io_uring.
    io_uring: Uring,
    /// Absent where the system has no epoll.
    epoll: Epoll,
    /// Absent where the system has no kqueue.
    kqueue: Kqueue,
    custom: Custom,

    pub fn kind(b: *const Backend) ?Kind {
        return switch (b.*) {
            .io_uring => .io_uring,
            .epoll => .epoll,
            .kqueue => .kqueue,
            .custom => null,
        };
    }

    pub fn deinit(b: *Backend) void {
        switch (b.*) {
            .io_uring => |*u| if (has_uring) u.deinit(),
            .epoll => |*e| if (has_epoll) e.deinit(),
            .kqueue => |*k| if (has_kqueue) k.deinit(),
            .custom => {},
        }
        b.* = undefined;
    }

    /// Hands `o` (a `*Loop.Op`) to the kernel. Its completion reaches the
    /// sink of a later `poll`, unless this returns true: a readiness
    /// backend found it complete at once, its result set.
    pub fn submit(b: *Backend, o: anytype) SubmitError!bool {
        switch (b.*) {
            .io_uring => |*u| if (has_uring) try u.submit(o) else unreachable, // unreachable: no such backend here
            .epoll => |*e| return if (has_epoll) e.submit(o) else unreachable, // unreachable: no such backend here
            .kqueue => |*k| return if (has_kqueue) k.submit(o) else unreachable, // unreachable: no such backend here
            .custom => |c| c.vtable.submit(c.context, o),
        }
        return false;
    }

    /// Asks the kernel to end `o`; its completion still arrives.
    pub fn cancel(b: *Backend, o: anytype) void {
        switch (b.*) {
            .io_uring => |*u| if (has_uring) u.cancel(o) else unreachable, // unreachable: no such backend here
            .epoll => |*e| if (has_epoll) e.cancel(o) else unreachable, // unreachable: no such backend here
            .kqueue => |*k| if (has_kqueue) k.cancel(o) else unreachable, // unreachable: no such backend here
            .custom => |c| c.vtable.cancel(c.context, o),
        }
    }

    /// A batch's operation, kept packed in its storage (see `pending`);
    /// its completion comes back to the sink under `token`.
    pub fn submitPending(b: *Backend, token: pending.Token, operation: Io.Operation) SubmitError!void {
        switch (b.*) {
            .io_uring => |*u| if (has_uring) try u.submitPending(token, operation) else unreachable, // unreachable: no such backend here
            .epoll => |*e| if (has_epoll) try e.submitPending(token, operation) else unreachable, // unreachable: no such backend here
            .kqueue => |*k| if (has_kqueue) try k.submitPending(token, operation) else unreachable, // unreachable: no such backend here
            .custom => |c| c.vtable.submitPending(c.context, token, operation),
        }
    }

    pub fn cancelPending(b: *Backend, token: pending.Token) void {
        switch (b.*) {
            .io_uring => |*u| if (has_uring) u.cancelPending(token) else unreachable, // unreachable: no such backend here
            .epoll => |*e| if (has_epoll) e.cancelPending(token) else unreachable, // unreachable: no such backend here
            .kqueue => |*k| if (has_kqueue) k.cancelPending(token) else unreachable, // unreachable: no such backend here
            .custom => |c| c.vtable.cancelPending(c.context, token),
        }
    }

    /// Submits what is queued and delivers completions to `sink`
    /// (`complete(*Loop.Op)`, `completePending(pending.Token, pending.Outcome)`),
    /// waiting as `wait` allows; a `wake` ends the wait.
    pub fn poll(b: *Backend, wait: Wait, sink: anytype) PollError!void {
        switch (b.*) {
            .io_uring => |*u| if (has_uring) try u.poll(wait, sink) else unreachable, // unreachable: no such backend here
            .epoll => |*e| if (has_epoll) try e.poll(wait, sink) else unreachable, // unreachable: no such backend here
            .kqueue => |*k| if (has_kqueue) try k.poll(wait, sink) else unreachable, // unreachable: no such backend here
            .custom => |c| c.vtable.poll(c.context, wait, CustomSink(@TypeOf(sink)).of(sink)),
        }
    }

    /// From any thread.
    pub fn wake(b: *Backend) void {
        switch (b.*) {
            .io_uring => |*u| if (has_uring) u.wake() else unreachable, // unreachable: no such backend here
            .epoll => |*e| if (has_epoll) e.wake() else unreachable, // unreachable: no such backend here
            .kqueue => |*k| if (has_kqueue) k.wake() else unreachable, // unreachable: no such backend here
            .custom => |c| c.vtable.wake(c.context),
        }
    }

    /// Completions a readiness backend made outside a poll, which the next
    /// poll delivers without waiting.
    pub fn hasCompletions(b: *const Backend) bool {
        return switch (b.*) {
            .epoll => |*e| if (has_epoll) e.hasCompletions() else unreachable, // unreachable: no such backend here
            .kqueue => |*k| if (has_kqueue) k.hasCompletions() else unreachable, // unreachable: no such backend here
            .io_uring, .custom => false,
        };
    }

    /// A descriptor that is readable when `poll` has work, for a host's own
    /// poller; null for a custom backend.
    pub fn handle(b: *Backend) error{ SystemResources, Unexpected }!?Io.File.Handle {
        return switch (b.*) {
            .io_uring => |*u| if (has_uring) try u.handle() else unreachable, // unreachable: no such backend here
            .epoll => |*e| if (has_epoll) e.handle() else unreachable, // unreachable: no such backend here
            .kqueue => |*k| if (has_kqueue) k.handle() else unreachable, // unreachable: no such backend here
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
