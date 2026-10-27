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
const aegis = @import("aegis");
const clocks = @import("../clock.zig");
const shuttle = @import("shuttle");
const op = @import("../backend/op.zig");
const stacks = @import("stacks.zig");
const Lanes = @import("../Lanes.zig");
const Loop = @import("../Loop.zig");
const Raised = @import("../sync/Raised.zig");

/// Saved registers while the task is not running.
context: shuttle.Context = .{},
/// The one queue the task is in: a run queue, the inject queue, a
/// processor's pinned queue or inbox.
next: ?*Task = null,
/// Cancel requests for this task's waits that are queued at a processor or
/// being served; they live in the waits' records, which the task keeps until
/// they are served (`Scheduler.leaveWait`).
cancel_messages: aegis.Atomic(CancelMessages) = .init(.fromRaw(0)),
/// Its stack among the runtime's; null for the root, which runs on its thread's.
stack: ?stacks.Number = null,
/// The immutable upper bound, also used for parked stack watermarks.
stack_top: usize = 0,
kind: Kind,
/// Immutable after publication: foreign wakes can read this byte without
/// racing the task's mutable execution hints.
policy: Policy = .{},
/// Owned by the running task, or by its pinned loop while parked.
execution: Execution = .{},
/// The loop of the processor it runs or last ran on: the processor holds
/// its loop, and `Scheduler.processorOf` finds the processor from it. A
/// task's record cannot name the processor, which names tasks.
processor_loop: ?*Loop = null,
/// The context of the seat of the thread it runs or last ran on, set at
/// every switch to it: where it lends its processor from without reading
/// the thread's own storage again. The seat holds its context, and
/// `Scheduler` finds the seat from it.
seat_context: ?*shuttle.Context = null,
/// Held on `processor` for now: a timer of its own armed there, or a
/// batch with operations in that processor's kernel queue.
pins: u16 = 0,
/// A group member in its group's list, from its first cancelable wait on.
/// The task's own.
listed: bool = false,
/// Operations left before an exhausted budget turns a cancelation point
/// into a yield.
budget: u16 = 0,
/// When the running task's budget started being spent; zero until its
/// first cancelation point that did not wait.
slice_start: clocks.Awake = .fromRaw(0),
/// A cancel was requested of it.
requested: Raised = .{},
/// Held while its waits' hooks are published or run (`lock`).
locked: Raised = .{},
/// The hook of the cancelable wait it is parked in; guarded by `locked`.
wait: ?*Hook = null,
/// While it waits on or drains a batch: where that batch's completions
/// find it (ops/batch.zig).
batch_wait: ?*BatchWait = null,
/// Futures: null while running, its scheduler's `finished` once done, else
/// the awaiter waiting for it.
awaiter: aegis.Atomic(?*Awaiter) = .init(null),
/// Group members: the group, and their links among its listed members
/// (`listGroupMember`), guarded by the group's lock.
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

/// A number of cancel requests for a task's waits.
pub const CancelMessages = aegis.units.Count(Hook, u32);

/// What a parked task's waiter does when the task is cancelled: called
/// with the task's lock held, from any thread.
pub const Hook = struct {
    cancel: *const fn (hook: *Hook, task: *Task) void,
};

/// Someone waiting for a future or a group: a task, or a thread outside the
/// runtime.
/// A batch a task waits on or drains, kept in the record that waits, which
/// the batch's completions find by `@fieldParentPtr`.
pub const BatchWait = struct {
    batch: *Io.Batch,
};

/// Work to do once a parked task is off its stack, kept in the record that
/// does it, as a scheduler's errand is: `run` finds the record from it by
/// `@fieldParentPtr`.
pub const After = struct {
    run: *const fn (after: *After, t: *Task) void,
};

pub const Awaiter = struct {
    task: ?*Task,
    /// The future awaited, for registering after the switch.
    target: ?*Task = null,
    /// While it waits for a group: the group's listed members, whose first
    /// the group's `state` gives up to the awaiter.
    members: ?*Task = null,
    /// Set to 1 when the future finishes, for a waiting thread.
    // aegis: boundary: a futex word: the kernel waits on this u32's address
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
    while (t.locked.raise(.acquire)) {
        while (t.locked.raised(.monotonic)) std.atomic.spinLoopHint();
    }
}

pub fn unlock(t: *Task) void {
    t.locked.clear(.release);
}

/// Whether a cancel is due: requested of the task, or of its group. A
/// group's cancel reaches only the members it lists, so one not listed yet
/// takes it here, as its own.
pub fn cancelRequested(t: *Task) bool {
    if (t.requested.raised(.acquire)) return true;
    const g = t.group orelse return false;
    if (!tokenOf(g).load(.monotonic).has(GroupToken.canceled)) return false;
    _ = t.requested.raise(.acq_rel);
    return true;
}

/// Marks the cancel requested and runs the hook of the wait the task is
/// parked in, if that wait is cancelable. Once per task.
pub fn requestCancel(t: *Task) void {
    t.lock();
    defer t.unlock();
    if (t.requested.raise(.acq_rel)) return;
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
    // A member is listed before its hook is published, so a cancel of its
    // group from here on reaches the hook.
    if (t.group) |g| if (!t.listed) t.listGroupMember(g);
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

// Groups.
//
// A group's `token` holds its member count, in the bits above three flags:
// its lock, its cancel, and `held`. std reads the token without the
// runtime: null means the group holds nothing, and `Group.await` and
// `cancel` return at once, after which its owner may reuse or free it. So
// `held` is set from the first member on, and only the runtime's own await
// or cancel clears the token, once every member has left and given its
// stack back. A member is counted in and out with one atomic add each,
// without the lock and without touching another member: a group of short
// tasks costs its spawner and its members no more. The lock guards `state`
// alone: the list of members a cancel must reach, those that have entered a
// cancelable wait (a member that has not takes the group's cancel at its
// next cancelation point, `cancelRequested`), or, while the group is
// awaited, the awaiter, which holds that list for it.

/// What a group's token word holds while it has members: its lock, whether
/// it was canceled, whether the runtime holds it, and above them the
/// members counted in, one `member` each.
pub const GroupToken = enum(usize) {
    none = 0,
    _,

    pub const AddError = error{Overflow};
    pub const SubError = error{Overflow};

    const locked: usize = 0b001;
    const canceled: usize = 0b010;
    const held: usize = 0b100;
    /// One member, as members are counted in and out.
    const member: GroupToken = @fromBackingInt(0b1000);

    pub fn add(a: GroupToken, b: GroupToken) AddError!GroupToken {
        return @fromBackingInt(std.math.add(usize, @backingInt(a), @backingInt(b)) catch return error.Overflow);
    }

    pub fn sub(a: GroupToken, b: GroupToken) SubError!GroupToken {
        return @fromBackingInt(std.math.sub(usize, @backingInt(a), @backingInt(b)) catch return error.Overflow);
    }

    fn has(t: GroupToken, bit: usize) bool {
        return @backingInt(t) & bit != 0;
    }

    fn with(t: GroupToken, bit: usize) GroupToken {
        return @fromBackingInt(@backingInt(t) | bit);
    }

    fn without(t: GroupToken, bit: usize) GroupToken {
        return @fromBackingInt(@backingInt(t) & ~bit);
    }

    /// How many members it counts.
    fn members(t: GroupToken) usize {
        return @backingInt(t) / @backingInt(member);
    }
};

/// `state` holds an awaiter, not the first listed member.
const group_awaited: usize = 0b1;

comptime {
    assert(@alignOf(Awaiter) > group_awaited);
    assert(@alignOf(Task) > group_awaited);
}

/// `g`'s token word, as this runtime keeps it.
fn tokenOf(g: *Io.Group) *aegis.Atomic(GroupToken) {
    comptime assert(@sizeOf(aegis.Atomic(GroupToken)) == @sizeOf(@TypeOf(g.token)));
    comptime assert(@alignOf(aegis.Atomic(GroupToken)) == @alignOf(@TypeOf(g.token)));
    // aegis: boundary: std's Io.Group keeps its token in an atomic word whose null it reads as no members; this runtime keeps its GroupToken there, in an aegis cell of the same layout, none being null
    return @ptrCast(&g.token);
}

/// Sets `bit` in `g`'s token.
fn markGroup(g: *Io.Group, bit: usize, comptime order: std.builtin.AtomicOrder) GroupToken {
    const cell = tokenOf(g);
    var seen = cell.load(.monotonic);
    while (cell.cmpxchgWeak(seen, seen.with(bit), order, .monotonic)) |found| seen = found;
    return seen;
}

/// How many members a group's token counts.
pub fn groupMembers(token: GroupToken) usize {
    return token.members();
}

/// Locks `g`; returns its token as it was.
pub fn lockGroup(g: *Io.Group) GroupToken {
    const cell = tokenOf(g);
    var seen = cell.load(.monotonic);
    while (true) {
        if (seen.has(GroupToken.locked)) {
            std.atomic.spinLoopHint();
            seen = cell.load(.monotonic);
            continue;
        }
        seen = cell.cmpxchgWeak(seen, seen.with(GroupToken.locked), .acquire, .monotonic) orelse return seen;
    }
}

/// Members come and go while the group is locked: only the lock bit moves.
pub fn unlockGroup(g: *Io.Group) void {
    const cell = tokenOf(g);
    var seen = cell.load(.monotonic);
    while (cell.cmpxchgWeak(seen, seen.without(GroupToken.locked), .release, .monotonic)) |found| seen = found;
}

/// The listed members' first, in `state` or, while the group is awaited,
/// in its awaiter. Under the lock.
fn listedOf(g: *Io.Group) *?*Task {
    if (awaiterOf(g)) |a| return &a.members;
    // aegis: boundary: std's Io.Group gives the implementation one word, `state`, where this runtime keeps the first listed member while the group is not awaited
    return @ptrCast(&g.state);
}

/// The group's awaiter, if it is awaited. Under the lock.
fn awaiterOf(g: *Io.Group) ?*Awaiter {
    if (g.state & group_awaited == 0) return null;
    // aegis: boundary: std's Io.Group gives the implementation one word, `state`, where this runtime keeps the awaiter, its low bit set, while the group is awaited
    return @ptrFromInt(g.state & ~group_awaited);
}

/// `t` counted into `g`, before it is published: born canceled when the
/// group's cancel came first.
pub fn joinGroup(t: *Task, g: *Io.Group) void {
    t.group = g;
    const old = tokenOf(g).fetchAddWrapping(GroupToken.member, .monotonic);
    if (!old.has(GroupToken.held)) _ = markGroup(g, GroupToken.held, .monotonic);
    if (old.has(GroupToken.canceled)) _ = t.requested.raise(.monotonic);
}

/// `t` lists itself in its group, at its first cancelable wait, so the
/// group's cancel reaches the wait's hook.
fn listGroupMember(t: *Task, g: *Io.Group) void {
    const token = lockGroup(g);
    const first = listedOf(g);
    t.group_prev = null;
    t.group_next = first.*;
    if (first.*) |member| member.group_prev = t;
    first.* = t;
    t.listed = true;
    if (token.has(GroupToken.canceled)) _ = t.requested.raise(.acq_rel);
    unlockGroup(g);
}

/// Off `t`'s stack: `t` leaves its group. Its awaiter, to wake, when it was
/// the last member.
pub fn leaveGroup(t: *Task) ?*Awaiter {
    const g = t.group.?;
    if (t.listed) {
        _ = lockGroup(g);
        if (t.group_prev) |prev| prev.group_next = t.group_next else listedOf(g).* = t.group_next;
        if (t.group_next) |next| next.group_prev = t.group_prev;
    }
    // Counted out after the unlink: an empty group lists no one.
    const old = tokenOf(g).fetchSubWrapping(GroupToken.member, .acq_rel);
    if (old.members() != 1) {
        if (t.listed) unlockGroup(g);
        return null;
    }
    // The last: an awaiter registers under the lock once it has seen a
    // member counted, so it is there by now or will see none.
    if (!t.listed) _ = lockGroup(g);
    const awaiter = awaiterOf(g);
    // No member is listed now: the group's list goes back to its `state`, empty.
    if (awaiter) |a| {
        assert(a.members == null);
        g.state = 0;
    }
    unlockGroup(g);
    return awaiter;
}

/// Under the lock, with members counted: `a` waits for them.
pub fn awaitGroup(g: *Io.Group, a: *Awaiter) void {
    assert(awaiterOf(g) == null);
    a.members = listedOf(g).*;
    g.state = @intFromPtr(a) | group_awaited; // safe: an address with a flag in its low bit, read back by `awaiterOf`
}

/// Requests the cancel of every listed member and marks the group, so the
/// others and those started until it settles take it at their next
/// cancelation point.
pub fn cancelGroup(g: *Io.Group) void {
    _ = lockGroup(g);
    _ = markGroup(g, GroupToken.canceled, .monotonic);
    var it = listedOf(g).*;
    while (it) |member| : (it = member.group_next) member.requestCancel();
    unlockGroup(g);
}

/// Every member has left `g` and given its stack back: the group is its
/// owner's again.
pub fn settleGroup(g: *Io.Group) void {
    const token = lockGroup(g);
    assert(token.members() == 0);
    assert(g.state == 0);
    tokenOf(g).store(.none, .release);
}
