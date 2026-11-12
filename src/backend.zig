//! The kernel's completion engines behind one interface: `submit`,
//! `cancel`, the batch hooks, `poll` (which delivers to a sink), `wake`
//! and `handle`. The loop dispatches on the union; backends never import
//! one another (epoll and kqueue share the readiness core, which imports
//! neither).
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const op = @import("backend/op.zig");
pub const pending = @import("backend/pending.zig");
pub const Wait = @import("backend/wait.zig").Wait;
pub const Custom = @import("backend/Custom.zig");

const has_uring = op.has_uring;
const uring_file = @import("backend/Uring.zig");
pub const Uring = if (has_uring) uring_file else void;

pub const readiness = @import("backend/readiness.zig");
const epoll_poller = @import("backend/readiness/Epoll.zig");
const kqueue_poller = @import("backend/readiness/Kqueue.zig");
const has_epoll = op.has_epoll;
pub const Epoll = if (has_epoll) readiness.Readiness(epoll_poller) else void;
const has_kqueue = op.has_kqueue;
pub const Kqueue = if (has_kqueue) readiness.Readiness(kqueue_poller) else void;

const has_iocp = op.has_iocp;
const iocp_file = @import("backend/Iocp.zig");
pub const Iocp = if (has_iocp) iocp_file else void;

/// The kernel mechanisms a loop can run on.
pub const Kind = enum { io_uring, epoll, kqueue, iocp };

pub const SubmitError = error{ SystemResources, Unexpected };
pub const PollError = error{ SystemResources, Unexpected };

pub const Backend = union(enum) {
    /// Absent (void) where the system has no io_uring.
    io_uring: if (has_uring) *Uring else void,
    /// Absent where the system has no epoll.
    iocp: if (has_iocp) *Iocp else void,
    epoll: if (has_epoll) *Epoll else void,
    /// Absent where the system has no kqueue.
    kqueue: if (has_kqueue) *Kqueue else void,
    custom: *Custom,

    pub fn kind(b: *const Backend) ?Kind {
        return switch (b.*) {
            .io_uring => .io_uring,
            .iocp => .iocp,
            .epoll => .epoll,
            .kqueue => .kqueue,
            .custom => null,
        };
    }

    pub fn deinit(b: *Backend, gpa: Allocator) void {
        switch (b.*) {
            .io_uring => |u| if (has_uring) {
                u.deinit(gpa);
                gpa.destroy(u);
            },
            .epoll => |e| if (has_epoll) {
                e.deinit();
                gpa.destroy(e);
            },
            .kqueue => |k| if (has_kqueue) {
                k.deinit();
                gpa.destroy(k);
            },
            .iocp => |w| if (has_iocp) {
                w.deinit(gpa);
                gpa.destroy(w);
            },
            .custom => {},
        }
        b.* = undefined;
    }

    /// Hands `o` to the kernel. Its completion reaches the
    /// sink of a later `poll`, unless this returns true: a readiness
    /// backend found it complete at once, its result set.
    pub fn submit(b: *Backend, o: *op.Op) SubmitError!bool {
        switch (b.*) {
            .io_uring => |u| if (has_uring) return u.submit(o) else unreachable, // unreachable: no such backend here
            .epoll => |e| return if (has_epoll) e.submit(o) else unreachable, // unreachable: no such backend here
            .kqueue => |k| return if (has_kqueue) k.submit(o) else unreachable, // unreachable: no such backend here
            .iocp => |w| if (has_iocp) return w.submit(o) else unreachable, // unreachable: no such backend here
            .custom => |c| try c.vtable.submit(c, o),
        }
        return false;
    }

    /// Asks the kernel to end `o`; its completion still arrives.
    pub fn cancel(b: *Backend, o: *op.Op) bool {
        switch (b.*) {
            .io_uring => |u| if (has_uring) u.cancel(o) else unreachable, // unreachable: no such backend here
            .epoll => |e| if (has_epoll) e.cancel(o) else unreachable, // unreachable: no such backend here
            .kqueue => |k| if (has_kqueue) k.cancel(o) else unreachable, // unreachable: no such backend here
            .iocp => |w| if (has_iocp) return w.cancel(o) else unreachable, // unreachable: no such backend here
            .custom => |c| c.vtable.cancel(c, o),
        }
        return false;
    }

    /// Whether a batch's `operation` can wait in this kernel queue; the
    /// rest run as std's own code.
    pub fn canPend(b: *const Backend, operation: Io.Operation) bool {
        return switch (b.*) {
            .iocp => if (has_iocp) Iocp.canPend(operation) else unreachable, // unreachable: no such backend here
            .io_uring, .epoll, .kqueue, .custom => operation != .device_io_control,
        };
    }

    /// A batch's operation, kept packed in its storage (see `pending`);
    /// its completion comes back to the sink under `token`.
    pub fn submitPending(b: *Backend, token: pending.Token, operation: Io.Operation) SubmitError!?pending.Outcome {
        switch (b.*) {
            .io_uring => |u| if (has_uring) try u.submitPending(token, operation) else unreachable, // unreachable: no such backend here
            .epoll => |e| if (has_epoll) try e.submitPending(token, operation) else unreachable, // unreachable: no such backend here
            .kqueue => |k| if (has_kqueue) try k.submitPending(token, operation) else unreachable, // unreachable: no such backend here
            .iocp => |w| if (has_iocp) return w.submitPending(token, operation) else unreachable, // unreachable: no such backend here
            .custom => |c| try c.vtable.submitPending(c, token, operation),
        }
        return null;
    }

    pub fn cancelPending(b: *Backend, token: pending.Token) void {
        switch (b.*) {
            .io_uring => |u| if (has_uring) u.cancelPending(token) else unreachable, // unreachable: no such backend here
            .epoll => |e| if (has_epoll) e.cancelPending(token) else unreachable, // unreachable: no such backend here
            .kqueue => |k| if (has_kqueue) k.cancelPending(token) else unreachable, // unreachable: no such backend here
            .iocp => |w| if (has_iocp) w.cancelPending(token) else unreachable, // unreachable: no such backend here
            .custom => |c| c.vtable.cancelPending(c, token),
        }
    }

    /// Submits what is queued and delivers completions to `sink`
    /// (`complete(*Loop.Op)`, `completePending(pending.Token, pending.Outcome)`),
    /// waiting as `wait` allows; a `wake` ends the wait.
    pub fn poll(b: *Backend, wait: Wait, sink: anytype) PollError!void {
        switch (b.*) {
            .io_uring => |u| if (has_uring) try u.poll(wait, sink) else unreachable, // unreachable: no such backend here
            .epoll => |e| if (has_epoll) try e.poll(wait, sink) else unreachable, // unreachable: no such backend here
            .kqueue => |k| if (has_kqueue) try k.poll(wait, sink) else unreachable, // unreachable: no such backend here
            .iocp => |w| if (has_iocp) try w.poll(wait, sink) else unreachable, // unreachable: no such backend here
            .custom => |c| {
                var adapter: CustomSink(@TypeOf(sink)) = .{ .inner = sink };
                c.vtable.poll(c, wait, &adapter.sink);
            },
        }
    }

    /// From any thread.
    pub fn wake(b: *Backend) void {
        switch (b.*) {
            .io_uring => |u| if (has_uring) u.wake() else unreachable, // unreachable: no such backend here
            .epoll => |e| if (has_epoll) e.wake() else unreachable, // unreachable: no such backend here
            .kqueue => |k| if (has_kqueue) k.wake() else unreachable, // unreachable: no such backend here
            .iocp => |w| if (has_iocp) w.wake() else unreachable, // unreachable: no such backend here
            .custom => |c| c.vtable.wake(c),
        }
    }

    /// Completions a readiness backend made outside a poll, which the next
    /// poll delivers without waiting.
    pub fn hasCompletions(b: *const Backend) bool {
        return switch (b.*) {
            .epoll => |e| if (has_epoll) e.hasCompletions() else unreachable, // unreachable: no such backend here
            .kqueue => |k| if (has_kqueue) k.hasCompletions() else unreachable, // unreachable: no such backend here
            .io_uring => |u| if (builtin.os.tag == .linux) u.deferred_count != 0 or @atomicLoad(u32, u.ring.cq.tail, .acquire) != @atomicLoad(u32, u.ring.cq.head, .monotonic) else false,
            .iocp, .custom => false,
        };
    }

    /// A descriptor that is readable when `poll` has work, for a host's own
    /// poller; null for a custom backend.
    pub fn handle(b: *Backend) error{ SystemResources, Unexpected }!?Io.File.Handle {
        return switch (b.*) {
            .io_uring => |u| if (has_uring) try u.handle() else unreachable, // unreachable: no such backend here
            .epoll => |e| if (has_epoll) e.handle() else unreachable, // unreachable: no such backend here
            .kqueue => |k| if (has_kqueue) k.handle() else unreachable, // unreachable: no such backend here
            .iocp => |w| if (has_iocp) w.waitHandle() else unreachable, // unreachable: no such backend here
            .custom => null,
        };
    }
};

/// The sink a custom backend delivers to, over the loop's own.
fn CustomSink(comptime SinkPtr: type) type {
    return struct {
        sink: Custom.Sink = .{ .complete = complete, .completePending = completePending },
        inner: SinkPtr,

        fn complete(s: *Custom.Sink, o: *op.Op) void {
            const adapter: *@This() = @alignCast(@fieldParentPtr("sink", s)); // safe: the field belongs to this record
            adapter.inner.complete(o);
        }

        fn completePending(s: *Custom.Sink, token: pending.Token, outcome: pending.Outcome) void {
            const adapter: *@This() = @alignCast(@fieldParentPtr("sink", s)); // safe: the field belongs to this record
            adapter.inner.completePending(token, outcome);
        }
    };
}
