//! A task: a stack, its saved context, and what scheduling and
//! cancellation need to know about it. The record lives at the top of the
//! task's own stack (the root's in the runtime), so a task costs no
//! allocation.
//!
//! Cancellation is std's: a request is made once in a task's life; the
//! next cancelation point that is not protected returns `error.Canceled`
//! and acknowledges it, which blocks later points until `recancel`. A task
//! parked in a cancelable wait publishes a hook in `wait`, guarded by the
//! lock bit of `cancel`; whoever requests the cancel runs the hook under
//! that lock, and the task clears it under the same lock when it resumes,
//! so a hook never runs on a frame that is gone.
const Task = @This();

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const clocks = @import("../clock.zig");
const fiber = @import("../fiber.zig");
const op = @import("../backend/op.zig");
const Stacks = @import("../fiber/Stacks.zig");
const Lanes = @import("../Lanes.zig");

/// Saved registers while the task is not running.
context: fiber.Context = undefined,
/// The one queue the task is in: a run queue, the inject queue, a
/// processor's pinned queue or inbox.
next: ?*Task = null,
/// The inbox link of this task's one cancel message.
cancel_next: ?*Task = null,
/// Its stack among the runtime's; null for the root, which runs on its thread's.
stack: ?Stacks.Stack = null,
/// The immutable upper bound, also used for parked stack watermarks.
stack_top: usize = 0,
kind: Kind,
/// Immutable after publication: foreign wakes can read this byte without
/// racing the task's mutable execution hints.
policy: Policy = .{},
/// Owned by the running task, or by its pinned loop while parked.
execution: Execution = .{},
/// The processor it runs or last ran on (an opaque `*Processor`).
processor: ?*anyopaque = null,
/// Held on `processor` for now: a timer of its own armed there, or a
/// batch with operations in that processor's kernel queue.
pins: u16 = 0,
/// Operations left before an exhausted budget turns a cancelation point
/// into a yield.
budget: u16 = 0,
/// When the running task's budget started being spent; zero until its
/// first cancelation point that did not wait.
slice_start: clocks.Awake = .fromRaw(0),
cancel: std.atomic.Value(u32) = .init(0),
/// The hook of the cancelable wait it is parked in; guarded by `locked`.
wait: ?*Hook = null,
/// Futures: 0 while running, `finished` once done, else the `*Awaiter`
/// waiting for it.
awaiter: std.atomic.Value(usize) = .init(0),
/// Group members: the group and their links in it.
group: ?*Io.Group = null,
group_prev: ?*Task = null,
group_next: ?*Task = null,
/// What it runs, and where its copied context and its result live.
start: Start = .none,
context_bytes: [*]u8 = undefined,
result_bytes: [*]u8 = undefined,
/// Where `concurrent`, `async` or a group call started it.
spawned_at: usize = 0,
/// The crashing task's own summary; no other thread reads these fields.
operation: ?std.meta.Tag(op.Kind) = null,
lane: ?Lanes.Lane = null,

pub const Priority = Lanes.Priority;

pub const Kind = enum(u8) { root, future, member };

pub const Policy = packed struct(u3) {
    /// The root and per-core tasks stay on their processor.
    home: bool = false,
    priority: Priority = .normal,
    measured: bool = false,

    /// Whether the task leaves the ordinary path: it stays on its processor
    /// or runs with latency priority. One test of the byte.
    pub inline fn routed(policy: Policy) bool {
        return @as(u3, @bitCast(policy)) & 0b011 != 0;
    }
};
pub const Execution = packed struct(u3) {
    protection: Protection = .{},
    /// Its loop owns a trim timer until resume.
    trim_pending: bool = false,
};

pub const Start = union(enum) {
    none,
    future: *const fn (context: *const anyopaque, result: *anyopaque) void,
    member: *const fn (context: *const anyopaque) void,
};

pub const finished: usize = 1;

const requested_bit: u32 = 1;
const locked_bit: u32 = 2;

/// What a parked task's waiter does when the task is cancelled: called
/// with the task's lock held, from any thread.
pub const Hook = struct {
    cancel: *const fn (hook: *Hook, task: *Task) void,
};

/// Someone waiting for a future: a task, or a thread outside the runtime.
pub const Awaiter = struct {
    task: ?*Task,
    /// The future awaited, for registering after the switch.
    target: ?*Task = null,
    /// Set to 1 when the future finishes, for a waiting thread.
    done: std.atomic.Value(u32) = .init(0),
};

pub const Protection = packed struct(u2) {
    user: Io.CancelProtection = .unblocked,
    acknowledged: bool = false,

    /// Whether a cancelation point may fire now.
    pub fn open(p: Protection) bool {
        return p.user == .unblocked and !p.acknowledged;
    }
};

pub fn lock(t: *Task) void {
    while (true) {
        const old = t.cancel.fetchOr(locked_bit, .acquire);
        if (old & locked_bit == 0) return;
        while (t.cancel.load(.monotonic) & locked_bit != 0) std.atomic.spinLoopHint();
    }
}

pub fn unlock(t: *Task) void {
    _ = t.cancel.fetchAnd(~locked_bit, .release);
}

pub fn cancelRequested(t: *const Task) bool {
    return t.cancel.load(.acquire) & requested_bit != 0;
}

/// Marks the cancel requested and runs the hook of the wait the task is
/// parked in, if that wait is cancelable. Once per task.
pub fn requestCancel(t: *Task) void {
    t.lock();
    defer t.unlock();
    const old = t.cancel.fetchOr(requested_bit, .acq_rel);
    if (old & requested_bit != 0) return;
    if (t.wait) |hook| hook.cancel(hook, t);
}

/// A cancelation point that does not wait: true when it fires, and then
/// the request is acknowledged.
pub fn takeCancel(t: *Task) bool {
    if (!t.execution.protection.open()) return false;
    if (!t.cancelRequested()) return false;
    t.execution.protection.acknowledged = true;
    return true;
}

/// Enters a cancelable wait: publishes `hook` unless a cancel is already
/// due, in which case it is acknowledged and the wait must not start.
/// `null` hook: the wait is not cancelable (protection blocks it).
pub fn enterWait(t: *Task, hook: *Hook) error{Canceled}!void {
    if (!t.execution.protection.open()) return;
    t.lock();
    defer t.unlock();
    if (t.cancelRequested()) {
        t.execution.protection.acknowledged = true;
        return error.Canceled;
    }
    t.wait = hook;
}

/// Leaves the wait entered with `enterWait`, if any.
pub fn leaveWait(t: *Task) void {
    if (t.wait == null) return;
    t.lock();
    t.wait = null;
    t.unlock();
}

/// Turns a wait that a cancel ended into the cancelation point's error.
pub fn acknowledge(t: *Task) error{Canceled} {
    t.acknowledged();
    return error.Canceled;
}

/// A call made elsewhere (on a lane) returned the cancel: this task has
/// seen it.
pub fn acknowledged(t: *Task) void {
    assert(t.cancelRequested());
    t.execution.protection.acknowledged = true;
}

pub fn recancel(t: *Task) void {
    assert(t.execution.protection.acknowledged);
    t.execution.protection.acknowledged = false;
}
