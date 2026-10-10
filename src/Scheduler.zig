//! The scheduler: its processors, and what they share (the global queue,
//! who is idle, the stacks, the root task, and the thread-local link from
//! a thread to the processor it holds). Also the scheduling interface the
//! layers above use: `current`, `park`, `yield`, `exit`, `ready`,
//! `create`, `release`.
const Scheduler = @This();

const std = @import("std");
const aegis = @import("aegis");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const clocks = @import("clock.zig");
const fiber = @import("fiber.zig");
const Stacks = @import("fiber/Stacks.zig");
const Loop = @import("Loop.zig");
const loop_internal = @import("loop/internal.zig");
const Task = @import("scheduler/Task.zig");
const Records = @import("scheduler/Records.zig");
const Trims = @import("scheduler/Trims.zig");
const run_queue = @import("scheduler/run_queue.zig");
const RunQueue = run_queue.RunQueue(Task);
const Inbox = @import("scheduler/inbox.zig").Inbox;
pub const Monitor = @import("scheduler/Monitor.zig");
pub const Spares = @import("scheduler/Spares.zig");

pub const Scheduling = enum { stealing, per_core };

/// Work another thread hands a processor, run on its thread.
pub const Errand = struct {
    next: ?*Errand = null,
    run: *const fn (e: *Errand, p: *Processor) void,
};

/// A request that the processor holding a task's wait check the wait for a
/// cancel. It lives in the wait's own record, in the waiting task's frame,
/// and the task does not leave the wait (`leaveWait`) until the processor has
/// served it, so a request never names a frame that is gone and a task's
/// record is never released while one is queued.
pub const CancelMessage = struct {
    next: ?*CancelMessage = null,
    task: *Task,
    /// In a processor's inbox or being served; guarded by the task's lock.
    queued: bool = false,
};

/// Descriptors are tracked hashed into this many slots; two descriptors in
/// one slot only make a close look at a processor it need not.
pub const descriptor_slots = 4096;

fn descriptorSlot(fd: Io.File.Handle) usize {
    const key: u64 = switch (@typeInfo(Io.File.Handle)) {
        .pointer => @intFromPtr(fd) >> 2, // safe: a handle's value, hashed
        else => @as(u32, @bitCast(fd)),
    };
    return @intCast(key % descriptor_slots);
}

/// A processor's bit in `holders`; beyond 64 processors bits are shared.
fn processorBit(index: u16) u64 {
    return @as(u64, 1) << @intCast(index % 64);
}

/// Whether processor `index`'s kernel queue may hold an operation on `fd`.
pub fn holds(s: *const Scheduler, index: u16, fd: Io.File.Handle) bool {
    if (comptime builtin.os.tag == .linux) if (s.processors[index].loop.backend == .io_uring) {
        if (s.processors[index].loop.backend.io_uring.contains(fd)) return true;
    };
    return s.holders[descriptorSlot(fd)].load(.acquire) & processorBit(index) != 0;
}

/// How much deeper than its current park a task must once have been parked
/// for the pages it touched then to be worth giving back.
const trim_gap = 64 << 10;

/// How long a processor with nothing to do looks for work before it
/// waits in the kernel.
/// A task whose budget has not begun to be spent in time: the awake clock
/// reads zero only before the machine has run.
const no_slice: clocks.Awake = .fromRaw(0);

const spin_for: clocks.Span = .fromRaw(20 * std.time.ns_per_us);

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
/// Every switch goes through the scheduler's context: a task
/// parks by switching there with an action (unlock this, publish that),
/// which runs only once the task's stack is still, so no other thread can
/// resume a task that has not finished switching away.
pub const Processor = struct {
    scheduler: *Scheduler,
    index: u16,
    /// Whether the current owner is the thread on which the root runs.
    on_home_thread: bool = false,
    loop: Loop,
    /// Where the scheduler waits while a task runs.
    sched_context: fiber.Context = undefined,
    /// The task running, if any.
    current: ?*Task = null,
    lifo: ?*Task = null,
    lifo_runs: u8 = 0,
    local: RunQueue = .{},
    pinned: Fifo = .{},
    latency: RunQueue = .{},
    latency_pinned: Fifo = .{},
    /// Zero while no latency work has reached this processor: the common
    /// case takes the queue path that never looks at priorities.
    latency_state: LatencyState = .{},
    stack_high_water: std.atomic.Value(usize) = .init(0),
    /// Group members of this processor between leaving their group and
    /// giving their stack back; written by the owner alone.
    retiring: std.atomic.Value(u32) = .init(0),
    /// What other threads write, on cache lines of their own.
    remote: Remote = .{},
    /// How many operations this processor's kernel queue holds on each
    /// descriptor (hashed); `Scheduler.holders` says which processors hold
    /// any.
    held: [descriptor_slots]u16 = @splat(0),
    tick: u32 = 0,
    /// The root's `run(mode)` the home processor is serving.
    serving: ?Serving = null,
    thread: ?std.Thread = null,
    /// For the monitor: odd while a task runs, moved at each switch in and
    /// out of one.
    passes: std.atomic.Value(u32) = .init(0),
    /// Where the running task was started.
    site: std.atomic.Value(usize) = .init(0),
    /// A blocking call's state, generation << 2 | 0 (none), 1 (in one), 2
    /// (the processor was handed to another thread meanwhile) or 3 (the
    /// home processor, given back to the home thread).
    blocking: std.atomic.Value(u32) = .init(0),

    /// The inboxes and flags other threads touch. Every wake reads the flags
    /// and every remote push writes an inbox, so the owner's own state must
    /// never share their lines: a producer's write would otherwise evict the
    /// lines a task switch reads.
    const Remote = struct {
        inbox: Inbox(Task, "next") = .{},
        cancels: Inbox(CancelMessage, "next") = .{},
        errands: Inbox(Errand, "next") = .{},
        /// Set while the processor may be waiting in the kernel: a producer
        /// that sees it wakes the loop.
        sleeping: std.atomic.Value(bool) = .init(false),
        /// Set from the root's return to its host (`Runtime.run`) until the
        /// root parks again: the scheduler is not looking and the host may
        /// be waiting on the loop's handle, so a producer wakes the loop as
        /// for `sleeping`.
        away: std.atomic.Value(bool) = .init(false),
        /// The home processor, held by another thread: the home thread
        /// wants it back for the root.
        home_wants: std.atomic.Value(bool) = .init(false),
        /// Aligns and pads the whole to cache lines.
        line: [0]u8 align(std.atomic.cache_line) = .{},

        comptime {
            assert(@alignOf(Remote) == std.atomic.cache_line and @sizeOf(Remote) % std.atomic.cache_line == 0);
        }
    };

    const LatencyState = packed struct(u16) {
        /// The latency queues may hold a task.
        ready: bool = false,
        /// Latency tasks run since a normal one had its turn.
        runs: u8 = 0,
        _: u7 = 0,

        fn idle(state: LatencyState) bool {
            return @as(u16, @bitCast(state)) == 0;
        }
    };

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
        /// A park whose stack holds pages a deeper park touched: once the
        /// task is off it, the loop may arm its trim.
        inspect: bool = false,
    };

    pub const Action = union(enum) {
        /// Back of the queue.
        yield,
        /// Parked; `after` (if any) runs now, off the task's stack.
        park: ?After,
        /// Ended; `after` runs now and releases what the task held.
        exit: After,
        /// Its processor went to another thread while it sat in a blocking
        /// call: it runs on next wherever a processor takes it.
        relocate,
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
        /// Woken by a task here: the LIFO slot.
        woken,
        /// An operation of its completed: the back of the queue.
        completed,
        /// Yielded: the back of the queue.
        yielded,
    };

    /// Makes `t` runnable on this processor; the owner's thread only.
    pub fn pushLocal(p: *Processor, t: *Task, how: How) void {
        p.scheduler.records.publish(t, p.index, .ready);
        t.processor = p;
        if (t.pins != 0 or t.policy.routed()) return p.pushRouted(t);
        switch (how) {
            .spawned, .woken => if (p.scheduler.scheduling == .stealing) {
                // A task in the LIFO slot cannot be stolen, so only one it
                // displaces into the queue is work for an idle processor.
                const displaced = p.lifo;
                p.lifo = t;
                if (displaced) |previous| {
                    p.pushQueue(previous);
                    p.scheduler.notify(p);
                }
                return;
            },
            .completed, .yielded => {},
        }
        p.pushQueue(t);
        p.scheduler.notify(p);
    }

    /// A task that stays on this processor or runs with latency priority.
    fn pushRouted(p: *Processor, t: *Task) void {
        var pinned = t.policy.home or t.pins > 0;
        if (pinned and t.execution.trim_pending) {
            p.scheduler.trims.beforeRun(&p.loop, t);
            pinned = t.policy.home or t.pins > 0;
        }
        if (t.policy.priority == .latency) {
            p.latency_state.ready = true;
            if (pinned) p.latency_pinned.push(t) else p.pushLatency(t);
            p.scheduler.notify(p);
            return;
        }
        if (pinned) p.pinned.push(t) else p.pushQueue(t);
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

    fn pushLatency(p: *Processor, t: *Task) void {
        p.latency_state.ready = true;
        if (p.latency.push(t)) return;
        var half: [run_queue.capacity / 2]*Task = undefined;
        if (p.latency.takeHalf(&half)) {
            p.scheduler.injectMany(&half);
            if (p.latency.push(t)) return;
        }
        p.scheduler.inject(t);
    }

    /// From any thread: `t` runs on this processor next time it looks.
    pub fn pushRemote(p: *Processor, t: *Task) void {
        p.scheduler.records.publish(t, p.index, .ready);
        _ = p.remote.inbox.push(t);
        p.wakeIfIdle();
    }

    /// From any thread: `e` runs on this processor's thread.
    pub fn send(p: *Processor, e: *Errand) void {
        _ = p.remote.errands.push(e);
        p.wakeIfIdle();
    }

    /// After a push from another thread: a processor waiting in the kernel,
    /// or whose root is back in its host, is woken through its loop.
    fn wakeIfIdle(p: *Processor) void {
        if (p.remote.sleeping.load(.seq_cst) or p.remote.away.load(.seq_cst)) wakeProcessor(p);
    }

    /// Whether this processor has a task to run or a message to serve: a
    /// host driving the home processor calls `run` again at once.
    pub fn hasWork(p: *const Processor) bool {
        return p.lifo != null or !p.local.isEmpty() or !p.pinned.isEmpty() or !p.latency.isEmpty() or !p.latency_pinned.isEmpty() or
            !p.remote.inbox.isEmpty() or !p.remote.cancels.isEmpty() or !p.remote.errands.isEmpty() or p.scheduler.injectedLen() > 0;
    }

    /// The owner's: this processor's kernel queue now holds one more
    /// operation on `fd`.
    pub fn hold(p: *Processor, fd: Io.File.Handle) void {
        const slot = descriptorSlot(fd);
        p.held[slot] += 1;
        if (p.held[slot] == 1) _ = p.scheduler.holders[slot].fetchOr(processorBit(p.index), .release);
    }

    /// The owner's: one fewer.
    pub inline fn release(p: *Processor, fd: Io.File.Handle) void {
        const slot = descriptorSlot(fd);
        p.held[slot] -= 1;
        if (p.held[slot] == 0) _ = p.scheduler.holders[slot].fetchAnd(~processorBit(p.index), .release);
    }

    /// From a wait's cancel hook, which runs with the task's lock held: this
    /// processor checks the task's wait for a cancel. One request is queued
    /// at a time; the one already queued checks whatever the task waits in
    /// when it is served.
    pub fn pushCancel(p: *Processor, m: *CancelMessage) void {
        if (m.queued) return;
        m.queued = true;
        _ = m.task.cancel_messages.fetchAdd(1, .release);
        _ = p.remote.cancels.push(m);
        p.wakeIfIdle();
    }

    /// Serves the cancel requests queued here: each task's wait is checked
    /// for a cancel on this processor's thread. True when there were any.
    pub fn serveCancels(p: *Processor) bool {
        var messages = p.remote.cancels.takeAll();
        const any = messages != null;
        while (messages) |m| {
            // The message and its task are alive until the count drops: the
            // task waits for it in `leaveWait`.
            messages = m.next;
            const t = m.task;
            t.lock();
            m.queued = false;
            // The hook re-checks that the wait is still this processor's and
            // cancels its operation in this loop.
            if (t.wait) |hook| hook.cancel(hook, t);
            t.unlock();
            _ = t.cancel_messages.fetchSub(1, .release);
        }
        return any;
    }

    /// The scheduler, on this processor's thread, until the runtime stops
    /// (workers) or forever (the home processor, which the root leaves).
    pub fn schedule(p: *Processor) void {
        if (p.scheduler.monitor != null) return p.scheduleMode(true);
        return p.scheduleMode(false);
    }

    // Monitoring is fixed at init. The normal loop needs no handoff checks
    // or thread-local reads at every task switch.
    fn scheduleMode(p: *Processor, comptime watched: bool) void {
        while (true) {
            if (watched and p.index == 0 and p.remote.home_wants.load(.seq_cst) and !p.on_home_thread) return p.giveBack();
            if (p.next()) |t| {
                p.runTask(watched, t);
                // The processor was handed on: this thread lets go of it.
                if (watched and held != p) return;
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
    inline fn next(p: *Processor) ?*Task {
        // Normal-only processors use the original queue path. Priority
        // accounting starts when local or injected latency work arrives.
        if (p.latency_state.idle()) return p.nextNormal();
        return p.nextByPriority();
    }

    fn nextByPriority(p: *Processor) ?*Task {
        // Eight latency tasks at most before offering normal work a turn.
        if (p.latency_state.runs < 8) if (p.takeLatency()) |t| {
            p.latency_state.runs += 1;
            return t;
        };
        if (p.nextNormal()) |t| {
            if (t.policy.priority == .normal) p.latency_state.runs = 0;
            return t;
        }
        return p.takeLatency();
    }

    fn takeLatency(p: *Processor) ?*Task {
        if (!p.latency_state.ready) return null;
        const task = p.latency_pinned.pop() orelse p.latency.pop();
        if (task == null) p.latency_state.ready = false;
        return task;
    }

    inline fn nextNormal(p: *Processor) ?*Task {
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
        var woken = p.remote.inbox.takeAll();
        while (woken) |t| {
            woken = t.next;
            p.pushLocal(t, .completed);
            any = true;
        }
        var errands = p.remote.errands.takeAll();
        while (errands) |e| {
            errands = e.next;
            e.run(e, p);
            any = true;
        }
        if (p.serveCancels()) any = true;
        return any;
    }

    /// Runs `t` until it switches back, then does what it asked.
    fn runTask(p: *Processor, comptime watched: bool, t: *Task) void {
        p.scheduler.records.publish(t, p.index, .running);
        p.current = t;
        t.processor = p;
        t.budget = p.scheduler.budget_ops;
        t.slice_start = no_slice;
        if (watched) {
            // The root runs on the home thread alone: another thread holding
            // the home processor gives it back instead.
            if (t.kind == .root and !p.on_home_thread) {
                p.pushLocal(t, .completed);
                return p.giveBack();
            }

            p.site.store(t.spawned_at, .monotonic);
            p.passes.store(p.passes.load(.monotonic) +% 1, .release);
        }
        var s: fiber.Switch = .{ .old = &p.sched_context, .new = &t.context };
        const back = fiber.switchTo(&s);
        p.afterSwitchMode(watched, true, t, back);
    }

    /// What the scheduler does once `t` has switched back to it: `t`'s stack
    /// is still now, so `t` may be published to whoever will resume it.
    pub fn afterSwitch(p: *Processor, t: *Task, back: *const fiber.Switch) void {
        if (p.scheduler.monitor != null) return p.afterSwitchMode(true, false, t, back);
        return p.afterSwitchMode(false, false, t, back);
    }

    inline fn afterSwitchMode(p: *Processor, comptime watched: bool, comptime was_running: bool, t: *Task, back: *const fiber.Switch) void {
        const message: *const Message = @alignCast(@fieldParentPtr("switch_", back)); // safe: the field belongs to this record
        const action = message.action;
        // A spare owns the processor after handoff: touch no mutable state.
        if (watched) {
            if (action == .relocate) return relocated(p.scheduler, t);
            // The first home entry parks the root without runTask starting it.
            if (was_running) p.passes.store(p.passes.load(.monotonic) +% 1, .release);
        }
        if (message.inspect or t.policy.measured) p.inspectStack(t, message.inspect);
        p.current = null;
        if (t.kind == .root) p.remote.away.store(false, .monotonic);
        if (action == .exit) p.scheduler.records.publish(t, p.index, .finished);
        switch (action) {
            .yield => p.pushLocal(t, .yielded),
            .park => |after| if (after) |a| a.func(a.context, t),
            .exit => |a| a.func(a.context, t),
            .relocate => unreachable, // unreachable: handoff above takes it before
        }
    }

    /// Cold stack work uses only the owning, suspended task. Ordinary
    /// switches do not load shared diagnostic state or inspect trim records.
    fn inspectStack(p: *Processor, t: *Task, trimmable: bool) void {
        const index = t.stack orelse return;
        if (t.policy.measured) {
            const depth = p.scheduler.stacks.highWater(index);
            if (depth > p.stack_high_water.load(.monotonic)) p.stack_high_water.store(depth, .monotonic);
        } else if (builtin.os.tag != .windows and trimmable) {
            p.scheduler.trims.arm(&p.loop, p.index, t, &p.scheduler.records, &p.scheduler.stacks, &p.scheduler.shared.stack_trims, fiber.stackPointer(&t.context));
        }
    }

    /// Polls the kernel and runs what became ready; true when something did.
    fn pollKernel(p: *Processor, mode: Loop.RunMode) bool {
        const n = p.loop.run(mode) catch |err| std.debug.panic("reactor: the kernel's queue failed: {t}", .{err});
        if (p.serving) |*s| s.delivered += n;
        return n > 0 or !p.pinned.isEmpty() or !p.local.isEmpty() or !p.latency_pinned.isEmpty() or !p.latency.isEmpty() or p.lifo != null;
    }

    /// Waits in the kernel until a completion, a timer, or a wake.
    fn block(p: *Processor) void {
        p.remote.sleeping.store(true, .seq_cst);
        defer p.remote.sleeping.store(false, .monotonic);
        // Publish idleness before checking the global queue. An injector
        // between the check and publication must still find someone to wake.
        p.scheduler.idle(p, true);
        defer p.scheduler.idle(p, false);
        if (!p.remote.inbox.isEmpty() or !p.remote.cancels.isEmpty() or !p.remote.errands.isEmpty() or p.scheduler.injectedLen() > 0) return;
        if (p.index != 0 and p.scheduler.stopping.load(.acquire)) return;
        // The home thread wants its processor back: its wake may have come
        // while this thread was still taking an earlier one.
        if (p.index == 0 and p.remote.home_wants.load(.seq_cst)) return;
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
            if (victim.latency.stealInto(&p.latency)) |t| {
                _ = p.scheduler.shared.steals.fetchAdd(1, .monotonic);
                p.pushLatency(t);
                return true;
            }
            if (victim.local.stealInto(&p.local)) |t| {
                _ = p.scheduler.shared.steals.fetchAdd(1, .monotonic);
                p.pushQueueFront(t);
                return true;
            }
        }
        return false;
    }

    /// Looks for work a while before waiting in the kernel: a burst of
    /// wakes then finds a processor awake. At
    /// most half the processors spin at once.
    fn spin(p: *Processor) bool {
        const s = p.scheduler;
        if (s.processors.len < 2) return false;
        if (s.shared.searching.load(.monotonic) * 2 >= s.processors.len) return false;
        _ = s.shared.searching.fetchAdd(1, .acq_rel);
        defer _ = s.shared.searching.fetchSub(1, .acq_rel);
        const start = p.loop.clock.awake();
        var round: u32 = 0;
        while (true) : (round += 1) {
            if (!p.remote.inbox.isEmpty() or !p.remote.cancels.isEmpty() or !p.remote.errands.isEmpty() or s.injectedLen() > 0) return true;
            if (round % 16 == 0) {
                // Its own completions first: free to ask for when the
                // kernel flags them.
                if (p.pollKernel(.nowait)) return true;
                if (p.steal()) return true;
                if (clocks.since(start, p.loop.clock.awake()).compare(spin_for) == .gt) return false;
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
    /// this thread's stack until the runtime stops; a spare, should the
    /// processor be handed on.
    pub fn work(p: *Processor) void {
        p.scheduler.serveThread(p);
    }

    /// On a thread holding the home processor for the home thread: back it
    /// goes, and this thread lets go.
    fn giveBack(p: *Processor) void {
        leave();
        p.blocking.store((p.blocking.load(.monotonic) & ~@as(u32, 3)) | 3, .release);
        system().futexWake(u32, &p.blocking.raw, 1);
    }

    /// The calling thread takes this processor over.
    fn adopt(p: *Processor) void {
        p.loop.adopt();
        p.on_home_thread = std.Thread.getCurrentId() == p.scheduler.home_thread;
        p.current = null;
        const passes = p.passes.load(.monotonic);
        if (passes & 1 == 1) p.passes.store(passes +% 1, .release);
        p.blocking.store(p.blocking.load(.monotonic) & ~@as(u32, 3), .release);
    }
};

/// The global queue's two classes of waiting task, under its lock.
const Injected = struct {
    normal_head: ?*Task = null,
    normal_tail: ?*Task = null,
    latency_head: ?*Task = null,
    latency_tail: ?*Task = null,
};

const Shared = struct {
    inject: aegis.BlockingGuarded(Injected) = .init(.{}),
    /// How many tasks the global queue holds, readable without its lock.
    inject_len: std.atomic.Value(u32) = .init(0),
    /// Processors waiting in their kernel.
    idle_count: std.atomic.Value(u32) = .init(0),
    /// Processors spinning for work before they wait.
    searching: std.atomic.Value(u32) = .init(0),
    stack_trims: std.atomic.Value(u64) = .init(0),
    /// Round robin for tasks started outside a processor under `per_core`.
    placement: std.atomic.Value(u32) = .init(0),
    steals: std.atomic.Value(u64) = .init(0),
    forced_yields: std.atomic.Value(u64) = .init(0),
    /// Aligns and pads the whole to cache lines.
    line: [0]u8 align(std.atomic.cache_line) = .{},

    comptime {
        assert(@alignOf(Shared) == std.atomic.cache_line and @sizeOf(Shared) % std.atomic.cache_line == 0);
    }
};

processors: []Processor,
root: *Task,
stacks: Stacks,
records: Records,
trims: Trims,
scheduling: Scheduling,
measure_stacks: bool = false,
budget_ops: u16,
/// The longest a task runs through cancelation points without waiting.
budget: clocks.Span,
/// Everything several processors write, on cache lines of their own: the
/// read-mostly fields around it are read at every task switch.
shared: Shared = .{},
/// Serializes the claims on persistent listener queues, which live in each
/// processor's own ring: no data of the scheduler's sits beside it.
listeners: aegis.Guarded(void) = .init({}),
/// Per descriptor slot, a bit for each processor whose kernel queue holds
/// an operation on it.
holders: [descriptor_slots]std.atomic.Value(u64) = @splat(.init(0)),
stopping: std.atomic.Value(bool) = .init(false),

/// The thread that built the runtime: the root runs there alone.
home_thread: std.Thread.Id,
/// Samples the processors, hands on those stuck in blocking calls, records
/// stalls; null when the options leave it off.
monitor: ?*Monitor = null,
/// Threads waiting for a processor (handoff only).
spares: Spares = undefined,

/// The system's own `Io`, for the few waits a thread outside any task
/// makes on a kernel futex.
pub fn system() Io {
    return Io.Threaded.global_single_threaded.io();
}

threadlocal var held: ?*Processor = null;

/// The processor the calling thread holds, read afresh at every call.
///
/// A task moves between threads at a switch, which the compiler cannot
/// see: within one function it computes a thread-local's address once and
/// reuses it, so after a park inlined into the same function a task would
/// read the thread it left. Never inlined, so each call computes the
/// address on the thread that makes it.
noinline fn heldNow() ?*Processor {
    return held;
}

/// The calling thread now holds `p`.
pub fn enter(p: *Processor) void {
    assert(heldNow() == null);
    held = p;
    p.on_home_thread = std.Thread.getCurrentId() == p.scheduler.home_thread;
}

pub fn leave() void {
    held = null;
}

/// The processor the calling thread holds, if any.
pub fn processor() ?*Processor {
    return heldNow();
}

/// The task running on the calling thread, if it is one of this
/// scheduler's.
pub fn current() ?*Task {
    const p = heldNow() orelse return null;
    return p.current;
}

/// Persistent listener queues stay on the first processor that accepts.
/// Claims are serialized, but the descriptor tables are atomically readable
/// by close routing. No ring or owner-only record is touched here.
pub fn listenerOwner(s: *Scheduler, fd: Io.File.Handle, caller: *Processor) *Processor {
    if (comptime builtin.os.tag != .linux) return caller;
    if (caller.loop.backend != .io_uring) return caller;
    var claiming = s.listeners.acquire();
    defer claiming.deinit();
    for (s.processors) |*p| if (p.loop.backend.io_uring.accepts.contains(fd)) return p;
    if (caller.loop.backend.io_uring.accepts.reserve(fd)) return caller;
    for (s.processors) |*p| if (p.loop.backend.io_uring.accepts.reserve(fd)) return p;
    // No accept-ahead slot: an ordinary, task-owned accept on this ring.
    return caller;
}

// Parking and waking.

/// Suspends the running task. `after` runs on the scheduler once the
/// task's stack is still: there it publishes the task to whoever will
/// wake it (a futex bucket, a lane, an awaited future).
pub fn park(after: ?Processor.After) void {
    const p = heldNow().?;
    const t = p.current.?;
    var message: Processor.Message = .{
        .switch_ = .{ .old = &t.context, .new = &p.sched_context },
        .action = .{ .park = after },
    };
    if (t.stack != null) {
        const bytes = t.stack_top - @intFromPtr(&message); // safe: message is a live frame below this task's owned stack top
        const deepest = p.scheduler.records.parked(t, p.index, bytes);
        message.inspect = deepest > bytes + trim_gap;
    }
    _ = fiber.switchTo(&message.switch_);
}

/// To the back of the queue.
pub fn yield() void {
    const p = heldNow().?;
    const t = p.current.?;
    var message: Processor.Message = .{
        .switch_ = .{ .old = &t.context, .new = &p.sched_context },
        .action = .yield,
    };
    _ = fiber.switchTo(&message.switch_);
}

/// Ends the running task: `after` runs once it is off its stack.
pub fn exit(after: Processor.After) noreturn {
    const p = heldNow().?;
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
    const p = heldNow() orelse return;
    const t = p.current orelse return;
    if (t.budget > 0) {
        t.budget -= 1;
        if (t.budget % 8 != 0) return;
        const now = p.loop.clock.awake();
        if (t.slice_start.eql(no_slice)) {
            t.slice_start = now;
            return;
        }
        if (clocks.since(t.slice_start, now).compare(s.budget) == .lt) return;
    }
    _ = s.shared.forced_yields.fetchAdd(1, .monotonic);
    yield();
}

/// Makes a parked task runnable, from any thread.
pub fn ready(s: *Scheduler, t: *Task, how: Processor.How) void {
    const target: ?*Processor = if (t.policy.home or t.pins > 0 or s.scheduling == .per_core)
        @ptrCast(@alignCast(t.processor)) // safe: only processors are stored there
    else
        null;
    if (heldNow()) |p| if (p.scheduler == s) {
        if (target == null or target == p) return p.pushLocal(t, how);
        return target.?.pushRemote(t);
    };
    if (target) |tp| return tp.pushRemote(t);
    s.inject(t);
}

/// Leaves the wait `t` entered: its hook is gone, and so is every request
/// to check it, since those live in the waiting frame. A request the
/// processor has not served yet is served by it, on its own thread, or here
/// when this is that thread; this task gives its processor the turn meanwhile.
pub fn leaveWait(t: *Task) void {
    t.leaveWait();
    while (t.cancel_messages.load(.acquire) != 0) {
        if (heldNow()) |p| _ = p.serveCancels();
        if (t.cancel_messages.load(.acquire) == 0) return;
        std.atomic.spinLoopHint();
        if (current() != null) yield();
    }
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
    var heads: [2]?*Task = .{ null, null };
    var tails: [2]?*Task = .{ null, null };
    var task = first;
    // This chain is exclusively ours until publication. Split it while
    // publishing summaries, then append each class under one short lock.
    while (true) {
        const next_task = task.next;
        s.records.publish(task, std.math.maxInt(u16), .ready);
        task.next = null;
        const class = @backingInt(task.policy.priority);
        if (tails[class]) |tail| tail.next = task else heads[class] = task;
        tails[class] = task;
        if (task == last) break;
        task = next_task.?;
    }
    var locked = s.shared.inject.acquireUncancelable(system());
    const queue = locked.value();
    if (heads[0]) |head| {
        if (queue.normal_tail) |tail| tail.next = head else queue.normal_head = head;
        queue.normal_tail = tails[0];
    }
    if (heads[1]) |head| {
        if (queue.latency_tail) |tail| tail.next = head else queue.latency_head = head;
        queue.latency_tail = tails[1];
    }
    _ = s.shared.inject_len.fetchAdd(count, .release);
    locked.deinit(system());
    s.wakeIdle();
}

pub fn injectedLen(s: *const Scheduler) u32 {
    return s.shared.inject_len.load(.acquire);
}

/// One task from the global queue for `p`.
pub fn takeInjected(s: *Scheduler, p: *Processor) ?*Task {
    if (s.shared.inject_len.load(.acquire) == 0) return null;
    var locked = s.shared.inject.acquireUncancelable(system());
    defer locked.deinit(system());
    const queue = locked.value();
    const latency = queue.latency_head != null and (p.latency_state.runs < 8 or queue.normal_head == null);
    const t = (if (latency) queue.latency_head else queue.normal_head) orelse return null;
    if (latency) {
        p.latency_state.runs +|= 1;
        queue.latency_head = t.next;
        if (queue.latency_head == null) queue.latency_tail = null;
    } else {
        queue.normal_head = t.next;
        if (queue.normal_head == null) queue.normal_tail = null;
    }
    t.next = null;
    _ = s.shared.inject_len.fetchSub(1, .release);
    return t;
}

// Idle processors.

/// `p` is about to wait in the kernel (or stopped waiting).
pub fn idle(s: *Scheduler, p: *Processor, waiting: bool) void {
    _ = p;
    if (waiting) {
        _ = s.shared.idle_count.fetchAdd(1, .seq_cst);
    } else {
        _ = s.shared.idle_count.fetchSub(1, .seq_cst);
        // The monitor parks while every processor waits: one is back.
        if (s.monitor) |m| if (m.parked.load(.seq_cst)) m.poke();
    }
}

/// Whether every processor waits in its kernel.
pub fn allIdle(s: *const Scheduler) bool {
    return s.shared.idle_count.load(.seq_cst) == s.processors.len;
}

// Blocking calls and handoff.

/// A blocking call under way on a worker, which the monitor may hand the
/// worker's processor away from meanwhile.
pub const Blocking = struct {
    processor: *Processor,
    task: *Task,
    word: u32,
    /// The scheduler of the thread making the call: where the task leaves
    /// that thread if the processor goes elsewhere meanwhile.
    home: fiber.Context,
};

/// Before a call that may block its thread (std's file code, borrowed on a
/// worker): while it lasts, the processor is no longer this thread's to
/// touch, and the monitor hands it to a spare thread if the call goes on
/// past `handoff_after`. Null where that cannot be: no monitor or no
/// handoff (io_uring, `per_core`), a task pinned (the root never
/// leaves its thread, so the home processor comes back to it), a task held
/// on its processor. Nothing between this and `leaveBlocking` may touch
/// the scheduler.
pub fn enterBlocking() ?Blocking {
    const p = held orelse return null;
    const m = if (p.scheduler.monitor) |m| m else return null;
    if (!m.handoff) return null;
    const t = p.current orelse return null;
    if (t.pins > 0 or (t.policy.home and t.kind != .root)) return null;
    const word = ((p.blocking.load(.monotonic) >> 2) +% 1) << 2 | 1;
    const b: Blocking = .{ .processor = p, .task = t, .word = word, .home = p.sched_context };
    p.blocking.store(word, .release);
    m.poke();
    return b;
}

/// After the call: the task goes on on this thread if it still holds the
/// processor, else leaves the thread (which waits as a spare) and goes on
/// wherever a processor takes it next.
pub fn leaveBlocking(b: *Blocking) void {
    if (b.processor.blocking.cmpxchgStrong(b.word, b.word & ~@as(u32, 3), .acquire, .monotonic) == null) return;
    if (b.task.kind == .root) {
        // The root never leaves its thread: the processor comes back.
        b.processor.remote.home_wants.store(true, .seq_cst);
        wakeProcessor(b.processor);
        reclaim(b.processor);
        b.processor.sched_context = b.home;
        b.processor.current = b.task;
        return;
    }
    var message: Processor.Message = .{
        .switch_ = .{ .old = &b.task.context, .new = &b.home },
        .action = .relocate,
    };
    _ = fiber.switchTo(&message.switch_);
}

/// On the home thread: waits until the home processor is given back
/// (`giveBack`), then holds it again.
pub fn reclaim(p: *Processor) void {
    while (true) {
        const word = p.blocking.load(.acquire);
        if (word & 3 == 3) break;
        system().futexWaitUncancelable(u32, &p.blocking.raw, word);
    }
    p.remote.home_wants.store(false, .monotonic);
    if (held == null) enter(p);
    p.adopt();
}

/// On the thread that lost its processor, `t` off its stack now: the
/// thread lets go, and `t` goes to the global queue.
fn relocated(s: *Scheduler, t: *Task) void {
    leave();
    s.inject(t);
}

/// From the monitor: hands `p`, whose thread has sat in a blocking call
/// (`word`) too long, to a spare thread. False when there is none to hand
/// it to, or the call has ended.
pub fn handOff(s: *Scheduler, p: *Processor, word: u32) bool {
    if (!s.spares.reserve(serveThread, s)) return false;
    if (p.blocking.cmpxchgStrong(word, (word & ~@as(u32, 3)) | 2, .acq_rel, .monotonic) != null) return false;
    s.spares.post(p);
    return true;
}

/// The monitor thread's body.
pub fn watch(s: *Scheduler) void {
    s.monitor.?.run(s);
}

/// A thread's body: holds `first` (a spare: waits for a processor), runs
/// its scheduler, and waits as a spare whenever the processor is handed
/// on, until the runtime stops.
pub fn serveThread(s: *Scheduler, first: ?*Processor) void {
    var fresh = first == null;
    var next = first;
    while (true) {
        const p: *Processor = next orelse @ptrCast(@alignCast(s.spares.wait(&s.stopping, fresh) orelse return)); // safe: only processors are posted
        fresh = false;
        next = null;
        enter(p);
        p.adopt();
        p.schedule();
        // Still held: the runtime stops.
        if (held == p) {
            if (comptime builtin.os.tag == .linux) if (p.loop.backend == .io_uring) p.loop.backend.io_uring.drainListeners();
            leave();
            return;
        }
    }
}

/// `p` has more work than it can run now: wake an idle processor to steal
/// it, if there is one.
pub fn notify(s: *Scheduler, p: *Processor) void {
    if (s.scheduling != .stealing) return;
    if (s.shared.idle_count.load(.seq_cst) == 0) return;
    // A spinning processor will find it.
    if (s.shared.searching.load(.seq_cst) > 0) return;
    const runnable = p.local.len() + p.latency.len() + @intFromBool(p.lifo != null);
    if (runnable == 0) return;
    // Between tasks, this processor runs the one task it has next: a
    // processor woken for it would only take it away.
    if (runnable == 1 and p.current == null) return;
    s.wakeIdle();
}

fn wakeIdle(s: *Scheduler) void {
    // A host outside run() is waiting on the home loop's handle, rather
    // than counted as a processor waiting in its kernel.
    const home = &s.processors[0];
    if (home.remote.away.load(.seq_cst)) wakeProcessor(home);
    if (s.shared.idle_count.load(.seq_cst) == 0) return;
    for (s.processors) |*other| {
        if (other.remote.sleeping.load(.seq_cst)) {
            wakeProcessor(other);
            return;
        }
    }
}

/// Every processor's thread looks at its queues again.
pub fn wakeAll(s: *Scheduler) void {
    // Stop joins workers without driving the source ring again.
    for (s.processors) |*p| p.loop.wake();
}

// Tasks.

/// A new task on a free stack, not yet runnable, with `extra` bytes
/// (aligned to `extra_align`) below its record for the caller's context
/// and result; null when every stack is in use. `entry` runs first.
pub inline fn create(s: *Scheduler, kind: Task.Kind, extra: usize, extra_align: std.mem.Alignment, entry: *const fn (t: *Task) noreturn) ?struct { *Task, [*]u8 } {
    const taken = s.stacks.take() orelse return null;
    return s.createAt(taken.stack, taken.at, kind, extra, extra_align, entry, .normal);
}

pub fn createWith(s: *Scheduler, kind: Task.Kind, extra: usize, extra_align: std.mem.Alignment, entry: *const fn (t: *Task) noreturn, size: ?aegis.units.Bytes(usize), priority: Task.Priority) ?struct { *Task, [*]u8 } {
    const taken = s.stacks.takeSized(size) orelse return null;
    return s.createAt(taken.stack, taken.at, kind, extra, extra_align, entry, priority);
}

inline fn createAt(s: *Scheduler, index: Stacks.Stack, location: Stacks.Location, kind: Task.Kind, extra: usize, extra_align: std.mem.Alignment, entry: *const fn (t: *Task) noreturn, priority: Task.Priority) ?struct { *Task, [*]u8 } {
    const pool = location.pool;
    const top = pool.top(location.slot);
    const record_at = std.mem.alignBackward(usize, top - @sizeOf(Task), @alignOf(Task));
    const extra_at = extra_align.backward(record_at - extra);
    const sp = std.mem.alignBackward(usize, extra_at, 16);
    if (sp - pool.bottom(location.slot) < pool.size / 2 or !pool.reach(location.slot, sp - 48)) {
        s.stacks.give(index);
        return null;
    }
    if (s.measure_stacks and !s.stacks.paint(index, extra_at)) {
        s.stacks.give(index);
        return null;
    }
    const t: *Task = @ptrFromInt(record_at);
    // The task builder assigns its start/context and spawn site before
    // publication; runTask assigns execution budgets before entering it.
    // Cancellation and queue ownership are initialized here as usual.
    t.* = .{
        .kind = kind,
        .stack = index,
        .stack_top = top,
        .policy = .{ .home = s.scheduling == .per_core, .priority = priority, .measured = s.measure_stacks },
        .start = undefined,
        .spawned_at = undefined,
        .budget = undefined,
        .slice_start = undefined,
    };
    t.context = fiber.initial(pool.stack(location.slot), sp, taskEntry, @ptrCast(@constCast(entry))); // safe: `taskEntry` casts it back to the entry it is
    return .{ t, @ptrFromInt(extra_at) };
}

/// Waits until every group member that has left its group has given its
/// stack back, so an awaiter that saw an empty group sees no stack in use
/// by it. A member counts itself in before it leaves the group.
pub fn awaitRetired(s: *Scheduler) void {
    for (s.processors) |*p| while (p.retiring.load(.acquire) != 0) std.atomic.spinLoopHint();
}

/// Gives back the stack of a task that has ended and been forgotten.
pub inline fn release(s: *Scheduler, t: *Task) void {
    const index = t.stack.?;
    s.stacks.ended(index, fiber.committedLimit(&t.context));
    s.records.release(t);
    fiber.deinit(&t.context);
    t.* = undefined;
    s.stacks.give(index);
}

/// Where a newly made task runs first: the creator's processor, or,
/// outside any, the next by round robin under `per_core`.
pub inline fn place(s: *Scheduler, t: *Task) void {
    s.records.created(t);
    if (heldNow()) |p| if (p.scheduler == s) {
        t.processor = p;
        return p.pushLocal(t, .spawned);
    };
    if (s.scheduling == .per_core) {
        const i = s.shared.placement.fetchAdd(1, .monotonic) % s.processors.len;
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

fn wakeProcessor(target: *Processor) void {
    if (heldNow()) |source| if (source.scheduler == target.scheduler)
        return loop_internal.wakeFrom(&target.loop, &source.loop);
    target.loop.wake();
}
