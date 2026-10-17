//! Calls that can take milliseconds run off the workers, on four lanes:
//! `sync` (device flushes), `lookup` (name resolution), `wait` (calls that
//! can wait without bound: locks, CPU-clock sleeps), `general` (the rest).
//! Each lane is an owned `Io.Threaded`, so std's own code runs there with
//! std's own cancellation (its thread status, signals and
//! `CancelSynchronousIo`); or the host's injected executor; or nothing, and
//! calls run inline only in the explicitly selected zero-thread profile.
//!
//! A call is a `Job` in the waiting task's frame: started as a member of
//! its own `Io.Group` on the lane, so cancelling it is std's
//! `Group.cancel`, run as a second short job on the lane. A lane runs at
//! most its cap of calls at once and queues the rest, oldest first; the
//! queue is the waiting tasks' own frames, so it needs no bound of its own
//! (`max_tasks` is one), and a call never runs on a worker because its
//! lane was busy. Closures come from a slot pool reserved at `init`.
//!
//! An owned lane starts no thread until a call needs one: before a call
//! starts, the lane grows to two threads for each call it runs (the call's
//! own, and one for a cancel of it) and three more (two for child
//! termination, one for a thread still leaving), and never shrinks. So a
//! cancel or a control call never waits on a thread being made, and a
//! runtime that makes no lane call starts none. A lane that cannot grow
//! queues the call behind the calls it runs, or, running none, refuses it:
//! a raw call returns `ConcurrencyUnavailable`, and a call whose signature
//! has no error for it waits and tries again, as it waits for admission.
const Lanes = @This();

const std = @import("std");
const aegis = @import("aegis");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const SlotPool = @import("lanes/SlotPool.zig");

pub const Lane = enum(u2) { sync, lookup, wait, general };
pub const count = 4;
pub const Priority = enum(u1) { normal, latency };

pub const Config = union(enum) {
    owned: Owned,
    /// Any `Io` whose `groupConcurrent` runs on a thread of its own.
    injected: struct {
        io: Io,
        /// Guaranteed submissions, including retiring execution and control jobs.
        /// Exclusive to reactor; the host must retain this capacity until stop.
        capacity: u16,
    },
    /// No threads: calls run inline on the caller, counted.
    none,
};

pub const Owned = struct {
    sync: u16 = 4,
    lookup: u16 = 8,
    wait: u16 = 32,
    /// null: max(4, CPUs), at most 64.
    general: ?u16 = null,
    /// Maximum allocation made by std inside one call; blocks are reserved at init.
    scratch_bytes: aegis.units.Bytes(u32) = .fromRaw(256 << 10),
};

/// What every Threaded instance needs from the runtime's options.
pub const Environment = struct {
    environ: std.process.Environ = .empty,
    argv0: Io.Threaded.Argv0 = .empty,
    /// Maximum admitted calls per lane, including queued and retiring jobs.
    max_jobs: u32 = 2048,
};

/// One call. Lives in the waiting task's frame until `done` has run and
/// the lane's executor has let go of `group`.
pub const Job = struct {
    /// Makes the call, on the lane's thread.
    run: *const fn (job: *Job) void,
    /// Once the call, and any cancel of it, is over; on the thread that
    /// finished last.
    done: *const fn (job: *Job) void,
    lane: Lane,
    priority: Priority = .normal,
    group: Io.Group = .init,
    cancellation: Io.Group = .init,
    /// The executor capacity this call holds from `admit` to `retire`.
    executor: ?Executor.Reservation = null,
    /// Child termination bypasses occupied wait slots using reserved control capacity.
    control: bool = false,
    next: ?*Job = null,
    /// The call, plus one while a cancel of it runs.
    pending: std.atomic.Value(u32) = .init(1),
    /// Cancelled before it started: `run` never ran.
    dropped: bool = false,
    /// The executor refused the call; no user code ran.
    rejected: bool = false,
    /// Of a rejected call: the lane, running no call, could make no thread
    /// for it. A wait for resources, where any other rejection of an
    /// admitted call is the executor breaking its capacity guarantee.
    short: bool = false,

    /// Whether `admit` has reserved this call's capacity and `retire` has not given it back.
    pub fn admitted(job: *const Job) bool {
        return job.executor != null;
    }

    /// Whether the executor still holds the job's group: wait until not
    /// before the job's frame goes.
    pub fn held(job: *const Job) bool {
        return job.group.token.load(.acquire) != null or job.cancellation.token.load(.acquire) != null;
    }
};

pub const Stats = struct {
    queued: u32,
    running: u32,
    /// Threads the lane's owned executor has made.
    threads: u32,
    @"inline": u64,
};

/// Executor capacity, in units: two for each admitted call.
const Executor = aegis.bounded.Budget(u32);

/// What `admit` and `retire` keep, under one lock: calls admitted per lane,
/// the executor capacity they hold, and whether the one control call is out.
const Admission = struct {
    admitted: [count]u32 = @splat(0),
    executor: Executor,
    control: bool = false,
};

/// A lane's calls waiting for a slot, oldest first, latency before normal
/// within the turn limit.
const Queue = struct {
    running: u16 = 0,
    head: [2]?*Job = .{ null, null },
    tail: [2]?*Job = .{ null, null },
    latency_runs: u8 = 0,
    queued: u32 = 0,

    fn push(q: *Queue, job: *Job) void {
        job.next = null;
        const class = @backingInt(job.priority);
        if (q.tail[class]) |t| t.next = job else q.head[class] = job;
        q.tail[class] = job;
        q.queued += 1;
    }

    /// The call to run next, or null with nothing queued.
    fn pop(q: *Queue) ?*Job {
        const class: usize = if (q.head[1] != null and (q.latency_runs < 8 or q.head[0] == null)) 1 else 0;
        const job = q.head[class] orelse return null;
        q.head[class] = job.next;
        if (q.head[class] == null) q.tail[class] = null;
        if (class == 1) q.latency_runs +|= 1 else q.latency_runs = 0;
        q.queued -= 1;
        return job;
    }

    /// Takes `job` out of the queue; false when it is not in it.
    fn remove(q: *Queue, job: *Job) bool {
        var prev: ?*Job = null;
        const class = @backingInt(job.priority);
        var it = q.head[class];
        while (it) |j| : ({
            prev = j;
            it = j.next;
        }) {
            if (j != job) continue;
            if (prev) |p| p.next = j.next else q.head[class] = j.next;
            if (q.tail[class] == j) q.tail[class] = prev;
            q.queued -= 1;
            return true;
        }
        return false;
    }
};

/// The threads a lane starts calls on, held for the whole of a start.
const Launch = struct {
    /// Threads the lane's executor has made: they stay, idle or busy, until
    /// `deinit`.
    threads: u32 = 0,
    growth: Growth = .{},
};

const State = struct {
    cap: u16,
    limit: u32,
    launch: aegis.BlockingGuarded(Launch) = .init(.{}),
    queue: aegis.BlockingGuarded(Queue) = .init(.{}),
    inlined: std.atomic.Value(u64) = .init(0),
};

mode: std.meta.Tag(Config),
/// The executors: owned instances, the injected one, or none.
threaded: [count]Io.Threaded = undefined,
/// Each owned lane's growth blockers, awaited at `deinit`.
growth_groups: [count]Io.Group = @splat(.init),
injected: Io = undefined,
/// std's code borrowed on the workers and for inline calls.
borrowed: Io.Threaded,
states: [count]State,
pool: SlotPool,
scratch: SlotPool,
/// Where cancels of calls run; never awaited until `deinit`.
started: bool = false,
capacity: u32 = 0,
/// The most executor capacity admitted calls can hold.
units: u32,
admission: aegis.BlockingGuarded(Admission),

pub fn init(l: *Lanes, gpa: Allocator, config: Config, env: Environment) Allocator.Error!void {
    const caps = capsOf(config);
    var total: u32 = 0;
    for (caps) |c| total += c;
    var pool = try SlotPool.init(gpa, 4 * total + 16);
    errdefer pool.deinit(gpa);
    const bytes = switch (config) {
        .owned => |o| o.scratch_bytes.raw(),
        else => 256 << 10,
    };
    var scratch = try SlotPool.initSized(gpa, total + 16, bytes);
    errdefer scratch.deinit(gpa);
    const capacity: u32 = if (config == .injected) config.injected.capacity else 0;
    // Only an injected executor has capacity of its own to run out of.
    const units: u32 = if (config == .injected) capacity else std.math.maxInt(u32);
    l.* = .{
        .mode = config,
        .borrowed = .init(.failing, .{ .async_limit = .nothing, .concurrent_limit = .nothing, .environ = env.environ, .argv0 = env.argv0 }),
        .states = undefined,
        // A closure for each running call, each cancel of one, and each
        // call that has ended but whose thread has not yet let go of it.
        .pool = pool,
        .scratch = scratch,
        .capacity = capacity,
        .units = units,
        .admission = .init(.{ .executor = .init(units) }),
    };
    l.borrowed.allocator = l.allocator();
    for (&l.states, caps) |*s, c| s.* = .{ .cap = c, .limit = env.max_jobs };
    switch (config) {
        // The lane's cap bounds its calls; std's own limit would also count
        // a call that has ended while its thread is still leaving, and
        // refuse the next call for it.
        .owned => for (&l.threaded) |*t| {
            t.* = .init(l.allocator(), .{
                .async_limit = .nothing,
                .concurrent_limit = .unlimited,
                .environ = env.environ,
                .argv0 = env.argv0,
            });
        },
        .injected => |injected| l.injected = injected.io,
        .none => {},
    }
}

pub fn deinit(l: *Lanes, gpa: Allocator) void {
    for (l.admission.teardown().admitted) |n| assert(n == 0);
    if (l.mode == .owned) {
        // Every round's blockers were let go as it ended.
        for (&l.growth_groups, 0..) |*group, i| group.await(l.threaded[i].io()) catch unreachable; // unreachable: shutdown is outside a cancelable executor task
        // std's instances restore the signal handlers they saw: last first.
        var i: usize = count;
        while (i > 0) {
            i -= 1;
            l.threaded[i].deinit();
        }
    }
    l.borrowed.deinit();
    l.pool.deinit(gpa);
    l.scratch.deinit(gpa);
    l.* = undefined;
}

fn capsOf(config: Config) [count]u16 {
    return switch (config) {
        .owned => |o| .{ o.sync, o.lookup, o.wait, o.general orelse general: {
            const cpus = std.Thread.getCpuCount() catch 4;
            break :general @intCast(std.math.clamp(cpus, 4, 64));
        } },
        .injected => |injected| @splat(injected.capacity / 2),
        .none => .{ 0, 0, 0, 0 },
    };
}

/// Whether calls run inline on their caller.
pub fn inlined(l: *const Lanes) bool {
    return l.mode == .none;
}

/// std's code for running a call on the caller's own thread.
pub fn borrowedIo(l: *Lanes) Io {
    return l.borrowed.io();
}

/// The executor of `lane`: the `Io` its calls run under.
pub fn executor(l: *Lanes, lane: Lane) Io {
    return switch (l.mode) {
        .owned => l.threaded[@backingInt(lane)].io(),
        .injected => l.injected,
        .none => l.borrowed.io(),
    };
}

/// Counts a call run inline.
pub fn countInline(l: *Lanes, lane: Lane) void {
    _ = l.states[@backingInt(lane)].inlined.fetchAdd(1, .monotonic);
}

/// Readies the lanes for calls. Owned lanes start no thread here: each
/// grows as its calls need (`launch`).
pub fn prepare(l: *Lanes) error{SystemResources}!void {
    assert(!l.started);
    switch (l.mode) {
        .none => {},
        .injected => if (l.capacity < 4) return error.SystemResources,
        .owned => for (&l.states) |*state| if (state.cap == 0) return error.SystemResources,
    }
    l.started = true;
}

/// A lane's growth: jobs that hold threads until let go, so that the
/// executor makes new ones. One round at a time, under the launch lock.
const Growth = struct {
    gate: Io.Event = .unset,
    /// The last round's blockers.
    blockers: u32 = 0,
    /// Of those, the ones that have let go of the gate.
    left: std.atomic.Value(u32) = .init(0),

    fn block(context: *const anyopaque) void {
        const pointer: *const *Growth = @ptrCast(@alignCast(context)); // safe: `grow` copies a pointer to its lane's growth
        const growth = pointer.*;
        growth.gate.waitUncancelable(system());
        // The last touch of the growth: the next round may reset it.
        _ = growth.left.fetchAdd(1, .release);
    }
};

/// Makes the lane's executor hold at least `target` threads. std's
/// executor makes a thread only when it has none idle, and every job it
/// runs holds one, so blockers are started until the jobs it runs reach
/// `target`; then they are let go, idle threads for the lane's next jobs.
/// On failure the lane keeps what it had and what was made meanwhile.
fn grow(threaded: *Io.Threaded, group: *Io.Group, launching: *Launch, target: u32) error{SystemResources}!void {
    const g = &launching.growth;
    while (g.left.load(.acquire) < g.blockers) std.atomic.spinLoopHint();
    g.gate.reset();
    g.left.store(0, .monotonic);
    g.blockers = 0;
    defer g.gate.set(system());
    const io = threaded.io();
    const pointer = g;
    while (true) {
        threaded.mutex.lockUncancelable(system());
        const busy = threaded.busy_count;
        threaded.mutex.unlock(system());
        // Each job counted busy has a thread of its own.
        if (busy >= target) break;
        io.vtable.groupConcurrent(io.userdata, group, std.mem.asBytes(&pointer), .of(*Growth), Growth.block) catch return error.SystemResources;
        g.blockers += 1;
    }
    launching.threads = target;
}

/// Reserve execution and cancellation together, before publishing a call.
/// A reservation survives completion until both executor groups retire.
pub fn admit(l: *Lanes, job: *Job) bool {
    if (!l.started) return false;
    const index = @backingInt(job.lane);
    const state = &l.states[index];
    var held = l.admission.acquireUncancelable(system());
    defer held.deinit(system());
    const admission = held.value();
    if (state.cap == 0 or (!job.control and admission.admitted[index] >= state.limit)) return false;
    if (job.control) {
        if (admission.control) return false;
    } else if (l.mode == .injected and admission.executor.remaining() < 4) return false; // two units stay for child termination
    job.executor = admission.executor.reserve(2) catch return false;
    if (job.control) admission.control = true;
    admission.admitted[index] += 1; // bounded by the lane's limit, and by `max_tasks` for the control call
    return true;
}

/// Starts an admitted job, or queues it behind the lane's running cap.
/// Standalone fallible callers may submit without an earlier reservation.
pub fn submit(l: *Lanes, job: *Job) void {
    if (!job.admitted() and !l.admit(job)) {
        job.rejected = true;
        return finish(job);
    }
    switch (l.dispatch(job)) {
        .started, .queued => {},
        .short => {
            job.short = true;
            if (job.control) {
                job.rejected = true;
                finish(job);
            } else l.reject(job);
        },
        .refused => if (job.control) {
            job.rejected = true;
            finish(job);
        } else l.reject(job),
    }
}

const Dispatch = enum { started, queued, short, refused };

/// Under the lane's lock: the call starts if a slot is free, else it waits.
fn dispatch(l: *Lanes, job: *Job) Dispatch {
    var held = l.states[@backingInt(job.lane)].queue.acquireUncancelable(system());
    defer held.deinit(system());
    const queue = held.value();
    if (job.control) return switch (l.start(job, queue.running)) {
        .started => .started,
        .short => .short,
        .refused => .refused,
    };
    if (queue.running < l.states[@backingInt(job.lane)].cap) {
        queue.running += 1;
        switch (l.start(job, queue.running)) {
            .started => return .started,
            .refused => return .refused,
            // No thread to be had: behind the calls the lane runs, which
            // hold theirs; refused, holding the slot `reject` passes on,
            // when it runs none.
            .short => {
                if (queue.running == 1) return .short;
                queue.running -= 1;
            },
        }
    }
    queue.push(job);
    return .queued;
}

/// After execution and cancellation have retired, release their reservation.
/// Running slots may already serve queued calls; their reservations are distinct.
pub fn retire(l: *Lanes, job: *Job) void {
    assert(!job.held());
    assert(job.pending.load(.acquire) == 0);
    const reservation = if (job.executor) |*r| r else return;
    var held = l.admission.acquireUncancelable(system());
    defer held.deinit(system());
    const admission = held.value();
    admission.admitted[@backingInt(job.lane)] -= 1;
    reservation.release();
    if (job.control) admission.control = false;
    job.executor = null;
}

const Start = enum {
    started,
    /// The lane could not grow to the threads its calls need.
    short,
    /// The executor could take no more.
    refused,
};

/// `job` as a member of its own group on the lane's executor, the lane
/// running `running` calls with it.
fn start(l: *Lanes, job: *Job, running: u16) Start {
    const io = l.executor(job.lane);
    var launching = l.states[@backingInt(job.lane)].launch.acquireUncancelable(system());
    defer launching.deinit(system());
    if (!l.reach(job.lane, launching.value(), threadsFor(running))) return .short;
    l.awaitIdle(job.lane, launching.value());
    const context: Context = .{ .lanes = l, .job = job };
    io.vtable.groupConcurrent(io.userdata, &job.group, std.mem.asBytes(&context), .of(Context), runEntry) catch return .refused;
    return .started;
}

/// The threads a lane running `running` calls holds: each call's and a
/// cancel's of it, two for child termination, one for a thread leaving.
fn threadsFor(running: u16) u32 {
    return 2 * @as(u32, running) + 3;
}

fn reject(l: *Lanes, first: *Job) void {
    var job = first;
    while (true) {
        const refused = l.next(job.lane);
        job.rejected = true;
        finish(job);
        job = refused orelse return;
    }
}

const Context = struct { lanes: *Lanes, job: *Job };

fn runEntry(context: *const anyopaque) void {
    const c: *const Context = @ptrCast(@alignCast(context)); // safe: `start` passed a `Context`
    const job = c.job;
    job.run(job);
    const refused = if (job.control) null else c.lanes.next(job.lane);
    finish(job);
    if (refused) |next_job| c.lanes.reject(next_job);
}

/// A call on `lane` ended: the oldest queued one takes its slot, or the
/// slot is freed. The queued call when the executor refused it, which then
/// holds the slot until `reject` passes it on; null otherwise. A call that
/// started is never returned: it may have ended, and its frame be gone,
/// by the time the caller looked at it.
fn next(l: *Lanes, lane: Lane) ?*Job {
    var held = l.states[@backingInt(lane)].queue.acquireUncancelable(system());
    defer held.deinit(system());
    const queue = held.value();
    const job = queue.pop() orelse {
        queue.running -= 1;
        return null;
    };
    // Publish the execution group before a cancellation can observe unqueued work.
    // The slot passes on, so the lane holds the threads it needs already.
    return switch (l.start(job, queue.running)) {
        .started => null,
        .short, .refused => job,
    };
}

fn finish(job: *Job) void {
    if (job.pending.fetchSub(1, .acq_rel) == 1) job.done(job);
}

/// From any thread: cancels `job` by std's own mechanism. A call still
/// queued is dropped without running.
pub fn cancel(l: *Lanes, job: *Job) void {
    var held = l.states[@backingInt(job.lane)].queue.acquireUncancelable(system());
    if (held.value().remove(job)) {
        held.deinit(system());
        job.dropped = true;
        return finish(job);
    }
    defer held.deinit(system());
    var pending = job.pending.load(.acquire);
    while (true) {
        if (pending == 0) return;
        pending = job.pending.cmpxchgWeak(pending, pending + 1, .acq_rel, .acquire) orelse break;
    }
    const io = l.executor(job.lane);
    var launching = l.states[@backingInt(job.lane)].launch.acquireUncancelable(system());
    defer launching.deinit(system());
    // The lane grew for this call's cancel before the call started.
    l.awaitIdle(job.lane, launching.value());
    const context: Context = .{ .lanes = l, .job = job };
    io.vtable.groupConcurrent(io.userdata, &job.cancellation, std.mem.asBytes(&context), .of(Context), cancelEntry) catch @panic("reactor: lane executor refused cancellation");
}

/// Under the lane's launch lock: whether an owned lane holds at least
/// `threads` threads, growing to them; false when it could not grow.
fn reach(l: *Lanes, lane: Lane, launching: *Launch, threads: u32) bool {
    if (l.mode != .owned or launching.threads >= threads) return true;
    const index = @backingInt(lane);
    grow(&l.threaded[index], &l.growth_groups[index], launching, threads) catch return false;
    return true;
}

/// Under the lane's launch lock: waits until an owned lane has a thread
/// idle to run what is started next. The lane holds every thread its jobs
/// need, so one busy past them is leaving, and idle at once.
fn awaitIdle(l: *Lanes, lane: Lane, launching: *const Launch) void {
    if (l.mode != .owned) return;
    const threaded = &l.threaded[@backingInt(lane)];
    while (true) {
        threaded.mutex.lockUncancelable(system());
        const available = threaded.busy_count < launching.threads;
        threaded.mutex.unlock(system());
        if (available) return;
        std.atomic.spinLoopHint();
    }
}

fn cancelEntry(context: *const anyopaque) void {
    const c: *const Context = @ptrCast(@alignCast(context)); // safe: `cancel` passed a `Context`
    c.job.group.cancel(c.lanes.executor(c.job.lane));
    finish(c.job);
}

pub fn stats(l: *Lanes, lane: Lane) Stats {
    const s = &l.states[@backingInt(lane)];
    var held = s.queue.acquireUncancelable(system());
    const queue = held.value();
    const queued = queue.queued;
    const running = queue.running;
    held.deinit(system());
    var launching = s.launch.acquireUncancelable(system());
    defer launching.deinit(system());
    return .{ .queued = queued, .running = running, .threads = launching.value().threads, .@"inline" = s.inlined.load(.monotonic) };
}

/// Executor capacity the admitted calls hold, in units.
pub fn charged(l: *Lanes) u32 {
    var held = l.admission.acquireUncancelable(system());
    defer held.deinit(system());
    return l.units - held.value().executor.remaining();
}

fn system() Io {
    return Io.Threaded.global_single_threaded.io();
}

/// Both allocation classes remain fixed after init: closures use small slots;
/// std's temporary arenas use larger blocks, freed when the call returns.
fn allocator(l: *Lanes) Allocator {
    return .{ .ptr = l, .vtable = &.{ .alloc = alloc, .resize = Allocator.noResize, .remap = Allocator.noRemap, .free = free } };
}

fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const l: *Lanes = @ptrCast(@alignCast(context)); // safe: allocator passed the lanes
    const a = if (len <= SlotPool.slot_len) l.pool.allocator() else l.scratch.allocator();
    return a.rawAlloc(len, alignment, ret_addr);
}

fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const l: *Lanes = @ptrCast(@alignCast(context)); // safe: allocator passed the lanes
    const address = @intFromPtr(memory.ptr); // safe: only compares the address with the reserved pools
    const first = @intFromPtr(l.pool.buffer.ptr); // safe: only compares the pool's address
    const a = if (address >= first and address < first + l.pool.buffer.len) l.pool.allocator() else l.scratch.allocator();
    a.rawFree(memory, alignment, ret_addr);
}
