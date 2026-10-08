//! Futures and groups: `async`, `concurrent`, `await`, `cancel`, the four
//! group calls, and the cancel-protection calls.
//!
//! A future's task keeps its stack after it ends, because its result lives
//! there, until the awaiter copies the result and gives the stack back. A
//! group member gives its stack back as it ends. A group's `token` points
//! at its first member while it has any; its `state` holds a lock bit, a
//! canceled bit, and the awaiter.
const std = @import("std");
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

pub fn concurrentWith(s: *Scheduler, result_len: usize, result_alignment: Alignment, context: []const u8, context_alignment: Alignment, start: *const fn (*const anyopaque, *anyopaque) void, spawned_at: usize, stack_size: ?usize, priority: Task.Priority) Io.ConcurrentError!*Task {
    return concurrentMode(true, s, result_len, result_alignment, context, context_alignment, start, spawned_at, stack_size, priority);
}

inline fn concurrentMode(comptime customized: bool, s: *Scheduler, result_len: usize, result_alignment: Alignment, context: []const u8, context_alignment: Alignment, start: *const fn (*const anyopaque, *anyopaque) void, spawned_at: usize, stack_size: ?usize, priority: Task.Priority) Io.ConcurrentError!*Task {
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
    t.start.future(t.context_bytes, t.result_bytes);
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

fn schedulerOf(t: *Task) *Scheduler {
    const p: *Processor = @ptrCast(@alignCast(t.processor.?)); // safe: only processors are stored there
    return p.scheduler;
}

// Groups.

const State = packed struct(usize) {
    locked: bool = false,
    canceled: bool = false,
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

fn stateOf(g: *Io.Group) *usize {
    return &g.state;
}

fn lockGroup(g: *Io.Group) State {
    while (true) {
        const old: State = @bitCast(@atomicRmw(usize, stateOf(g), .Or, 1, .acquire));
        if (!old.locked) {
            var held = old;
            held.locked = true;
            return held;
        }
        while (@as(State, @bitCast(@atomicLoad(usize, stateOf(g), .monotonic))).locked) std.atomic.spinLoopHint();
    }
}

fn unlockGroup(g: *Io.Group, st: State) void {
    var released = st;
    released.locked = false;
    @atomicStore(usize, stateOf(g), @bitCast(released), .release);
}

fn head(g: *Io.Group) ?*Task {
    return @ptrCast(@alignCast(g.token.raw)); // safe: only tasks are stored in a group's token
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
    const st = lockGroup(g);
    t.group_next = head(g);
    if (head(g)) |first| first.group_prev = t;
    g.token.store(t, .release);
    if (st.canceled) _ = t.cancel.fetchOr(1, .monotonic);
    unlockGroup(g, st);
    s.place(t);
}

fn memberEntry(t: *Task) noreturn {
    t.start.member(t.context_bytes);
    Scheduler.exit(.{ .func = memberDone, .context = t });
}

/// Off the ended member's stack: out of the group, the stack back, and the
/// awaiter told if it was the last.
fn memberDone(context: *anyopaque, t: *Task) void {
    _ = context;
    const s = schedulerOf(t);
    const g = t.group.?;
    var st = lockGroup(g);
    if (t.group_prev) |prev| prev.group_next = t.group_next else g.token.store(t.group_next, .release);
    if (t.group_next) |next| next.group_prev = t.group_prev;
    const last = head(g) == null;
    const a = if (last) st.awaiterPtr() else null;
    if (last) st = st.withAwaiter(null);
    // Empty is observable only after every member has returned its stack.
    // Awaiters that see an empty group may immediately stop the runtime.
    s.release(t);
    unlockGroup(g, st);
    if (a) |awaiter| wakeAwaiter(s, awaiter);
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

fn cancelMembers(g: *Io.Group) void {
    var st = lockGroup(g);
    st.canceled = true;
    var it = head(g);
    while (it) |member| : (it = member.group_next) member.requestCancel();
    unlockGroup(g, st);
}

const Registration = struct { group: *Io.Group, awaiter: *Task.Awaiter, state: State };

fn registerGroupAwaiter(context: *anyopaque, t: *Task) void {
    _ = t;
    const r: *Registration = @ptrCast(@alignCast(context)); // safe: `waitGroup` passed its registration
    unlockGroup(r.group, r.state.withAwaiter(r.awaiter));
}

/// Waits until `g` has no members. Cancelable: a cancel is passed to every
/// member, and the wait still lasts until they have all ended.
pub fn groupAwait(s: *Scheduler, g: *Io.Group) Io.Cancelable!void {
    _ = s;
    const t = Scheduler.current() orelse return waitGroupThread(g);
    var w: GroupWait = .{ .group = g };
    t.enterWait(&w.hook) catch {
        // A cancel was already due: pass it on and wait for the members.
        cancelMembers(g);
        waitGroup(g, t);
        return error.Canceled;
    };
    waitGroup(g, t);
    t.leaveWait();
    if (w.fired) return t.acknowledge();
}

/// Cancels every member, then waits until all have ended.
pub fn groupCancel(s: *Scheduler, g: *Io.Group) void {
    _ = s;
    cancelMembers(g);
    const t = Scheduler.current() orelse return waitGroupThread(g);
    waitGroup(g, t);
}

fn waitGroup(g: *Io.Group, t: *Task) void {
    const st = lockGroup(g);
    if (head(g) == null) return unlockGroup(g, st);
    var a: Task.Awaiter = .{ .task = t };
    var r: Registration = .{ .group = g, .awaiter = &a, .state = st };
    // The group stays locked until the task is off its stack.
    Scheduler.park(.{ .func = registerGroupAwaiter, .context = &r });
}

fn waitGroupThread(g: *Io.Group) void {
    const st = lockGroup(g);
    if (head(g) == null) return unlockGroup(g, st);
    var a: Task.Awaiter = .{ .task = null };
    unlockGroup(g, st.withAwaiter(&a));
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
    const old = t.protection.user;
    t.protection.user = new;
    return old;
}
