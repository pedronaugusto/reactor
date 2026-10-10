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

pub const Stats = struct { queued: u32, running: u32, threads: u16, @"inline": u64 };

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

/// The workers a lane starts calls on, held for the whole of a start.
const Launch = struct {
    dormant: []Warm = &.{},
    activated: usize = 0,
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
warm_groups: [count]Io.Group = @splat(.init),
warm_entries: []Warm,
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
    const warm_entries = try gpa.alloc(Warm, if (config == .owned) 2 * total + 3 * count else 0);
    for (warm_entries) |*entry| entry.* = .{};
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
        .warm_entries = warm_entries,
        .capacity = capacity,
        .units = units,
        .admission = .init(.{ .executor = .init(units) }),
    };
    l.borrowed.allocator = l.allocator();
    var offset: usize = 0;
    for (&l.states, caps) |*s, c| {
        s.* = .{ .cap = c, .limit = env.max_jobs };
        if (config == .owned) {
            const n = 2 * @as(usize, c) + 3;
            s.launch = .init(.{ .dormant = warm_entries[offset..][0..n] });
            offset += n;
        }
    }
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
        for (l.warm_entries) |*entry| entry.gate.set(system());
        for (&l.warm_groups, 0..) |*group, i| group.await(l.threaded[i].io()) catch unreachable; // unreachable: shutdown is outside a cancelable executor task
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
    gpa.free(l.warm_entries);
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

/// Prepare the executor threads before any fixed-signature operation runs.
/// Every running call has a control thread; two extra serve child termination,
/// and one absorbs executor retirement bookkeeping.
pub fn prepare(l: *Lanes) error{SystemResources}!void {
    assert(!l.started);
    switch (l.mode) {
        .none => {},
        .injected => if (l.capacity < 4) return error.SystemResources,
        .owned => for (&l.states, &l.threaded, &l.warm_groups) |*state, *threaded, *group| {
            if (state.cap == 0) return error.SystemResources;
            try warm(threaded, state, group);
        },
    }
    l.started = true;
}

const Warm = struct {
    gate: Io.Event = .unset,
    entered: std.atomic.Value(bool) = .init(false),
    fn run(context: *const anyopaque) void {
        const pointer: *const *Warm = @ptrCast(@alignCast(context)); // safe: warm copies a pointer to its retained barrier
        const barrier = pointer.*;
        barrier.entered.store(true, .release);
        barrier.gate.waitUncancelable(system());
    }
};
/// All workers exist at startup. Unused workers wait separately from the
/// executor's ready pool, preserving warm-thread reuse for sequential calls.
fn warm(threaded: *Io.Threaded, state: *State, group: *Io.Group) error{SystemResources}!void {
    const io = threaded.io();
    var launching = state.launch.acquireUncancelable(system());
    defer launching.deinit(system());
    const workers = launching.value();
    for (workers.dormant) |*entry| {
        const pointer = entry;
        io.vtable.groupConcurrent(io.userdata, group, std.mem.asBytes(&pointer), .of(@TypeOf(pointer)), Warm.run) catch return error.SystemResources;
    }
    for (workers.dormant) |*entry| while (!entry.entered.load(.acquire)) std.atomic.spinLoopHint();
    workers.dormant[0].gate.set(system());
    workers.activated = 1;
    while (true) {
        threaded.mutex.lockUncancelable(system());
        const available = threaded.busy_count < workers.dormant.len;
        threaded.mutex.unlock(system());
        if (available) return;
        std.atomic.spinLoopHint();
    }
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
        .refused => if (job.control) {
            job.rejected = true;
            finish(job);
        } else l.reject(job),
    }
}

const Dispatch = enum { started, queued, refused };

/// Under the lane's lock: the call starts if a slot is free, else it waits.
fn dispatch(l: *Lanes, job: *Job) Dispatch {
    var held = l.states[@backingInt(job.lane)].queue.acquireUncancelable(system());
    defer held.deinit(system());
    const queue = held.value();
    if (job.control) return if (l.start(job)) .started else .refused;
    if (queue.running < l.states[@backingInt(job.lane)].cap) {
        queue.running += 1;
        return if (l.start(job)) .started else .refused;
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

/// `job` as a member of its own group on the lane's executor; false when
/// the executor could take no more.
fn start(l: *Lanes, job: *Job) bool {
    const io = l.executor(job.lane);
    var launching = l.launch(job.lane);
    defer launching.deinit(system());
    const context: Context = .{ .lanes = l, .job = job };
    io.vtable.groupConcurrent(io.userdata, &job.group, std.mem.asBytes(&context), .of(Context), runEntry) catch return false;
    return true;
}

fn reject(l: *Lanes, first: *Job) void {
    var job = first;
    while (true) {
        const following = l.next(job.lane);
        job.rejected = true;
        finish(job);
        job = following orelse return;
        if (!job.rejected) return;
    }
}

const Context = struct { lanes: *Lanes, job: *Job };

fn runEntry(context: *const anyopaque) void {
    const c: *const Context = @ptrCast(@alignCast(context)); // safe: `start` passed a `Context`
    const job = c.job;
    job.run(job);
    const following = if (job.control) null else c.lanes.next(job.lane);
    finish(job);
    if (following) |next_job| if (next_job.rejected) c.lanes.reject(next_job);
}

/// A call on `lane` ended: the oldest queued one takes its slot, or the
/// slot is freed.
fn next(l: *Lanes, lane: Lane) ?*Job {
    var held = l.states[@backingInt(lane)].queue.acquireUncancelable(system());
    defer held.deinit(system());
    const queue = held.value();
    const job = queue.pop() orelse {
        queue.running -= 1;
        return null;
    };
    // Publish the execution group before a cancellation can observe unqueued work.
    if (!l.start(job)) job.rejected = true;
    return job;
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
    var launching = l.launch(job.lane);
    defer launching.deinit(system());
    const context: Context = .{ .lanes = l, .job = job };
    io.vtable.groupConcurrent(io.userdata, &job.cancellation, std.mem.asBytes(&context), .of(Context), cancelEntry) catch @panic("reactor: lane executor refused cancellation");
}

/// The lane's launch lock, taken once an owned lane has a worker free to
/// run what is started under it.
fn launch(l: *Lanes, lane: Lane) aegis.BlockingGuarded(Launch).Guard {
    const state = &l.states[@backingInt(lane)];
    var held = state.launch.acquireUncancelable(system());
    if (l.mode != .owned) return held;
    const launching = held.value();
    const threaded = &l.threaded[@backingInt(lane)];
    const prepared = 2 * @as(usize, state.cap) + 3;
    var activated = false;
    while (true) {
        threaded.mutex.lockUncancelable(system());
        const available = threaded.busy_count < prepared;
        threaded.mutex.unlock(system());
        if (available) return held;
        if (!activated and launching.activated < launching.dormant.len) {
            activated = true;
            launching.dormant[launching.activated].gate.set(system());
            launching.activated += 1;
        }
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
    defer held.deinit(system());
    const queue = held.value();
    return .{ .queued = queue.queued, .running = queue.running, .threads = queue.running, .@"inline" = s.inlined.load(.monotonic) };
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
