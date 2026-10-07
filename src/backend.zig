//! The kernel's completion engines behind one interface: `submit`,
//! `cancel`, the batch hooks, `poll` (which delivers to a sink), `wake`
//! and `handle`. The loop dispatches on the union; backends never import
//! one another.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const op = @import("backend/op.zig");
pub const pending = @import("backend/pending.zig");
pub const Wait = @import("backend/wait.zig").Wait;
pub const Custom = @import("backend/Custom.zig");

const has_uring = builtin.os.tag == .linux;
const uring_file = @import("backend/Uring.zig");
pub const Uring = if (has_uring) uring_file else void;

const has_iocp = builtin.os.tag == .windows;
const iocp_file = @import("backend/Iocp.zig");
pub const Iocp = if (has_iocp) iocp_file else void;

/// The kernel mechanisms a loop can run on.
pub const Kind = enum { io_uring, epoll, kqueue, iocp };

pub const SubmitError = error{ SystemResources, Unexpected };
pub const PollError = error{ SystemResources, Unexpected };

/// What an operation keeps for its backend while the kernel holds it.
pub const Scratch = union {
    custom: Custom.Scratch,
    io_uring: if (has_uring) Uring.Scratch else void,
    iocp: if (has_iocp) Iocp.Scratch else void,
};

pub const Backend = union(enum) {
    /// Absent (void) where the system has no io_uring.
    io_uring: Uring,
    /// Absent (void) off Windows.
    iocp: Iocp,
    custom: Custom,

    pub fn kind(b: *const Backend) ?Kind {
        return switch (b.*) {
            .io_uring => .io_uring,
            .iocp => .iocp,
            .custom => null,
        };
    }

    pub fn deinit(b: *Backend, gpa: Allocator) void {
        switch (b.*) {
            .io_uring => |*u| if (has_uring) u.deinit(),
            .iocp => |*w| if (has_iocp) w.deinit(gpa),
            .custom => {},
        }
        b.* = undefined;
    }

    /// Hands `o` (a `*Loop.Op`) to the kernel. True when it finished at
    /// once: its result is set and no completion follows. Otherwise its
    /// completion reaches the sink of a later `poll`.
    pub fn submit(b: *Backend, o: anytype) SubmitError!bool {
        switch (b.*) {
            .io_uring => |*u| if (has_uring) {
                try u.submit(o);
                return false;
            } else unreachable, // unreachable: no such backend here
            .iocp => |*w| if (has_iocp) return w.submit(o) else unreachable, // unreachable: no such backend here
            .custom => |c| {
                c.vtable.submit(c.context, o);
                return false;
            },
        }
    }

    /// Asks the kernel to end `o`; its completion still arrives, unless
    /// this returns true: it ended here, its result set.
    pub fn cancel(b: *Backend, o: anytype) bool {
        switch (b.*) {
            .io_uring => |*u| if (has_uring) u.cancel(o) else unreachable, // unreachable: no such backend here
            .iocp => |*w| if (has_iocp) return w.cancel(o) else unreachable, // unreachable: no such backend here
            .custom => |c| c.vtable.cancel(c.context, o),
        }
        return false;
    }

    /// Whether a batch's `operation` can wait in this kernel queue; the
    /// rest run as std's own code.
    pub fn canPend(b: *const Backend, operation: Io.Operation) bool {
        return switch (b.*) {
            .iocp => if (has_iocp) Iocp.canPend(operation) else unreachable, // unreachable: no such backend here
            .io_uring, .custom => operation != .device_io_control,
        };
    }

    /// A batch's operation, kept packed in its storage (see `pending`):
    /// null when the kernel holds it, its outcome reaching the sink under
    /// `token`; else its outcome now.
    pub fn submitPending(b: *Backend, token: pending.Token, operation: Io.Operation) SubmitError!?pending.Outcome {
        switch (b.*) {
            .io_uring => |*u| if (has_uring) try u.submitPending(token, operation) else unreachable, // unreachable: no such backend here
            .iocp => |*w| if (has_iocp) return w.submitPending(token, operation) else unreachable, // unreachable: no such backend here
            .custom => |c| c.vtable.submitPending(c.context, token, operation),
        }
        return null;
    }

    pub fn cancelPending(b: *Backend, token: pending.Token) void {
        switch (b.*) {
            .io_uring => |*u| if (has_uring) u.cancelPending(token) else unreachable, // unreachable: no such backend here
            .iocp => |*w| if (has_iocp) w.cancelPending(token) else unreachable, // unreachable: no such backend here
            .custom => |c| c.vtable.cancelPending(c.context, token),
        }
    }

    /// Submits what is queued and delivers completions to `sink`
    /// (`complete(*Loop.Op)`, `completePending(pending.Token, pending.Outcome)`),
    /// waiting as `wait` allows; a `wake` ends the wait.
    pub fn poll(b: *Backend, wait: Wait, sink: anytype) PollError!void {
        switch (b.*) {
            .io_uring => |*u| if (has_uring) try u.poll(wait, sink) else unreachable, // unreachable: no such backend here
            .iocp => |*w| if (has_iocp) try w.poll(wait, sink) else unreachable, // unreachable: no such backend here
            .custom => |c| c.vtable.poll(c.context, wait, CustomSink(@TypeOf(sink)).of(sink)),
        }
    }

    /// From any thread.
    pub fn wake(b: *Backend) void {
        switch (b.*) {
            .io_uring => |*u| if (has_uring) u.wake() else unreachable, // unreachable: no such backend here
            .iocp => |*w| if (has_iocp) w.wake() else unreachable, // unreachable: no such backend here
            .custom => |c| c.vtable.wake(c.context),
        }
    }

    /// What a host's own poller waits on for `poll`'s work: a descriptor
    /// that is readable (io_uring), or the port (IOCP); null for a custom
    /// backend.
    pub fn handle(b: *Backend) error{ SystemResources, Unexpected }!?Io.File.Handle {
        return switch (b.*) {
            .io_uring => |*u| if (has_uring) try u.handle() else unreachable, // unreachable: no such backend here
            .iocp => |*w| if (has_iocp) w.waitHandle() else unreachable, // unreachable: no such backend here
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
