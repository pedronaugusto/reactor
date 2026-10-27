//! Futures and groups: `async`, `concurrent`, `await`, `cancel`, the four
//! group calls, and the cancel-protection calls.
//!
//! A future's task keeps its stack after it ends, because its result lives
//! there, until the awaiter copies the result and gives the stack back. A
//! group member gives its stack back as it ends. How a group counts and
//! lists its members is the task's (Task.zig, "Groups").
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const Alignment = std.mem.Alignment;

const Task = @import("../scheduler/Task.zig");
const Processor = @import("../Scheduler.zig").Processor;
const Scheduler = @import("../Scheduler.zig");

// Futures.

/// A future's task, or `ConcurrencyUnavailable` when no stack can be had
/// (every one in use, or the system refused to make a new one usable).
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
    Scheduler.exit(futureDone);
}

/// Off the ended task's stack: tell its awaiter, if it has one yet.
fn futureDone(t: *Task) void {
    const s = schedulerOf(t);
    if (t.awaiter.swap(&s.finished, .acq_rel)) |a| wakeAwaiter(s, a);
}

fn wakeAwaiter(s: *Scheduler, a: *Task.Awaiter) void {
    if (a.task) |waiter| return s.ready(waiter, .woken);
    a.done.store(1, .release);
    Scheduler.system().futexWake(u32, &a.done.raw, 1);
}

/// An awaiter, and the work that registers it once its task is off its stack.
const Awaiting = struct {
    after: Scheduler.After = .{ .run = registerAwaiter },
    awaiter: Task.Awaiter,
};

fn registerAwaiter(after: *Scheduler.After, waiter: *Task) void {
    const a = &(@as(*Awaiting, @fieldParentPtr("after", after))).awaiter;
    const future = a.target.?;
    const s = schedulerOf(waiter);
    if (future.awaiter.swap(a, .acq_rel) == &s.finished) s.ready(waiter, .woken);
}

/// Waits for `t` to end, copies its result and gives its stack back.
pub fn await(s: *Scheduler, t: *Task, result: []u8) void {
    const finished = &s.finished;
    if (t.awaiter.load(.acquire) != finished) {
        var w: Awaiting = .{ .awaiter = .{ .task = Scheduler.current(), .target = t } };
        const a = &w.awaiter;
        if (a.task != null) {
            Scheduler.park(&w.after);
        } else {
            const old = t.awaiter.swap(a, .acq_rel);
            if (old != finished) {
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
    return Scheduler.processorOf(t).?;
}

fn schedulerOf(t: *Task) *Scheduler {
    return processorOf(t).scheduler;
}

// Groups: their token, lock and membership are the task's (Task.zig); here
// the std calls.

/// Starts `start(context)` as a member of `g`; `ConcurrencyUnavailable`
/// when no stack can be had (`concurrent`).
pub fn groupConcurrent(s: *Scheduler, g: *Io.Group, context: []const u8, context_alignment: Alignment, start: *const fn (*const anyopaque) void, spawned_at: usize) Io.ConcurrentError!void {
    const layout = Layout.of(context.len, context_alignment, 0, .@"1");
    const t, const extra = s.create(.member, layout.size, layout.alignment, memberEntry) orelse return error.ConcurrencyUnavailable;
    t.context_bytes = extra + layout.context_offset;
    @memcpy(t.context_bytes[0..context.len], context);
    t.start = .{ .member = start };
    t.spawned_at = spawned_at;
    t.joinGroup(g);
    s.place(t);
}

fn memberEntry(t: *Task) noreturn {
    Scheduler.callOut(t, t.start.member, .{t.context_bytes});
    Scheduler.exit(memberDone);
}

/// Off the ended member's stack: out of the group, the stack back, and the
/// awaiter told if it was the last.
fn memberDone(t: *Task) void {
    const p = processorOf(t);
    const s = p.scheduler;
    // Counted from before it leaves the group until its stack is back, so an
    // awaiter that finds the group empty can wait for the stacks without
    // every member holding the group's lock for the release.
    p.retiring.store(p.retiring.load(.monotonic).add(.fromRaw(1)) catch unreachable, .release); // unreachable: fewer tasks than a u32 counts
    const a = t.leaveGroup();
    s.release(t);
    p.retiring.store(p.retiring.load(.monotonic).sub(.fromRaw(1)) catch unreachable, .release); // unreachable: it counted this member
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
        Task.cancelGroup(w.group);
    }
};

const Registration = struct {
    after: Scheduler.After = .{ .run = registerGroupAwaiter },
    group: *Io.Group,
    awaiter: *Task.Awaiter,
};

fn registerGroupAwaiter(after: *Scheduler.After, t: *Task) void {
    _ = t;
    const r: *Registration = @fieldParentPtr("after", after);
    Task.awaitGroup(r.group, r.awaiter);
    Task.unlockGroup(r.group);
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
        Task.cancelGroup(g);
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
    Task.cancelGroup(g);
    if (Scheduler.current()) |t| waitGroup(g, t) else waitGroupThread(g);
    settle(s, g);
}

/// `g` has no members: once every member that left it has given its stack
/// back, its token goes null and the group is its owner's again.
fn settle(s: *Scheduler, g: *Io.Group) void {
    s.awaitRetired();
    Task.settleGroup(g);
}

fn waitGroup(g: *Io.Group, t: *Task) void {
    const token = Task.lockGroup(g);
    if (Task.groupMembers(token) == 0) return Task.unlockGroup(g);
    var a: Task.Awaiter = .{ .task = t };
    var r: Registration = .{ .group = g, .awaiter = &a };
    // The group stays locked until the task is off its stack.
    Scheduler.park(&r.after);
}

fn waitGroupThread(g: *Io.Group) void {
    const token = Task.lockGroup(g);
    if (Task.groupMembers(token) == 0) return Task.unlockGroup(g);
    var a: Task.Awaiter = .{ .task = null };
    Task.awaitGroup(g, &a);
    Task.unlockGroup(g);
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
