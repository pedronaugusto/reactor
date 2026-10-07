//! The scheduler: its processors, and what they share (the global queue,
//! who is idle, the stacks, the root task, and the thread-local link from
//! a thread to the processor it holds). Also the scheduling interface the
//! layers above use: `current`, `park`, `yield`, `exit`, `ready`,
//! `create`, `release`.
const Scheduler = @This();

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const fiber = @import("fiber.zig");
const Stacks = @import("fiber/Stacks.zig");
const Loop = @import("Loop.zig");
const Task = @import("scheduler/Task.zig");
const run_queue = @import("scheduler/run_queue.zig");
const RunQueue = run_queue.RunQueue(Task);
const Inbox = @import("scheduler/inbox.zig").Inbox;

pub const Scheduling = enum { stealing, per_core };

/// Work another thread hands a processor, run on its thread.
pub const Errand = struct {
    next: ?*Errand = null,
    run: *const fn (e: *Errand, p: *Processor) void,
};

/// Descriptors are tracked hashed into this many slots; two descriptors in
/// one slot only make a close look at a processor it need not.
pub const descriptor_slots = 4096;

fn descriptorSlot(fd: i64) usize {
    return @intCast(@as(u64, @bitCast(fd)) % descriptor_slots);
}

/// A processor's bit in `holders`; beyond 64 processors bits are shared.
fn processorBit(index: u16) u64 {
    return @as(u64, 1) << @intCast(index % 64);
}

/// Whether processor `index`'s kernel queue may hold an operation on `fd`.
pub fn holds(s: *const Scheduler, index: u16, fd: i64) bool {
    return s.holders[descriptorSlot(fd)].load(.acquire) & processorBit(index) != 0;
}

/// How long a processor with nothing to do looks for work before it
/// waits in the kernel.
const spin_ns = 20 * std.time.ns_per_us;

/// A processor: a loop, the tasks ready to run on it, and the context its
/// scheduler runs in. Exactly one thread holds a processor at a time.
///
/// Tasks are found in this order: every 61st pass the global queue first
/// (and the kernel polled without waiting); the LIFO slot, at most three
/// times in a row; the pinned queue and the local queue, alternating;
/// the global queue; the inbox; then, under `stealing`, half of another
/// processor's queue. With nothing to run the processor waits in its
/// loop's kernel call until a completion, a timer or a wake.
///
/// Every switch goes through the scheduler's context, as Go's g0: a task
/// parks by switching there with an action (unlock this, publish that),
/// which runs only once the task's stack is still, so no other thread can
/// resume a task that has not finished switching away.
pub const Processor = struct {
    scheduler: *Scheduler,
    index: u16,
    loop: Loop,
    /// Where the scheduler waits while a task runs.
    sched_context: fiber.Context = undefined,
    /// The task running, if any.
    current: ?*Task = null,
    lifo: ?*Task = null,
    lifo_runs: u8 = 0,
    local: RunQueue = .{},
    pinned: Fifo = .{},
    inbox: Inbox(Task, "next") = .{},
    cancels: Inbox(Task, "cancel_next") = .{},
    errands: Inbox(Errand, "next") = .{},
    /// How many operations this processor's kernel queue holds on each
    /// descriptor (hashed); `Scheduler.holders` says which processors hold
    /// any.
    held: [descriptor_slots]u16 = @splat(0),
    tick: u32 = 0,
    /// Set while the processor may be waiting in the kernel: a producer that
    /// sees it wakes the loop.
    sleeping: std.atomic.Value(bool) = .init(false),
    /// The root's `run(mode)` the home processor is serving.
    serving: ?Serving = null,
    thread: ?std.Thread = null,

    /// A task queue only the owner touches.
    pub const Fifo = struct {
        head: ?*Task = null,
        tail: ?*Task = null,

        pub fn push(f: *Fifo, t: *Task) void {
            t.next = null;
            if (f.tail) |tail| tail.next = t else f.head = t;
            f.tail = t;
        }

        pub fn pop(f: *Fifo) ?*Task {
            const t = f.head orelse return null;
            f.head = t.next;
            if (f.head == null) f.tail = null;
            t.next = null;
            return t;
        }

        pub fn isEmpty(f: *const Fifo) bool {
            return f.head == null;
        }
    };

    /// What a switch into the scheduler asks it to do once the task's stack
    /// is still.
    pub const Message = struct {
        switch_: fiber.Switch,
        action: Action,
    };

    pub const Action = union(enum) {
        /// Back of the queue.
        yield,
        /// Parked; `after` (if any) runs now, off the task's stack.
        park: ?After,
        /// Ended; `after` runs now and releases what the task held.
        exit: After,
    };

    /// Work to do once a task is off its stack.
    pub const After = struct {
        func: *const fn (context: *anyopaque, t: *Task) void,
        context: *anyopaque,
    };

    /// A run of the home processor on the root's behalf (`Runtime.run`).
    pub const Serving = struct {
        mode: Loop.RunMode,
        /// Whether a kernel poll has happened for this run.
        polled: bool = false,
        delivered: u32 = 0,
    };

    /// How a task became ready, which decides where it queues.
    pub const How = enum {
        /// Started by a task here: the LIFO slot, so a spawn-then-await pair
        /// stays on one processor.
        spawned,
        /// Woken by a task here: the LIFO slot, as tokio and Go do.
        woken,
        /// An operation of its completed: the back of the queue.
        completed,
        /// Yielded: the back of the queue.
        yielded,
    };

    /// Makes `t` runnable on this processor; the owner's thread only.
    pub fn pushLocal(p: *Processor, t: *Task, how: How) void {
        t.processor = p;
        if (t.home or t.pins > 0) {
            p.pinned.push(t);
            return;
        }
        switch (how) {
            .spawned, .woken => if (p.scheduler.scheduling == .stealing) {
                if (p.lifo) |previous| p.pushQueue(previous);
                p.lifo = t;
                p.scheduler.notify(p);
                return;
            },
            .completed, .yielded => {},
        }
        p.pushQueue(t);
        p.scheduler.notify(p);
    }

    fn pushQueue(p: *Processor, t: *Task) void {
        if (p.local.push(t)) return;
        // Full: move the older half to the global queue, then retry.
        var half: [run_queue.capacity / 2]*Task = undefined;
        if (p.local.takeHalf(&half)) {
            p.scheduler.injectMany(&half);
            if (p.local.push(t)) return;
        }
        p.scheduler.inject(t);
    }

    /// From any thread: `t` runs on this processor next time it looks.
    pub fn pushRemote(p: *Processor, t: *Task) void {
        _ = p.inbox.push(t);
        if (p.sleeping.load(.seq_cst)) p.loop.wake();
    }

    /// From any thread: `e` runs on this processor's thread.
    pub fn send(p: *Processor, e: *Errand) void {
        _ = p.errands.push(e);
        if (p.sleeping.load(.seq_cst)) p.loop.wake();
    }

    /// The owner's: this processor's kernel queue now holds one more
    /// operation on `fd`.
    pub fn hold(p: *Processor, fd: i64) void {
        const slot = descriptorSlot(fd);
        p.held[slot] += 1;
        if (p.held[slot] == 1) _ = p.scheduler.holders[slot].fetchOr(processorBit(p.index), .release);
    }

    /// The owner's: one fewer.
    pub fn release(p: *Processor, fd: i64) void {
        const slot = descriptorSlot(fd);
        p.held[slot] -= 1;
        if (p.held[slot] == 0) _ = p.scheduler.holders[slot].fetchAnd(~processorBit(p.index), .release);
    }

    /// From any thread: this processor checks `t`'s wait for a cancel.
    pub fn pushCancel(p: *Processor, t: *Task) void {
        _ = p.cancels.push(t);
        if (p.sleeping.load(.seq_cst)) p.loop.wake();
    }

    /// The scheduler, on this processor's thread, until the runtime stops
    /// (workers) or forever (the home processor, which the root leaves).
    pub fn schedule(p: *Processor) void {
        while (true) {
            if (p.next()) |t| {
                p.runTask(t);
                continue;
            }
            if (p.drainInboxes()) continue;
            if (p.index != 0 and p.scheduler.stopping.load(.acquire)) return;
            if (p.serving != null and p.serve()) continue;
            if (p.pollKernel(.nowait)) continue;
            if (p.scheduler.scheduling == .stealing and (p.steal() or p.spin())) continue;
            p.block();
        }
    }

    /// The next task to run, from the queues this processor owns and the
    /// global queue.
    fn next(p: *Processor) ?*Task {
        p.tick +%= 1;
        if (p.tick % 61 == 0) {
            _ = p.pollKernel(.nowait);
            if (p.scheduler.takeInjected(p)) |t| return t;
        }
        if (p.lifo) |t| if (p.lifo_runs < 3) {
            p.lifo = null;
            p.lifo_runs += 1;
            return t;
        };
        p.lifo_runs = 0;
        const pinned_first = p.tick & 1 == 0;
        if (pinned_first) if (p.pinned.pop()) |t| return t;
        if (p.local.pop()) |t| return t;
        if (!pinned_first) if (p.pinned.pop()) |t| return t;
        if (p.lifo) |t| {
            p.lifo = null;
            return t;
        }
        return p.scheduler.takeInjected(p);
    }

    /// Moves remote wakes into the queues and serves cancel messages.
    fn drainInboxes(p: *Processor) bool {
        var any = false;
        var woken = p.inbox.takeAll();
        while (woken) |t| {
            woken = t.next;
            p.pushLocal(t, .completed);
            any = true;
        }
        var errands = p.errands.takeAll();
        while (errands) |e| {
            errands = e.next;
            e.run(e, p);
            any = true;
        }
        var cancels = p.cancels.takeAll();
        while (cancels) |t| {
            cancels = t.cancel_next;
            t.cancel_next = null;
            // The hook re-checks that the wait is still this processor's and
            // cancels its operation in this loop.
            t.lock();
            if (t.wait) |hook| hook.cancel(hook, t);
            t.unlock();
        }
        return any;
    }

    /// Runs `t` until it switches back, then does what it asked.
    fn runTask(p: *Processor, t: *Task) void {
        p.current = t;
        t.processor = p;
        t.budget = p.scheduler.budget_ops;
        t.slice_start = 0;
        var s: fiber.Switch = .{ .old = &p.sched_context, .new = &t.context };
        const back = fiber.switchTo(&s);
        p.afterSwitch(t, back);
    }

    /// What the scheduler does once `t` has switched back to it: `t`'s stack
    /// is still now, so `t` may be published to whoever will resume it.
    pub fn afterSwitch(p: *Processor, t: *Task, back: *const fiber.Switch) void {
        p.current = null;
        const message: *const Message = @alignCast(@fieldParentPtr("switch_", back)); // safe: the field belongs to this record
        const action = message.action;
        switch (action) {
            .yield => p.pushLocal(t, .yielded),
            .park => |after| if (after) |a| a.func(a.context, t),
            .exit => |a| a.func(a.context, t),
        }
    }

    /// Polls the kernel and runs what became ready; true when something did.
    fn pollKernel(p: *Processor, mode: Loop.RunMode) bool {
        const n = p.loop.run(mode) catch |err| std.debug.panic("reactor: the kernel's queue failed: {t}", .{err});
        if (p.serving) |*s| s.delivered += n;
        return n > 0 or !p.pinned.isEmpty() or !p.local.isEmpty() or p.lifo != null;
    }

    /// Waits in the kernel until a completion, a timer, or a wake.
    fn block(p: *Processor) void {
        p.sleeping.store(true, .seq_cst);
        defer p.sleeping.store(false, .monotonic);
        if (!p.inbox.isEmpty() or !p.cancels.isEmpty() or !p.errands.isEmpty() or p.scheduler.injectedLen() > 0) return;
        if (p.index != 0 and p.scheduler.stopping.load(.acquire)) return;
        p.scheduler.idle(p, true);
        defer p.scheduler.idle(p, false);
        const mode: Loop.RunMode = if (p.serving) |s| switch (s.mode) {
            .within, .until => |deadline| .{ .within = deadline },
            .nowait, .once => .once,
        } else .once;
        _ = p.pollKernel(mode);
        if (p.serving) |*s| s.polled = true;
    }

    /// Whether the root's `run(mode)` is over, and if so makes the root
    /// runnable. True when the caller should look for tasks again.
    fn serve(p: *Processor) bool {
        const s = &p.serving.?;
        const done = switch (s.mode) {
            .nowait => s.polled,
            .once => s.delivered > 0 or s.polled,
            .within => |deadline| s.delivered > 0 or s.polled and p.passed(deadline),
            .until => |deadline| p.passed(deadline),
        };
        if (done) {
            p.serving = null;
            p.pushLocal(p.scheduler.root, .completed);
            return true;
        }
        if (s.mode == .nowait) {
            _ = p.pollKernel(.nowait);
            s.polled = true;
            return true;
        }
        return false;
    }

    fn passed(p: *Processor, t: Io.Clock.Timestamp) bool {
        return p.loop.clock.now(t.clock).nanoseconds >= t.raw.nanoseconds;
    }

    /// Takes half of a busy processor's queue.
    fn steal(p: *Processor) bool {
        const all = p.scheduler.processors;
        if (all.len < 2) return false;
        const start = p.tick % all.len;
        for (0..all.len) |i| {
            const victim = &all[(start + i) % all.len];
            if (victim == p) continue;
            if (victim.local.stealInto(&p.local)) |t| {
                _ = p.scheduler.steals.fetchAdd(1, .monotonic);
                p.pushQueueFront(t);
                return true;
            }
        }
        return false;
    }

    /// Looks for work a while before waiting in the kernel, as Go's
    /// spinning Ms do: a burst of wakes then finds a processor awake. At
    /// most half the processors spin at once.
    fn spin(p: *Processor) bool {
        const s = p.scheduler;
        if (s.processors.len < 2) return false;
        if (s.searching.load(.monotonic) * 2 >= s.processors.len) return false;
        _ = s.searching.fetchAdd(1, .acq_rel);
        defer _ = s.searching.fetchSub(1, .acq_rel);
        const start = p.loop.clock.awake();
        var round: u32 = 0;
        while (true) : (round += 1) {
            if (!p.inbox.isEmpty() or !p.cancels.isEmpty() or !p.errands.isEmpty() or s.injectedLen() > 0) return true;
            if (round % 16 == 0) {
                if (p.steal()) return true;
                if (p.loop.clock.awake() - start > spin_ns) return false;
            }
            std.atomic.spinLoopHint();
        }
    }

    /// A stolen task runs next.
    fn pushQueueFront(p: *Processor, t: *Task) void {
        if (p.lifo) |previous| p.pushQueue(previous);
        p.lifo = t;
    }

    /// The worker thread's body: own the processor's loop, then schedule on
    /// this thread's stack until the runtime stops.
    pub fn work(p: *Processor) void {
        Scheduler.enter(p);
        defer Scheduler.leave();
        p.loop.adopt();
        p.schedule();
    }
};

processors: []Processor,
root: *Task,
stacks: Stacks,
scheduling: Scheduling,
budget_ops: u16,
/// The longest a task runs through cancelation points without waiting.
budget_ns: u64,
inject_lock: Io.Mutex = .init,
inject_head: ?*Task = null,
inject_tail: ?*Task = null,
inject_len: std.atomic.Value(u32) = .init(0),
idle_count: std.atomic.Value(u32) = .init(0),
/// Per descriptor slot, a bit for each processor whose kernel queue holds
/// an operation on it.
holders: [descriptor_slots]std.atomic.Value(u64) = @splat(.init(0)),
/// Processors spinning for work before they wait.
searching: std.atomic.Value(u32) = .init(0),
stopping: std.atomic.Value(bool) = .init(false),
/// Tasks alive, the root excluded.
live: std.atomic.Value(u32) = .init(0),
/// Round robin for tasks started outside a processor under `per_core`.
placement: std.atomic.Value(u32) = .init(0),
steals: std.atomic.Value(u64) = .init(0),
forced_yields: std.atomic.Value(u64) = .init(0),

/// The system's own `Io`, for the few waits a thread outside any task
/// makes on a kernel futex.
pub fn system() Io {
    return Io.Threaded.global_single_threaded.io();
}

threadlocal var held: ?*Processor = null;

/// The calling thread now holds `p`.
pub fn enter(p: *Processor) void {
    assert(held == null);
    held = p;
}

pub fn leave() void {
    held = null;
}

/// The processor the calling thread holds, if any.
pub fn processor() ?*Processor {
    return held;
}

/// The task running on the calling thread, if it is one of this
/// scheduler's.
pub fn current() ?*Task {
    const p = held orelse return null;
    return p.current;
}

// Parking and waking.

/// Suspends the running task. `after` runs on the scheduler once the
/// task's stack is still: there it publishes the task to whoever will
/// wake it (a futex bucket, a lane, an awaited future).
pub fn park(after: ?Processor.After) void {
    const p = held.?;
    const t = p.current.?;
    var message: Processor.Message = .{
        .switch_ = .{ .old = &t.context, .new = &p.sched_context },
        .action = .{ .park = after },
    };
    _ = fiber.switchTo(&message.switch_);
}

/// To the back of the queue.
pub fn yield() void {
    const p = held.?;
    const t = p.current.?;
    var message: Processor.Message = .{
        .switch_ = .{ .old = &t.context, .new = &p.sched_context },
        .action = .yield,
    };
    _ = fiber.switchTo(&message.switch_);
}

/// Ends the running task: `after` runs once it is off its stack.
pub fn exit(after: Processor.After) noreturn {
    const p = held.?;
    const t = p.current.?;
    var message: Processor.Message = .{
        .switch_ = .{ .old = &t.context, .new = &p.sched_context },
        .action = .{ .exit = after },
    };
    _ = fiber.switchTo(&message.switch_);
    unreachable; // unreachable: nothing switches back to an ended task
}

/// Spends one unit of the running task's budget at a cancelation point
/// that did not wait; a spent budget, in operations or in time, yields.
/// The clock is read at the first such point of a run and every eighth
/// after, so a task that waits soon never reads it.
pub fn spend(s: *Scheduler) void {
    const p = held orelse return;
    const t = p.current orelse return;
    if (t.budget > 0) {
        t.budget -= 1;
        if (t.budget % 8 != 0) return;
        const now = p.loop.clock.awake();
        if (t.slice_start == 0) {
            t.slice_start = now;
            return;
        }
        if (now - t.slice_start < s.budget_ns) return;
    }
    _ = s.forced_yields.fetchAdd(1, .monotonic);
    yield();
}

/// Makes a parked task runnable, from any thread.
pub fn ready(s: *Scheduler, t: *Task, how: Processor.How) void {
    const target: ?*Processor = if (t.home or t.pins > 0 or s.scheduling == .per_core)
        @ptrCast(@alignCast(t.processor)) // safe: only processors are stored there
    else
        null;
    if (held) |p| {
        if (target == null or target == p) return p.pushLocal(t, how);
        return target.?.pushRemote(t);
    }
    if (target) |tp| return tp.pushRemote(t);
    s.inject(t);
}

/// Asks the processor holding `t`'s wait to check it for a cancel.
pub fn cancelOn(t: *Task, p: *Processor) void {
    p.pushCancel(t);
}

// The global queue.

pub fn inject(s: *Scheduler, t: *Task) void {
    s.injectChain(t, t, 1);
}

pub fn injectMany(s: *Scheduler, tasks: []const *Task) void {
    for (tasks[0 .. tasks.len - 1], tasks[1..]) |a, b| a.next = b;
    tasks[tasks.len - 1].next = null;
    s.injectChain(tasks[0], tasks[tasks.len - 1], @intCast(tasks.len));
}

fn injectChain(s: *Scheduler, first: *Task, last: *Task, count: u32) void {
    last.next = null;
    s.inject_lock.lockUncancelable(system());
    if (s.inject_tail) |tail| tail.next = first else s.inject_head = first;
    s.inject_tail = last;
    _ = s.inject_len.fetchAdd(count, .release);
    s.inject_lock.unlock(system());
    s.wakeIdle();
}

pub fn injectedLen(s: *const Scheduler) u32 {
    return s.inject_len.load(.acquire);
}

/// One task from the global queue for `p`.
pub fn takeInjected(s: *Scheduler, p: *Processor) ?*Task {
    _ = p;
    if (s.inject_len.load(.acquire) == 0) return null;
    s.inject_lock.lockUncancelable(system());
    defer s.inject_lock.unlock(system());
    const t = s.inject_head orelse return null;
    s.inject_head = t.next;
    if (s.inject_head == null) s.inject_tail = null;
    t.next = null;
    _ = s.inject_len.fetchSub(1, .release);
    return t;
}

// Idle processors.

/// `p` is about to wait in the kernel (or stopped waiting).
pub fn idle(s: *Scheduler, p: *Processor, waiting: bool) void {
    _ = p;
    if (waiting) {
        _ = s.idle_count.fetchAdd(1, .seq_cst);
    } else {
        _ = s.idle_count.fetchSub(1, .seq_cst);
    }
}

/// `p` has more work than it can run now: wake an idle processor to steal
/// it, if there is one.
pub fn notify(s: *Scheduler, p: *Processor) void {
    if (s.scheduling != .stealing) return;
    if (s.idle_count.load(.seq_cst) == 0) return;
    // A spinning processor will find it.
    if (s.searching.load(.seq_cst) > 0) return;
    if (p.local.isEmpty() and p.lifo == null) return;
    s.wakeIdle();
}

fn wakeIdle(s: *Scheduler) void {
    if (s.idle_count.load(.seq_cst) == 0) return;
    for (s.processors) |*other| {
        if (other.sleeping.load(.seq_cst)) {
            other.loop.wake();
            return;
        }
    }
}

/// Every processor's thread looks at its queues again.
pub fn wakeAll(s: *Scheduler) void {
    for (s.processors) |*p| p.loop.wake();
}

// Tasks.

/// A new task on a free stack, not yet runnable, with `extra` bytes
/// (aligned to `extra_align`) below its record for the caller's context
/// and result; null when every stack is in use. `entry` runs first.
pub fn create(s: *Scheduler, kind: Task.Kind, extra: usize, extra_align: std.mem.Alignment, entry: *const fn (t: *Task) noreturn) ?struct { *Task, [*]u8 } {
    const index = s.stacks.take() orelse return null;
    const top = s.stacks.top(index);
    const record_at = std.mem.alignBackward(usize, top - @sizeOf(Task), @alignOf(Task));
    const extra_at = extra_align.backward(record_at - extra);
    const sp = std.mem.alignBackward(usize, extra_at, 16);
    if (sp - s.stacks.bottom(index) < s.stacks.size / 2) {
        s.stacks.give(index);
        return null;
    }
    const t: *Task = @ptrFromInt(record_at);
    t.* = .{ .kind = kind, .stack = index, .home = s.scheduling == .per_core };
    t.context = fiber.initial(sp, taskEntry, @ptrCast(@constCast(entry))); // safe: `taskEntry` casts it back to the entry it is
    _ = s.live.fetchAdd(1, .monotonic);
    return .{ t, @ptrFromInt(extra_at) };
}

/// Gives back the stack of a task that has ended and been forgotten.
pub fn release(s: *Scheduler, t: *Task) void {
    const index = t.stack.?;
    t.* = undefined;
    s.stacks.give(index);
    _ = s.live.fetchSub(1, .release);
}

/// Where a newly made task runs first: the creator's processor, or,
/// outside any, the next by round robin under `per_core`.
pub fn place(s: *Scheduler, t: *Task) void {
    if (held) |p| {
        t.processor = p;
        return p.pushLocal(t, .spawned);
    }
    if (s.scheduling == .per_core) {
        const i = s.placement.fetchAdd(1, .monotonic) % s.processors.len;
        const p = &s.processors[i];
        t.processor = p;
        return p.pushRemote(t);
    }
    s.inject(t);
}

fn taskEntry(arg: *anyopaque, message: *const fiber.Switch) callconv(.c) noreturn {
    _ = message;
    const entry: *const fn (t: *Task) noreturn = @ptrCast(@alignCast(arg)); // safe: `create` passed the entry
    entry(current().?);
}
