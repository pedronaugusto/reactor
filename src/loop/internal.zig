//! What reactor's runtime does to a loop beyond its public interface:
//! build one over a given backend and clock, and hand a batch's
//! operations to its backend.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;

const Loop = @import("../Loop.zig");
const backend = @import("../backend.zig");
const clock = @import("../clock.zig");

/// A loop over `b` and `source`: the runtime's tests give it the seeded
/// fake and a virtual clock.
pub fn initWith(l: *Loop, b: backend.Backend, source: clock.Source, max_ops: u32) void {
    l.* = .{
        .backend = b,
        .clock = source,
        .wheel = .init(source.ticks()),
        .max_ops = max_ops,
        .owner = std.Thread.getCurrentId(),
    };
}

/// Where the loop's batch completions go.
pub fn setBatchSink(l: *Loop, sink: Loop.BatchSink) void {
    l.batch_sink = sink;
}

/// Whether a batch's `operation` can wait in this loop's kernel queue;
/// the rest run as std's own code.
pub fn canPend(l: *const Loop, operation: Io.Operation) bool {
    return l.backend.canPend(operation);
}

/// One operation of a batch, kept in the batch's own storage: null while
/// the kernel holds it, else its outcome, which it had at once.
pub fn submitPending(l: *Loop, token: backend.pending.Token, operation: Io.Operation) backend.SubmitError!?backend.pending.Outcome {
    if (l.in_flight == l.max_ops) return error.SystemResources;
    const outcome = try l.backend.submitPending(token, operation);
    if (outcome == null) l.in_flight += 1;
    return outcome;
}

/// An operation `submit` finished at once, taken back before delivery:
/// its result is the caller's now and no callback runs for it. False when
/// it is under way, or not first in line for delivery.
pub fn takeCompleted(l: *Loop, o: *Loop.Op) bool {
    if (o.state.phase != .done or l.ready.head != o) return false;
    l.ready.head = @ptrCast(@alignCast(o.state.next)); // safe: the ready list links `*Op`s only
    if (l.ready.head == null) l.ready.tail = null;
    o.state.next = null;
    o.state.phase = .idle;
    l.in_flight -= 1;
    return true;
}

pub fn cancelPending(l: *Loop, token: backend.pending.Token) void {
    l.backend.cancelPending(token);
}

/// The caller owns source on this thread and retains both loops until all
/// source completions drain. The scheduler uses this only within one runtime;
/// independent runtimes use ordinary wake, which retains no target pointer.
pub fn wakeFrom(l: *Loop, source: *Loop) void {
    l.woken.store(true, .release);
    if (comptime builtin.os.tag == .linux) if (source != l and source.backend == .io_uring and l.backend == .io_uring) {
        if (source.backend.io_uring.messageWake(l.backend.io_uring)) return;
    };
    l.backend.wake();
}
