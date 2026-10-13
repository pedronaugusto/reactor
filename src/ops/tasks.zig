//! Futures and groups: `async`, `concurrent`, `await`, `cancel`, the four
//! group calls, and the cancel-protection calls.
//!
//! A future's task keeps its stack after it ends, because its result lives
//! there, until the awaiter copies the result and gives the stack back. A
//! group member gives its stack back as it ends. A group's `token` holds its
//! lock bit and points at its first member while it has any; its `state`
//! holds a canceled bit and the awaiter.
const std = @import("std");
const aegis = @import("aegis");
const assert = std.debug.assert;
const Io = std.Io;
const Alignment = std.mem.Alignment;

const Task = @import("../scheduler/Task.zig");
const Processor = @import("../Scheduler.zig").Processor;
const Scheduler = @import("../Scheduler.zig");

// Futures.

/// A future's task, or `ConcurrencyUnavailable` when every stack is in use.
pub fn concurrent(s: *Scheduler, result_len: usize, result_alignment: Alignment, context: []const u8, context_alignment: Alignment, start: *const fn (*const anyopaque, *anyopaque) void, spawned_at: usize) Io.ConcurrentError!*Task {
    return concurrentMode(false, s, result_len, result_alignment, context, context_alignment, start, spawned_at, null, .normal);
}

pub fn concurrentWith(s: *Scheduler, result_len: usize, result_alignment: Alignment, context: []const u8, context_alignment: Alignment, start: *const fn (*const anyopaque, *anyopaque) void, spawned_at: usize, stack_size: ?aegis.units.Bytes(usize), priority: Task.Priority) Io.ConcurrentError!*Task {
    return concurrentMode(true, s, result_len, result_alignment, context, context_alignment, start, spawned_at, stack_size, priority);
}

inline fn concurrentMode(comptime customized: bool, s: *Scheduler, result_len: usize, result_alignment: Alignment, context: []const u8, context_alignment: Alignment, start: *const fn (*const anyopaque, *anyopaque) void, spawned_at: usize, stack_size: ?aegis.units.Bytes(usize), priority: Task.Priority) Io.ConcurrentError!*Task {
    const layout = Layout.of(context.len, context_alignment, result_len, result_alignment);
    const created = if (customized) s.createWith(.future, layout.size, layout.alignment, futureEntry, stack_size, priority) else s.create(.future, layout.size, layout.alignment, futureEntry);
    const t, const extra = created orelse return error.ConcurrencyUnavailable;
    t.context_bytes = extra + layout.context_offset;
    t.result_bytes = extra + layout.result_offset;
    @memcpy(t.context_bytes[0..context.len], context);
    t.start = .{ .future = start };
    t.spawned_at = spawned_at;
    s.place(t);
    return t;
}

/// Where a task's copied context and its result sit in the bytes below
/// its record: the result first (it outlives the context), then the
/// context.
const Layout = struct {
    size: usize,
    alignment: Alignment,
    result_offset: usize,
    context_offset: usize,

    fn of(context_len: usize, context_alignment: Alignment, result_len: usize, result_alignment: Alignment) Layout {
        const alignment = context_alignment.max(result_alignment).max(.@"16");
        const result_offset: usize = 0;
        const context_offset = context_alignment.forward(result_offset + result_len);
        return .{
            .size = alignment.forward(context_offset + context_len),
            .alignment = alignment,
            .result_offset = result_offset,
            .context_offset = context_offset,
        };
    }
};

fn futureEntry(t: *Task) noreturn {
    Scheduler.callOut(t, t.start.future, .{ t.context_bytes, t.result_bytes });
    Scheduler.exit(.{ .func = futureDone, .context = t });
}

/// Off the ended task's stack: tell its awaiter, if it has one yet.
fn futureDone(context: *anyopaque, t: *Task) void {
    _ = context;
    const s = schedulerOf(t);
    const old = t.awaiter.swap(Task.finished, .acq_rel);
    if (old != 0) wakeAwaiter(s, @ptrFromInt(old)); // safe: only `await` stores, and it stores an `*Awaiter`
}

fn wakeAwaiter(s: *Scheduler, a: *Task.Awaiter) void {
    if (a.task) |waiter| return s.ready(waiter, .woken);
    a.done.store(1, .release);
    Scheduler.system().futexWake(u32, &a.done.raw, 1);
}

fn registerAwaiter(context: *anyopaque, waiter: *Task) void {
    const a: *Task.Awaiter = @ptrCast(@alignCast(context)); // safe: `await` passed its awaiter
    const future = a.target.?;
    const old = future.awaiter.swap(@intFromPtr(a), .acq_rel); // safe: read back by `futureDone`
    if (old == Task.finished) schedulerOf(waiter).ready(waiter, .woken);
}

/// Waits for `t` to end, copies its result and gives its stack back.
pub fn await(s: *Scheduler, t: *Task, result: []u8) void {
    if (t.awaiter.load(.acquire) != Task.finished) {
        var a: Task.Awaiter = .{ .task = Scheduler.current(), .target = t };
        if (a.task != null) {
            Scheduler.park(.{ .func = registerAwaiter, .context = &a });
        } else {
            const old = t.awaiter.swap(@intFromPtr(&a), .acq_rel); // safe: read back by `futureDone`
            if (old != Task.finished) {
                const sys = Scheduler.system();
                while (a.done.load(.acquire) == 0) sys.futexWaitUncancelable(u32, &a.done.raw, 0);
            }
        }
    }
    @memcpy(result, t.result_bytes[0..result.len]);
    s.release(t);
}

/// Requests `t`'s cancel, then awaits it.
pub fn cancel(s: *Scheduler, t: *Task, result: []u8) void {
    t.requestCancel();
    await(s, t, result);
}

fn processorOf(t: *Task) *Processor {
    return @ptrCast(@alignCast(t.processor.?)); // safe: only processors are stored there
}

fn schedulerOf(t: *Task) *Scheduler {
    return processorOf(t).scheduler;
}

// Groups.
//
// std reads a group's `token` without the runtime: null means the group holds
// nothing, and `Group.await` and `cancel` return at once, after which its
// owner may reuse or free it. So only the runtime's own await or cancel leaves
// the token null, once every member has left the group and given its stack
// back. The last member to leave leaves it `ended`, its last touch of the
// group. The token also carries the group's lock, in a low bit beside the
// first member.

const locked_bit: usize = 0b01;
/// No members, and no await or cancel has settled the group yet.
const ended: usize = 0b10;
const flags: usize = locked_bit | ended;

comptime {
    assert(@alignOf(Task) > flags);
}

/// The canceled bit and the awaiter, read and written under the lock alone.
const State = packed struct(usize) {
    canceled: bool = false,
    _: u1 = 0,
    /// The awaiter's address, shifted right by 2.
    awaiter: @Int(.unsigned, @bitSizeOf(usize) - 2) = 0,

    fn awaiterPtr(st: State) ?*Task.Awaiter {
        if (st.awaiter == 0) return null;
        return @ptrFromInt(@as(usize, st.awaiter) << 2);
    }

    fn withAwaiter(st: State, a: ?*Task.Awaiter) State {
        var copy = st;
        copy.awaiter = if (a) |p| @intCast(@intFromPtr(p) >> 2) else 0; // safe: an `Awaiter` is word-aligned
        return copy;
    }
};

fn tokenOf(g: *Io.Group) *usize {
    return @ptrCast(&g.token.raw); // safe: an optional pointer is one word, null as zero
}

fn stateOf(g: *Io.Group) *State {
    return @ptrCast(&g.state); // safe: `State` is a packed `usize`, and `state` is the runtime's
}

/// Locks `g`; returns its token as it was, unlocked.
fn lockGroup(g: *Io.Group) usize {
    while (true) {
        const old = @atomicRmw(usize, tokenOf(g), .Or, locked_bit, .acquire);
        if (old & locked_bit == 0) return old;
        while (@atomicLoad(usize, tokenOf(g), .monotonic) & locked_bit != 0) std.atomic.spinLoopHint();
    }
}

fn unlockGroup(g: *Io.Group, token: usize) void {
    @atomicStore(usize, tokenOf(g), token, .release);
}

/// The token of a group whose first member is `t`, unlocked.
fn tokenFor(t: *Task) usize {
    return @intFromPtr(t); // safe: a task is aligned past the flag bits (checked above)
}

fn firstOf(token: usize) ?*Task {
    return @ptrFromInt(token & ~flags); // safe: only tasks are stored in a group's token
}

/// Starts `start(context)` as a member of `g`; `ConcurrencyUnavailable`
/// when every stack is in use.
pub fn groupConcurrent(s: *Scheduler, g: *Io.Group, context: []const u8, context_alignment: Alignment, start: *const fn (*const anyopaque) void, spawned_at: usize) Io.ConcurrentError!void {
    const layout = Layout.of(context.len, context_alignment, 0, .@"1");
    const t, const extra = s.create(.member, layout.size, layout.alignment, memberEntry) orelse return error.ConcurrencyUnavailable;
    t.context_bytes = extra + layout.context_offset;
    @memcpy(t.context_bytes[0..context.len], context);
    t.start = .{ .member = start };
    t.spawned_at = spawned_at;
    t.group = g;
    const first = firstOf(lockGroup(g));
    t.group_next = first;
    if (first) |member| member.group_prev = t;
    if (stateOf(g).canceled) _ = t.cancel.fetchOr(1, .monotonic);
    unlockGroup(g, tokenFor(t));
    s.place(t);
}

fn memberEntry(t: *Task) noreturn {
    Scheduler.callOut(t, t.start.member, .{t.context_bytes});
    Scheduler.exit(.{ .func = memberDone, .context = t });
}

/// Off the ended member's stack: out of the group, the stack back, and the
/// awaiter told if it was the last.
fn memberDone(context: *anyopaque, t: *Task) void {
    _ = context;
    const p = processorOf(t);
    const s = p.scheduler;
    const g = t.group.?;
    // Counted from before it leaves the group until its stack is back, so an
    // awaiter that finds the group empty can wait for the stacks without
    // every member holding the group's lock for the release.
    p.retiring.store(p.retiring.load(.monotonic) +% 1, .release);
    var first = firstOf(lockGroup(g));
    if (t.group_prev) |prev| prev.group_next = t.group_next else first = t.group_next;
    if (t.group_next) |next| next.group_prev = t.group_prev;
    var a: ?*Task.Awaiter = null;
    if (first) |member| unlockGroup(g, tokenFor(member)) else {
        a = stateOf(g).awaiterPtr();
        stateOf(g).* = .{};
        unlockGroup(g, ended);
    }
    s.release(t);
    p.retiring.store(p.retiring.load(.monotonic) -% 1, .release);
    if (a) |awaiter| wakeAwaiter(s, awaiter); // safe: an awaiter waits until woken, and its record with it
}

const GroupWait = struct {
    hook: Task.Hook = .{ .cancel = cancelHook },
    group: *Io.Group,
    fired: bool = false,

    /// The awaiting task was cancelled: cancel every member, keep waiting.
    fn cancelHook(hook: *Task.Hook, t: *Task) void {
        _ = t;
        const w: *GroupWait = @alignCast(@fieldParentPtr("hook", hook)); // safe: the field belongs to this record
        w.fired = true;
        cancelMembers(w.group);
    }
};

/// Requests every member's cancel and marks the group, so members started
/// before it empties are born canceled; an empty group stays unmarked.
fn cancelMembers(g: *Io.Group) void {
    const token = lockGroup(g);
    const first = firstOf(token);
    if (first != null) stateOf(g).canceled = true;
    var it = first;
    while (it) |member| : (it = member.group_next) member.requestCancel();
    unlockGroup(g, token);
}

const Registration = struct { group: *Io.Group, awaiter: *Task.Awaiter, token: usize };

fn registerGroupAwaiter(context: *anyopaque, t: *Task) void {
    _ = t;
    const r: *Registration = @ptrCast(@alignCast(context)); // safe: `waitGroup` passed its registration
    stateOf(r.group).* = stateOf(r.group).withAwaiter(r.awaiter);
    unlockGroup(r.group, r.token);
}

/// Waits until `g` has no members. Cancelable: a cancel is passed to every
/// member, and the wait still lasts until they have all ended.
pub fn groupAwait(s: *Scheduler, g: *Io.Group) Io.Cancelable!void {
    const t = Scheduler.current() orelse {
        waitGroupThread(g);
        return settle(s, g);
    };
    var w: GroupWait = .{ .group = g };
    t.enterWait(&w.hook) catch {
        // A cancel was already due: pass it on and wait for the members.
        cancelMembers(g);
        waitGroup(g, t);
        settle(s, g);
        return error.Canceled;
    };
    waitGroup(g, t);
    // Out of the wait first: its cancel hook may lock the group until then.
    t.leaveWait();
    settle(s, g);
    if (w.fired) return t.acknowledge();
}

/// Cancels every member, then waits until all have ended.
pub fn groupCancel(s: *Scheduler, g: *Io.Group) void {
    cancelMembers(g);
    if (Scheduler.current()) |t| waitGroup(g, t) else waitGroupThread(g);
    settle(s, g);
}

/// `g` has no members: once every member that left it has given its stack
/// back, its token goes null and the group is its owner's again.
fn settle(s: *Scheduler, g: *Io.Group) void {
    s.awaitRetired();
    const token = lockGroup(g);
    assert(firstOf(token) == null);
    unlockGroup(g, 0);
}

fn waitGroup(g: *Io.Group, t: *Task) void {
    const token = lockGroup(g);
    if (firstOf(token) == null) return unlockGroup(g, token);
    var a: Task.Awaiter = .{ .task = t };
    var r: Registration = .{ .group = g, .awaiter = &a, .token = token };
    // The group stays locked until the task is off its stack.
    Scheduler.park(.{ .func = registerGroupAwaiter, .context = &r });
}

fn waitGroupThread(g: *Io.Group) void {
    const token = lockGroup(g);
    if (firstOf(token) == null) return unlockGroup(g, token);
    var a: Task.Awaiter = .{ .task = null };
    stateOf(g).* = stateOf(g).withAwaiter(&a);
    unlockGroup(g, token);
    const sys = Scheduler.system();
    while (a.done.load(.acquire) == 0) sys.futexWaitUncancelable(u32, &a.done.raw, 0);
}

// Cancel protection.

pub fn checkCancel(s: *Scheduler) Io.Cancelable!void {
    const t = Scheduler.current() orelse return;
    if (t.takeCancel()) return error.Canceled;
    s.spend();
}

pub fn recancel() void {
    const t = Scheduler.current() orelse return;
    t.recancel();
}

pub fn swapCancelProtection(new: Io.CancelProtection) Io.CancelProtection {
    const t = Scheduler.current() orelse return .unblocked;
    const old = t.execution.protection.user;
    t.execution.protection.user = new;
    return old;
}
