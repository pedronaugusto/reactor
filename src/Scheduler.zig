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

const clocks = @import("clock.zig");
const shuttle = @import("shuttle");
const stacks_ = @import("scheduler/stacks.zig");
const Loop = @import("Loop.zig");
const loop_internal = @import("loop/internal.zig");
const Task = @import("scheduler/Task.zig");
const Records = @import("scheduler/Records.zig");
const Trims = @import("scheduler/Trims.zig");
const Raised = @import("sync/Raised.zig");
const run_queue = @import("scheduler/run_queue.zig");
const RunQueue = run_queue.RunQueue(Task);
const Inbox = @import("scheduler/inbox.zig").Inbox;
pub const Monitor = @import("scheduler/Monitor.zig");
pub const Spares = @import("scheduler/Spares.zig").Of(Processor);

pub const Scheduling = enum { stealing, per_core };

/// Whether this target can run reactor's tasks.
pub const supported = shuttle.supported and switch (builtin.os.tag) {
    .linux, .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    .windows => builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64,
    else => false,
};

/// Work another thread hands a processor, run on its thread.
pub const Errand = struct {
    next: ?*Errand = null,
    run: *const fn (e: *Errand, p: *Processor) void,
};

/// Work to do once a parked task is off its stack (`Task.After`).
pub const After = Task.After;

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

/// The processors whose kernel queues hold an operation on a descriptor
/// slot: a bit each (`processorBit`).
const Holders = enum(u64) {
    none = 0,
    _,

    fn with(h: Holders, bit: u64) Holders {
        return @fromBackingInt(@backingInt(h) | bit);
    }

    fn without(h: Holders, bit: u64) Holders {
        return @fromBackingInt(@backingInt(h) & ~bit);
    }

    fn has(h: Holders, bit: u64) bool {
        return @backingInt(h) & bit != 0;
    }

    /// Adds or takes `bit` in `cell`.
    fn mark(cell: *aegis.Atomic(Holders), bit: u64, comptime held: bool) void {
        var seen = cell.load(.monotonic);
        while (cell.cmpxchgWeak(seen, if (held) seen.with(bit) else seen.without(bit), .release, .monotonic)) |found| seen = found;
    }
};

/// A processor's bit in `holders`; beyond 64 processors bits are shared.
fn processorBit(index: u16) u64 {
    return @as(u64, 1) << @intCast(index % 64);
}

/// Whether processor `index`'s kernel queue may hold an operation on `fd`.
pub fn holds(s: *const Scheduler, index: u16, fd: Io.File.Handle) bool {
    if (comptime builtin.os.tag == .linux) if (s.processors[index].loop.backend == .io_uring) {
        if (s.processors[index].loop.backend.io_uring.contains(fd)) return true;
    };
    return s.holders[descriptorSlot(fd)].load(.acquire).has(processorBit(index));
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
    /// Whether the owner lends the processor while a task runs its own code
    /// or sits in a blocking call, so the monitor can hand it to a spare
    /// thread (`lease`); fixed at init.
    lends: bool = false,
    loop: Loop,
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
    /// The deepest any task reached on a stack of this processor's.
    stack_high_water: aegis.Atomic(stacks_.Bytes) = .init(.fromRaw(0)),
    /// Group members of this processor between leaving their group and
    /// giving their stack back; written by the owner alone.
    retiring: aegis.Atomic(Tasks) = .init(.fromRaw(0)),
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
    passes: aegis.Atomic(Passes) = .init(.fromRaw(0)),
    /// Where the running task was started.
    site: aegis.Atomic(Site) = .init(.fromRaw(0)),
    /// The root, ready, while another thread holds the home processor and
    /// the home thread has not asked for it yet; given back with it.
    root_aside: bool = false,
    /// What the monitor did with the processor (`Lease`), its generation
    /// moving at every change of owner, so a word one owner held it with
    /// never matches under the next.
    // aegis: boundary: a futex word: the kernel waits on this u32's address
    lease: std.atomic.Value(u32) = .init(0),
    /// The seat of the thread holding the processor, which the monitor
    /// reads to see whether it is lent.
    owner: aegis.Atomic(?*Seat) = .init(null),

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
        sleeping: Raised = .{},
        /// Set from the root's return to its host (`Runtime.run`) until the
        /// root parks again: the scheduler is not looking and the host may
        /// be waiting on the loop's handle, so a producer wakes the loop as
        /// for `sleeping`.
        away: Raised = .{},
        /// The home processor, held by another thread: the home thread
        /// wants it back for the root.
        home_wants: Raised = .{},
        /// Aligns and pads the whole to cache lines.
        line: [0]u8 align(std.atomic.cache_line) = .{},

        comptime {
            assert(@alignOf(Remote) == std.atomic.cache_line);
            assert(@sizeOf(Remote) % std.atomic.cache_line == 0);
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
        /// The processor whose scheduler the task switches to.
        processor: *Processor,
        action: Action,
        /// A park whose stack holds pages a deeper park touched: once the
        /// task is off it, the loop may arm its trim.
        inspect: bool = false,
        /// What the switch runs on the scheduler's side, which finds the
        /// message from it.
        after: shuttle.handoff.After = .{ .run = afterSwitch },
    };

    pub const Action = union(enum) {
        /// Back of the queue.
        yield,
        /// Parked; `after` (if any) runs now, off the task's stack.
        park: ?*After,
        /// Ended; `done` runs now and releases what the task held.
        exit: *const fn (t: *Task) void,
        /// Its processor went to another thread while it sat in a blocking
        /// call: it runs on next wherever a processor takes it.
        relocate,
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
        t.processor_loop = &p.loop;
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
        if (p.remote.sleeping.raised(.seq_cst) or p.remote.away.raised(.seq_cst)) wakeProcessor(p);
    }

    /// Whether this processor has a task to run or a message to serve: a
    /// host driving the home processor calls `run` again at once.
    pub fn hasWork(p: *const Processor) bool {
        return p.hasOwnWork() or p.scheduler.injectedLen() > 0;
    }

    /// Whether this processor has a task to run or a message to serve of its
    /// own, the global queue aside: what only its owner can do.
    pub fn hasOwnWork(p: *const Processor) bool {
        return p.lifo != null or !p.local.isEmpty() or !p.pinned.isEmpty() or !p.latency.isEmpty() or !p.latency_pinned.isEmpty() or
            !p.remote.inbox.isEmpty() or !p.remote.cancels.isEmpty() or !p.remote.errands.isEmpty();
    }

    /// The owner's: this processor's kernel queue now holds one more
    /// operation on `fd`.
    pub fn hold(p: *Processor, fd: Io.File.Handle) void {
        const slot = descriptorSlot(fd);
        p.held[slot] += 1;
        if (p.held[slot] == 1) Holders.mark(&p.scheduler.holders[slot], processorBit(p.index), true);
    }

    /// The owner's: one fewer.
    pub inline fn release(p: *Processor, fd: Io.File.Handle) void {
        const slot = descriptorSlot(fd);
        p.held[slot] -= 1;
        if (p.held[slot] == 0) Holders.mark(&p.scheduler.holders[slot], processorBit(p.index), false);
    }

    /// From a wait's cancel hook, which runs with the task's lock held: this
    /// processor checks the task's wait for a cancel. One request is queued
    /// at a time; the one already queued checks whatever the task waits in
    /// when it is served.
    pub fn pushCancel(p: *Processor, m: *CancelMessage) void {
        if (m.queued) return;
        m.queued = true;
        _ = m.task.cancel_messages.fetchAddWrapping(.fromRaw(1), .release);
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
            _ = t.cancel_messages.fetchSubWrapping(.fromRaw(1), .release);
        }
        return any;
    }

    /// The scheduler, on this processor's thread, until the runtime stops
    /// (workers) or forever (the home processor, which the root leaves).
    pub fn schedule(p: *Processor) void {
        // The thread's own seat, read once: a task switches back to the
        // context this loop saves there.
        const own = seatNow();
        if (p.scheduler.monitor != null) return p.scheduleMode(true, own);
        return p.scheduleMode(false, own);
    }

    // Monitoring is fixed at init. The normal loop needs no handoff checks
    // or thread-local reads at every task switch.
    fn scheduleMode(p: *Processor, comptime watched: bool, own: *Seat) void {
        while (true) {
            if (watched and p.index == 0 and p.remote.home_wants.raised(.seq_cst) and !p.on_home_thread) {
                if (p.root_aside) {
                    p.root_aside = false;
                    p.pushLocal(p.scheduler.root, .completed);
                }
                return p.giveBack();
            }
            if (p.next()) |t| {
                p.runTask(watched, t, own);
                // The processor was handed on: this thread lets go of it.
                if (watched and own.held != p) return;
                continue;
            }
            if (p.drainInboxes()) continue;
            if (p.index != 0 and p.scheduler.stopping.raised(.acquire)) return;
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
    fn runTask(p: *Processor, comptime watched: bool, t: *Task, own: *Seat) void {
        p.scheduler.records.publish(t, p.index, .running);
        p.current = t;
        t.processor_loop = &p.loop;
        t.budget = p.scheduler.budget_ops;
        t.slice_start = no_slice;
        if (watched) {
            // The root runs on the home thread alone: another thread holding
            // the home processor gives it back instead.
            if (t.kind == .root and !p.on_home_thread) {
                p.current = null;
                // Kept aside until the home thread asks for its processor:
                // given back now, it would sit with no thread to run it
                // while the home thread still runs a task of its own.
                if (!p.remote.home_wants.raised(.seq_cst)) {
                    p.root_aside = true;
                    return;
                }
                p.pushLocal(t, .completed);
                return p.giveBack();
            }

            p.site.store(.fromRaw(t.spawned_at), .monotonic);
            // The count wraps through zero, which keeps the parity alternating.
            p.passes.store(p.passes.load(.monotonic).add(.fromRaw(1)) catch .fromRaw(0), .release);
        }
        own.task = t;
        t.seat_context = &own.context;
        // The task's switch back runs `afterSwitch` here, once its stack is still.
        shuttle.handoff.switchTo(&own.context, &t.context, null);
    }

    /// What the scheduler does once a task has switched back to it, run
    /// by the switch on the scheduler's side: the task's stack is still
    /// now, so it may be published to whoever will resume it.
    pub fn afterSwitch(after: *shuttle.handoff.After, from: *shuttle.Context) void {
        const message: *const Message = @fieldParentPtr("after", after);
        const t: *Task = @fieldParentPtr("context", from);
        const p = message.processor;
        if (p.scheduler.monitor != null) return p.afterSwitchMode(true, t, message);
        return p.afterSwitchMode(false, t, message);
    }

    inline fn afterSwitchMode(p: *Processor, comptime watched: bool, t: *Task, message: *const Message) void {
        const action = message.action;
        // A spare owns the processor after handoff: touch no mutable state.
        if (watched) {
            if (action == .relocate) return relocated(p.scheduler, t);
            // Odd while a task `runTask` started runs: the root's first park,
            // which enters the home scheduler, ends no such run.
            const passes = p.passes.load(.monotonic).raw();
            if (passes & 1 == 1) p.passes.store(.fromRaw(passes +% 1), .release);
        }
        if (message.inspect or t.policy.measured) p.inspectStack(t, message.inspect);
        p.current = null;
        if (t.kind == .root) p.remote.away.clear(.monotonic);
        if (action == .exit) p.scheduler.records.publish(t, p.index, .finished);
        switch (action) {
            .yield => p.pushLocal(t, .yielded),
            .park => |after| if (after) |a| a.run(a, t),
            .exit => |done| done(t),
            .relocate => unreachable, // unreachable: handoff above takes it before
        }
    }

    /// Cold stack work uses only the owning, suspended task. Ordinary
    /// switches do not load shared diagnostic state or inspect trim records.
    fn inspectStack(p: *Processor, t: *Task, trimmable: bool) void {
        if (t.stack == null) return;
        if (t.policy.measured) {
            const depth = stacks_.highWater(p.scheduler.stackOf(t));
            if (p.stack_high_water.load(.monotonic).compare(.fromRaw(depth)) == .lt) p.stack_high_water.store(.fromRaw(depth), .monotonic);
        } else if (builtin.os.tag != .windows and trimmable) {
            p.scheduler.trims.arm(&p.loop, p.index, t, &p.scheduler.records, &p.scheduler.stacks, &p.scheduler.shared.stack_trims, t.context.stackPointer());
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
        _ = p.remote.sleeping.raise(.seq_cst);
        defer p.remote.sleeping.clear(.monotonic);
        // Publish idleness before checking the global queue. An injector
        // between the check and publication must still find someone to wake.
        p.scheduler.idle(p, true);
        defer p.scheduler.idle(p, false);
        if (!p.remote.inbox.isEmpty() or !p.remote.cancels.isEmpty() or !p.remote.errands.isEmpty() or p.scheduler.injectedLen() > 0) return;
        if (p.index != 0 and p.scheduler.stopping.raised(.acquire)) return;
        // The home thread wants its processor back: its wake may have come
        // while this thread was still taking an earlier one.
        if (p.index == 0 and p.remote.home_wants.raised(.seq_cst)) return;
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
            .within => |deadline| s.delivered > 0 or (s.polled and p.passed(deadline)),
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
                _ = p.scheduler.shared.steals.fetchAddWrapping(.fromRaw(1), .monotonic);
                p.pushLatency(t);
                return true;
            }
            if (victim.local.stealInto(&p.local)) |t| {
                _ = p.scheduler.shared.steals.fetchAddWrapping(.fromRaw(1), .monotonic);
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
        if (@as(usize, s.shared.searching.load(.monotonic).raw()) * 2 >= s.processors.len) return false;
        _ = s.shared.searching.fetchAddWrapping(.fromRaw(1), .acq_rel);
        defer _ = s.shared.searching.fetchSubWrapping(.fromRaw(1), .acq_rel);
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
        const word = seatNow().lease;
        // A look of the monitor's may be under way: it ends with the word
        // as it found it.
        while (p.lease.cmpxchgWeak(word, Lease.with(word, Lease.home_back), .release, .monotonic)) |seen| {
            assert(seen == word or seen == Lease.with(word, Lease.claimed));
            std.atomic.spinLoopHint();
        }
        leave();
        system().futexWake(u32, &p.lease.raw, 1);
    }

    /// The calling thread takes this processor over.
    fn adopt(p: *Processor) void {
        p.loop.adopt();
        p.on_home_thread = std.Thread.getCurrentId() == p.scheduler.home_thread;
        p.current = null;
        const passes = p.passes.load(.monotonic).raw();
        if (passes & 1 == 1) p.passes.store(.fromRaw(passes +% 1), .release);
        p.holdFrom(seatNow());
    }

    /// The thread at `holder` holds `p` from here, in the runtime, in a new
    /// generation: no word the last owner held it with matches again.
    pub fn holdFrom(p: *Processor, holder: *Seat) void {
        const word = Lease.next(p.lease.load(.monotonic)) | Lease.held;
        holder.lease = word;
        holder.stage.store(holder.stage.load(.monotonic).moved(.inside), .monotonic);
        // The owner before the word: a monitor that reads the new word reads
        // the new owner after it.
        p.owner.store(holder, .release);
        p.lease.store(word, .release);
    }
};

/// The global queue's two classes of waiting task, under its lock.
const Injected = struct {
    normal_head: ?*Task = null,
    normal_tail: ?*Task = null,
    latency_head: ?*Task = null,
    latency_tail: ?*Task = null,
};

/// Where a task was spawned: the address its spawn was called from.
pub const Site = aegis.id.Id(Task, usize);
/// Switches into and out of tasks on a processor: odd while one runs.
const Passes = aegis.units.Count(Processor, u32);
/// A number of tasks held at once.
const Tasks = aegis.units.Count(Task, u32);
/// A number of processors.
const Processors = aegis.units.Count(Processor, u32);
/// A number of things that happened to tasks, over the runtime's life.
const TaskEvents = aegis.units.Count(Task, u64);

const Shared = struct {
    inject: aegis.BlockingGuarded(Injected) = .init(.{}),
    /// How many tasks the global queue holds, readable without its lock.
    inject_len: aegis.Atomic(Tasks) = .init(.fromRaw(0)),
    /// Processors waiting in their kernel.
    idle_count: aegis.Atomic(Processors) = .init(.fromRaw(0)),
    /// Processors spinning for work before they wait.
    searching: aegis.Atomic(Processors) = .init(.fromRaw(0)),
    /// Stacks given back to the system in part (`Trims`).
    stack_trims: aegis.Atomic(Trims.Count) = .init(.fromRaw(0)),
    /// Round robin for tasks started outside a processor under `per_core`.
    placement: aegis.Atomic(Processors) = .init(.fromRaw(0)),
    /// Tasks taken from another processor's queue.
    steals: aegis.Atomic(TaskEvents) = .init(.fromRaw(0)),
    /// Tasks made to yield by their budget.
    forced_yields: aegis.Atomic(TaskEvents) = .init(.fromRaw(0)),
    /// Aligns and pads the whole to cache lines.
    line: [0]u8 align(std.atomic.cache_line) = .{},

    comptime {
        assert(@alignOf(Shared) == std.atomic.cache_line);
        assert(@sizeOf(Shared) % std.atomic.cache_line == 0);
    }
};

processors: []Processor,
root: *Task,
stacks: shuttle.Pool,
/// The default class's size: what a task that asks no size takes.
stack_size: stacks_.Bytes,
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
holders: [descriptor_slots]aegis.Atomic(Holders) = @splat(.init(.none)),
stopping: Raised = .{},
/// What a future of this scheduler's holds as its awaiter once it is done
/// (`Task.awaiter`): its address alone says so, and nothing reads or writes
/// the record.
finished: Task.Awaiter = .{ .task = null },

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

/// What a thread keeps of its own: the processor it holds, its
/// scheduler's context, which the tasks it runs switch back to, and the
/// task it runs. A processor moves between threads; a task that loses its
/// processor while it runs its own code finds its way back through the
/// thread's seat, never through the processor, which is another's by then.
pub const Seat = struct {
    held: ?*Processor = null,
    context: shuttle.Context = .{},
    /// The task this thread last switched to.
    task: ?*Task = null,
    /// Where the thread is (`Stage`): in the runtime, or lending its
    /// processor while its task runs its own code or sits in a blocking
    /// call. Written by the thread alone, read by the monitor.
    stage: aegis.Atomic(Stage) = .init(.first),
    /// The processor's `lease` word while this thread holds it, its
    /// generation this thread's: any other word says the monitor claimed
    /// it or handed it on.
    lease: u32 = 0,
};

threadlocal var seat: Seat = .{};

/// The runtimes in the process whose processors are lent: any thread may
/// hold one of theirs and call into any runtime.
pub var lending: aegis.Atomic(Lending) = .init(.fromRaw(0));
/// A number of runtimes.
const Lending = aegis.units.Count(Scheduler, u32);

/// The calling thread's seat, read afresh at every call.
///
/// A task moves between threads at a switch, which the compiler cannot
/// see: within one function it computes a thread-local's address once and
/// reuses it, so after a park inlined into the same function a task would
/// read the thread it left. Never inlined, so each call computes the
/// address on the thread that makes it.
///
/// Not inlining is not enough: LLVM sees the function always returns the
/// thread-local's address and puts that address, computed in the caller,
/// where the call's result was used, and then merges it with the caller's
/// earlier one across a switch. On x86_64 the address is a load through
/// %fs, which a switch's memory clobber orders; on aarch64 it is a register
/// read, merged freely, so a task that moved kept the seat of the thread it
/// left (optimized builds only: lane calls crashed in the switch, a queued
/// task was never offered to an idle processor). The address passes through
/// an assembly statement, which the compiler cannot see through.
pub noinline fn seatNow() *Seat {
    // aegis: design: the seat's address passes through an assembly statement the compiler cannot see through, so a switch does not merge it with an earlier read (above)
    return asm volatile (""
        : [address] "=r" (-> *Seat),
        : [seat] "0" (&seat),
    );
}

/// The processor the calling thread holds, read afresh at every call.
noinline fn heldNow() ?*Processor {
    return seatNow().held;
}

/// The calling thread now holds `p`.
pub fn enter(p: *Processor) void {
    assert(heldNow() == null);
    seatNow().held = p;
    p.on_home_thread = std.Thread.getCurrentId() == p.scheduler.home_thread;
}

pub fn leave() void {
    seatNow().held = null;
}

/// The processor the calling thread holds, if any.
pub fn processor() ?*Processor {
    return heldNow();
}

/// The task the calling thread runs, read without touching a processor the
/// thread has lent, which may be another's by now: for a crash report.
pub fn runningTask() ?*Task {
    const own = seatNow();
    const p = own.held orelse return null;
    if (own.stage.load(.monotonic).mode() != .inside) return own.task;
    return p.current;
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
pub fn park(after: ?*After) void {
    const own = seatNow();
    const p = own.held.?;
    const t = p.current.?;
    var message: Processor.Message = .{ .processor = p, .action = .{ .park = after } };
    if (t.stack != null) {
        const bytes = t.stack_top - @intFromPtr(&message); // safe: message is a live frame below this task's owned stack top
        const deepest = p.scheduler.records.parked(t, p.index, bytes);
        message.inspect = deepest > bytes + trim_gap;
    }
    toScheduler(t, &own.context, &message);
}

/// To the back of the queue.
pub fn yield() void {
    const own = seatNow();
    const p = own.held.?;
    const t = p.current.?;
    var message: Processor.Message = .{ .processor = p, .action = .yield };
    toScheduler(t, &own.context, &message);
}

/// Ends the running task: `done` runs once it is off its stack.
pub fn exit(done: *const fn (t: *Task) void) noreturn {
    const own = seatNow();
    const p = own.held.?;
    const t = p.current.?;
    var message: Processor.Message = .{ .processor = p, .action = .{ .exit = done } };
    toScheduler(t, &own.context, &message);
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
    _ = s.shared.forced_yields.fetchAddWrapping(.fromRaw(1), .monotonic);
    yield();
}

/// Makes a parked task runnable, from any thread.
pub fn ready(s: *Scheduler, t: *Task, how: Processor.How) void {
    const target: ?*Processor = if (t.policy.home or t.pins > 0 or s.scheduling == .per_core)
        processorOf(t)
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
    while (!t.cancel_messages.load(.acquire).eql(.fromRaw(0))) {
        if (heldNow()) |p| _ = p.serveCancels();
        if (t.cancel_messages.load(.acquire).eql(.fromRaw(0))) return;
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
    _ = s.shared.inject_len.fetchAddWrapping(.fromRaw(count), .release);
    locked.deinit(system());
    s.wakeIdle();
}

pub fn injectedLen(s: *const Scheduler) u32 {
    return s.shared.inject_len.load(.acquire).raw();
}

/// One task from the global queue for `p`.
pub fn takeInjected(s: *Scheduler, p: *Processor) ?*Task {
    if (s.shared.inject_len.load(.acquire).eql(.fromRaw(0))) return null;
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
    _ = s.shared.inject_len.fetchSubWrapping(.fromRaw(1), .release);
    return t;
}

// Idle processors.

/// `p` is about to wait in the kernel (or stopped waiting).
pub fn idle(s: *Scheduler, p: *Processor, waiting: bool) void {
    _ = p;
    if (waiting) {
        _ = s.shared.idle_count.fetchAddWrapping(.fromRaw(1), .seq_cst);
    } else {
        _ = s.shared.idle_count.fetchSubWrapping(.fromRaw(1), .seq_cst);
        // The monitor parks while every processor waits: one is back.
        if (s.monitor) |m| if (m.parked.raised(.seq_cst)) m.poke();
    }
}

/// Whether every processor waits in its kernel.
pub fn allIdle(s: *const Scheduler) bool {
    return s.shared.idle_count.load(.seq_cst).eql(.fromRaw(@intCast(s.processors.len)));
}

// Lending and handoff.
//
// A worker lends its processor whenever the task it runs leaves the
// runtime: for its own code, between one call into the runtime and the
// next, and for a blocking call. The thread says where it is in its seat's
// `stage`, the monitor says what it did with the processor in the
// processor's `lease`, and each writes its word and then reads the other's,
// both sequentially consistent, so of a thread coming back into the runtime
// and the monitor claiming its processor at least one sees the other: the
// monitor backs off, or the thread waits for its look to end. No
// read-modify-write on a task's way in or out. A lending that lasts
// `handoff_after` (a task computing, a call blocked) costs the thread its
// processor when the processor has work, never the processor its queue. A
// task that lost its processor goes on running its own code on its thread
// and rejoins a processor at its next call into the runtime; the root takes
// the home processor back. Only where the monitor hands processors on
// (`Processor.lends`): epoll, kqueue and IOCP, with workers.

/// The states of `Processor.lease`, in its low bits below the generation,
/// which moves at every change of owner.
pub const Lease = struct {
    /// Its owner's: whether it is lent is the owner's `stage`.
    pub const held: u32 = 0;
    /// The monitor gave it to a spare thread while its owner had lent it.
    pub const handed: u32 = 1;
    /// The home processor, given back to the home thread.
    pub const home_back: u32 = 2;
    /// The monitor looks at it while its owner has lent it, to decide
    /// whether to hand it on; the owner waits for the look to end.
    pub const claimed: u32 = 3;
    pub const state: u32 = 3;

    /// The generation after `word`'s, with no state.
    pub fn next(word: u32) u32 {
        return (word & ~state) +% (state + 1);
    }

    /// `word` with `new` as its state, its generation kept.
    pub fn with(word: u32, new: u32) u32 {
        return (word & ~state) | new;
    }
};

/// Where a thread is, in its seat's `stage`: a count of its moves in the
/// bits above, so the monitor tells one long lending from many short ones.
pub const Stage = @import("scheduler/stage.zig").Stage;

/// Whether `stage` lends its thread's processor.
pub fn isLent(s: *const Scheduler, stage: Stage) bool {
    _ = s;
    return stage.mode() != .inside;
}

/// Whether `stage` lends its thread's processor for a blocking call.
pub fn isBlocked(s: *const Scheduler, stage: Stage) bool {
    _ = s;
    return stage.mode() == .blocked;
}

/// The thread at `own` leaves the runtime for `to`, lending its processor.
inline fn lendFrom(own: *Seat, to: Stage.Mode) void {
    own.stage.store(own.stage.load(.monotonic).moved(to), .release);
}

/// The thread at `own` comes back into the runtime: true when it still
/// holds its processor, having waited out a look of the monitor's; false
/// when the monitor handed it on meanwhile.
fn comeBack(own: *Seat) bool {
    own.stage.store(own.stage.load(.monotonic).moved(.inside), .seq_cst);
    const p = own.held.?;
    while (true) {
        const word = p.lease.load(.seq_cst);
        if (word == own.lease) return true;
        if (word != Lease.with(own.lease, Lease.claimed)) return false;
        std.atomic.spinLoopHint();
    }
}

/// From a task's own code into the runtime: the calling thread takes its
/// processor back from lending, or, when the monitor handed it on, the
/// task first rejoins a processor (the root, the home one). The task when
/// its processor was lent here, for `toUser` at the way out; null inside
/// the runtime already, off any processor, or where processors are not
/// lent. Nothing before it may touch the processor.
pub inline fn fromUser() ?*Task {
    // A process with no runtime that lends reads nothing more.
    if (lending.load(.monotonic).eql(.fromRaw(0))) return null;
    // The seat read first, before anything in the caller can move the task
    // to another thread; nothing reads it directly after (`seatNow`, a
    // call, reads it afresh), so the address is never one thread's taken
    // for another's.
    const own = &seat;
    if (own.stage.load(.monotonic).mode() != .user) return null;
    return comeIn(own);
}

noinline fn comeIn(own: *Seat) ?*Task {
    return fromSeat(own);
}

/// `fromUser` for the running task `t`, through its seat.
fn fromTask(t: *Task) void {
    _ = fromSeat(seatOf(t));
}

inline fn fromSeat(own: *Seat) ?*Task {
    if (own.stage.load(.monotonic).mode() != .user) return null;
    const t = own.task.?;
    if (!comeBack(own)) rejoin(own, t);
    return t;
}

/// Back to `t`'s own code, `t` the task `fromUser` returned: its processor
/// is lent until it calls into the runtime again. Through the task's seat,
/// which is the thread's it runs on now, wherever the call took it.
pub fn toUser(t: *Task) void {
    lendFrom(seatOf(t), .user);
}

fn seatOf(t: *Task) *Seat {
    return @fieldParentPtr("context", t.seat_context.?);
}

/// The processor `t` runs or last ran on, by the loop it holds.
pub fn processorOf(t: *const Task) ?*Processor {
    return @fieldParentPtr("loop", t.processor_loop orelse return null);
}

/// Calls the running task `t`'s own code from inside the runtime (an
/// `async` run inline, its first function): its processor is lent
/// meanwhile, and the task may come back on another.
pub inline fn callOut(t: *Task, function: anytype, args: anytype) void {
    const p = processorOf(t).?;
    if (!p.lends) return @call(.auto, function, args);
    toUser(t);
    @call(.auto, function, args);
    fromTask(t);
}

/// The processor the thread at `own` lent went to another thread: the
/// running task `t` leaves this thread and goes on wherever a processor
/// takes it; the root, which never leaves its thread, waits for the home
/// processor to come back. The processor's own record of the task is
/// another thread's now: the task is the seat's.
fn rejoin(own: *Seat, t: *Task) void {
    const p = own.held.?;
    if (t.kind == .root) {
        reclaim(p);
        p.current = t;
        return;
    }
    var message: Processor.Message = .{ .processor = p, .action = .relocate };
    toScheduler(t, &own.context, &message);
}

/// A blocking call under way on a worker, which the monitor may hand the
/// worker's processor away from meanwhile.
pub const Blocking = struct {
    task: *Task,
};

/// Before a call that may block its thread (std's file code, borrowed on a
/// worker): the processor is lent while it lasts, and the monitor hands it
/// to a spare thread if the call goes on past `handoff_after` and it has
/// work. Null where processors are not lent. Nothing between this and
/// `leaveBlocking` may touch the scheduler.
pub fn enterBlocking() ?Blocking {
    const own = seatNow();
    const p = own.held orelse return null;
    if (!p.lends) return null;
    const t = p.current orelse return null;
    lendFrom(own, .blocked);
    // The monitor sleeps long while nothing is lent for long: a blocking
    // call is worth watching from its start.
    p.scheduler.monitor.?.poke();
    return .{ .task = t };
}

/// After the call: the task goes on on this thread if it still holds the
/// processor, else rejoins one as at a call from its own code.
pub fn leaveBlocking(b: *Blocking) void {
    const own = seatOf(b.task);
    if (!comeBack(own)) rejoin(own, b.task);
}

/// On the home thread: asks for the home processor, waits until it is
/// given back (`giveBack`), then holds it again.
pub fn reclaim(p: *Processor) void {
    _ = p.remote.home_wants.raise(.seq_cst);
    p.loop.wake();
    while (true) {
        const word = p.lease.load(.acquire);
        if (word & Lease.state == Lease.home_back) break;
        system().futexWaitUncancelable(u32, &p.lease.raw, word);
    }
    p.remote.home_wants.clear(.monotonic);
    if (heldNow() == null) enter(p);
    p.adopt();
}

/// On the thread that lost its processor, `t` off its stack now: the
/// thread lets go, and `t` goes where it may run, as a woken task does: to
/// the processor it belongs to (`per_core`, pinned) or the global queue.
fn relocated(s: *Scheduler, t: *Task) void {
    leave();
    s.ready(t, .completed);
}

/// From the monitor: hands `p`, held by `owner` under `word` and lent by it
/// at `stage` too long, to a spare thread, when it has something only its
/// owner can do: tasks queued there, operations and timers in its loop, the
/// home thread asking for it. The global queue is any processor's, and an
/// idle one is woken for it. False when it has nothing, there is no thread
/// to hand it to, or the owner came back into the runtime or changed.
pub fn handOff(s: *Scheduler, p: *Processor, word: u32, owner: *Seat, stage: Stage) bool {
    if (word & Lease.state != Lease.held) return false;
    // A thread first, outside the claim: starting one is slow, and the owner
    // waits on a claim.
    if (!s.spares.reserve(serveThread, s)) return false;
    // `word` is the generation `owner` and `stage` were read under: a
    // processor another thread took over since has another.
    if (p.lease.cmpxchgStrong(word, Lease.with(word, Lease.claimed), .seq_cst, .monotonic) != null) return false;
    // The owner came back meanwhile: it may be touching the processor.
    if (owner.stage.load(.seq_cst) != stage) {
        p.lease.store(word, .release);
        return false;
    }
    // Claimed while lent: the owner waits at its next way in, so the
    // processor's queues and loop are still.
    if (!p.hasOwnWork() and !p.loop.waiting() and !p.remote.home_wants.raised(.seq_cst)) {
        p.lease.store(word, .release);
        return false;
    }
    p.lease.store(Lease.with(word, Lease.handed), .release);
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
        const p: *Processor = next orelse s.spares.wait(&s.stopping, fresh) orelse return;
        fresh = false;
        next = null;
        enter(p);
        p.adopt();
        p.schedule();
        // Still held: the runtime stops.
        if (heldNow() == p) {
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
    if (s.shared.idle_count.load(.seq_cst).eql(.fromRaw(0))) return;
    // A spinning processor will find it.
    if (!s.shared.searching.load(.seq_cst).eql(.fromRaw(0))) return;
    const runnable = p.local.len() + p.latency.len() + @intFromBool(p.lifo != null);
    if (runnable == 0) return;
    // Between tasks, this processor runs the one task it has next: a
    // processor woken for it would only take it away. Not when tasks that
    // cannot leave wait here too (the root, a task holding a deadline): the
    // queued one then waits behind them, and an idle processor runs it
    // meanwhile. A root writing to a task that reads ran on one thread,
    // turn about, until this (1 GiB over loopback: 7.6 GiB/s, now 9.0, lima
    // VM, three workers).
    if (runnable == 1 and p.current == null and p.pinned.isEmpty() and p.latency_pinned.isEmpty()) return;
    s.wakeIdle();
}

fn wakeIdle(s: *Scheduler) void {
    // A host outside run() is waiting on the home loop's handle, rather
    // than counted as a processor waiting in its kernel.
    const home = &s.processors[0];
    if (home.remote.away.raised(.seq_cst)) wakeProcessor(home);
    if (s.shared.idle_count.load(.seq_cst).eql(.fromRaw(0))) return;
    for (s.processors) |*other| {
        if (other.remote.sleeping.raised(.seq_cst)) {
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
/// and result; null when no stack can be had (`stacks.take`). `entry` runs
/// first.
pub inline fn create(s: *Scheduler, kind: Task.Kind, extra: usize, extra_align: std.mem.Alignment, entry: *const fn (t: *Task) callconv(.c) noreturn) ?struct { *Task, [*]u8 } {
    const taken = stacks_.take(&s.stacks, s.stack_size, null) orelse return null;
    return s.createAt(taken, kind, extra, extra_align, entry, .normal);
}

pub fn createWith(s: *Scheduler, kind: Task.Kind, extra: usize, extra_align: std.mem.Alignment, entry: *const fn (t: *Task) callconv(.c) noreturn, size: ?aegis.units.Bytes(usize), priority: Task.Priority) ?struct { *Task, [*]u8 } {
    const taken = stacks_.take(&s.stacks, s.stack_size, size) orelse return null;
    return s.createAt(taken, kind, extra, extra_align, entry, priority);
}

inline fn createAt(s: *Scheduler, taken: shuttle.Stack, kind: Task.Kind, extra: usize, extra_align: std.mem.Alignment, entry: *const fn (t: *Task) callconv(.c) noreturn, priority: Task.Priority) ?struct { *Task, [*]u8 } {
    var stack = taken;
    const top = stack.top;
    const record = stack.carve(Task) catch return s.refuse(stack);
    const extra_bytes = stack.carveBytes(extra, extra_align) catch return s.refuse(stack);
    // A task whose record and context leave it less than half its stack
    // would rather wait for a larger one.
    if (stack.top - stack.bottom < (stack.end - stack.bottom) / 2) return s.refuse(stack);
    if (s.measure_stacks and !stacks_.paint(&stack, @intFromPtr(extra_bytes))) return s.refuse(stack);
    // The task builder assigns its start/context and spawn site before
    // publication; runTask assigns execution budgets before entering it.
    // Cancellation and queue ownership are initialized here as usual.
    record.* = .{
        .kind = kind,
        .stack = .fromRaw(s.stacks.number(stack)),
        .stack_top = top,
        .policy = .{ .home = s.scheduling == .per_core, .priority = priority, .measured = s.measure_stacks },
        .start = undefined,
        .spawned_at = undefined,
        .budget = undefined,
        .slice_start = undefined,
    };
    record.context = shuttle.handoff.init(&stack, *const fn (t: *Task) callconv(.c) noreturn, taskBody, entry) catch return s.refuse(stack);
    return .{ record, extra_bytes };
}

/// Gives back a stack a task could not be made on.
fn refuse(s: *Scheduler, stack: shuttle.Stack) ?struct { *Task, [*]u8 } {
    s.stacks.give(stack);
    return null;
}

/// Waits until every group member that has left its group has given its
/// stack back, so an awaiter that saw an empty group sees no stack in use
/// by it. A member counts itself in before it leaves the group.
pub fn awaitRetired(s: *Scheduler) void {
    for (s.processors) |*p| while (!p.retiring.load(.acquire).eql(.fromRaw(0))) std.atomic.spinLoopHint();
}

/// Gives back the stack of a task that has ended and been forgotten. A
/// task keeps only its stack's number; the pool describes the stack again.
pub inline fn release(s: *Scheduler, t: *Task) void {
    s.records.release(t);
    var stack = s.stackOf(t);
    // On Windows the stack keeps what its task committed, for the next.
    t.context.deinit(&stack);
    t.* = undefined;
    s.stacks.give(stack);
}

/// The stack task `t` runs on, as the pool handed it out: its bounds,
/// before anything was carved from its top.
pub fn stackOf(s: *const Scheduler, t: *const Task) shuttle.Stack {
    return s.stacks.stackOf(t.stack.?.raw());
}

/// Where a newly made task runs first: the creator's processor, or,
/// outside any, the next by round robin under `per_core`.
pub inline fn place(s: *Scheduler, t: *Task) void {
    s.records.created(t);
    if (heldNow()) |p| if (p.scheduler == s) {
        t.processor_loop = &p.loop;
        return p.pushLocal(t, .spawned);
    };
    if (s.scheduling == .per_core) {
        // aegis: no-danger: a round robin: the count wraps, and only its remainder picks a processor
        const i = s.shared.placement.fetchAddWrapping(.fromRaw(1), .monotonic).raw() % s.processors.len;
        const p = &s.processors[i];
        t.processor_loop = &p.loop;
        return p.pushRemote(t);
    }
    s.inject(t);
}

/// A task's first code, once the switch that started it is finished.
fn taskBody(entry: *const fn (t: *Task) callconv(.c) noreturn) noreturn {
    entry(current().?);
}

/// From a task to a scheduler's context, which runs `afterSwitch` with
/// `message` once the task's stack is still.
inline fn toScheduler(t: *Task, scheduler: *shuttle.Context, message: *Processor.Message) void {
    shuttle.handoff.switchTo(&t.context, scheduler, &message.after);
}

fn wakeProcessor(target: *Processor) void {
    if (heldNow()) |source| if (source.scheduler == target.scheduler)
        return loop_internal.wakeFrom(&target.loop, &source.loop);
    target.loop.wake();
}
