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
    scratch_bytes: u32 = 256 << 10,
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
    admitted: bool = false,
    /// Child termination bypasses occupied wait slots using reserved control capacity.
    control: bool = false,
    next: ?*Job = null,
    /// The call, plus one while a cancel of it runs.
    pending: std.atomic.Value(u32) = .init(1),
    /// Cancelled before it started: `run` never ran.
    dropped: bool = false,
    /// The executor refused the call; no user code ran.
    rejected: bool = false,

    /// Whether the executor still holds the job's group: wait until not
    /// before the job's frame goes.
    pub fn held(job: *const Job) bool {
        return job.group.token.load(.acquire) != null or job.cancellation.token.load(.acquire) != null;
    }
};

pub const Stats = struct { queued: u32, running: u32, threads: u16, @"inline": u64 };

const State = struct {
    cap: u16,
    running: u16 = 0,
    admitted: u32 = 0,
    limit: u32,
    launch: Io.Mutex = .init,
    dormant: []Warm = &.{},
    activated: usize = 0,
    head: [2]?*Job = .{ null, null },
    tail: [2]?*Job = .{ null, null },
    latency_runs: u8 = 0,
    queued: u32 = 0,
    lock: Io.Mutex = .init,
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
reserved: u32 = 0,
control_admitted: bool = false,
admission_lock: Io.Mutex = .init,

pub fn init(l: *Lanes, gpa: Allocator, config: Config, env: Environment) Allocator.Error!void {
    const caps = capsOf(config);
    var total: u32 = 0;
    for (caps) |c| total += c;
    var pool = try SlotPool.init(gpa, 4 * total + 16);
    errdefer pool.deinit(gpa);
    const bytes = switch (config) {
        .owned => |o| o.scratch_bytes,
        else => 256 << 10,
    };
    var scratch = try SlotPool.initSized(gpa, total + 16, bytes);
    errdefer scratch.deinit(gpa);
    const warm_entries = try gpa.alloc(Warm, if (config == .owned) 2 * total + 3 * count else 0);
    for (warm_entries) |*entry| entry.* = .{};
    l.* = .{
        .mode = config,
        .borrowed = .init(.failing, .{ .async_limit = .nothing, .concurrent_limit = .nothing, .environ = env.environ, .argv0 = env.argv0 }),
        .states = undefined,
        // A closure for each running call, each cancel of one, and each
        // call that has ended but whose thread has not yet let go of it.
        .pool = pool,
        .scratch = scratch,
        .warm_entries = warm_entries,
    };
    l.borrowed.allocator = l.allocator();
    for (&l.states, caps) |*s, c| s.* = .{ .cap = c, .limit = env.max_jobs };
    if (config == .owned) {
        var offset: usize = 0;
        for (&l.states) |*state| {
            const n = 2 * @as(usize, state.cap) + 3;
            state.dormant = warm_entries[offset..][0..n];
            offset += n;
        }
    }
    if (config == .injected) l.capacity = config.injected.capacity;
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
    for (l.states) |state| assert(state.admitted == 0);
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
    for (state.dormant) |*entry| {
        const pointer = entry;
        io.vtable.groupConcurrent(io.userdata, group, std.mem.asBytes(&pointer), .of(@TypeOf(pointer)), Warm.run) catch return error.SystemResources;
    }
    for (state.dormant) |*entry| while (!entry.entered.load(.acquire)) std.atomic.spinLoopHint();
    state.dormant[0].gate.set(system());
    state.activated = 1;
    while (true) {
        threaded.mutex.lockUncancelable(system());
        const available = threaded.busy_count < state.dormant.len;
        threaded.mutex.unlock(system());
        if (available) return;
        std.atomic.spinLoopHint();
    }
}

/// Reserve execution and cancellation together, before publishing a call.
/// A reservation survives completion until both executor groups retire.
pub fn admit(l: *Lanes, job: *Job) bool {
    if (!l.started) return false;
    const state = &l.states[@backingInt(job.lane)];
    l.admission_lock.lockUncancelable(system());
    defer l.admission_lock.unlock(system());
    if (state.cap == 0 or (!job.control and state.admitted >= state.limit)) return false;
    if (job.control) {
        if (l.control_admitted) return false;
    } else if (l.mode == .injected and l.capacity - l.reserved < 4) return false;
    if (l.mode == .injected and l.capacity - l.reserved < 2) return false;
    if (job.control) l.control_admitted = true;
    state.admitted += 1;
    l.reserved += 2;
    job.admitted = true;
    return true;
}

/// Starts an admitted job, or queues it behind the lane's running cap.
/// Standalone fallible callers may submit without an earlier reservation.
pub fn submit(l: *Lanes, job: *Job) void {
    if (!job.admitted and !l.admit(job)) {
        job.rejected = true;
        return finish(job);
    }
    const s = &l.states[@backingInt(job.lane)];
    s.lock.lockUncancelable(system());
    if (job.control) {
        const accepted = l.start(job);
        s.lock.unlock(system());
        if (!accepted) {
            job.rejected = true;
            finish(job);
        }
        return;
    }
    if (s.running < s.cap) {
        s.running += 1;
        const accepted = l.start(job);
        s.lock.unlock(system());
        if (!accepted) l.reject(job);
        return;
    }
    job.next = null;
    const class = @backingInt(job.priority);
    if (s.tail[class]) |t| t.next = job else s.head[class] = job;
    s.tail[class] = job;
    s.queued += 1;
    s.lock.unlock(system());
}

/// After execution and cancellation have retired, release their reservation.
/// Running slots may already serve queued calls; their reservations are distinct.
pub fn retire(l: *Lanes, job: *Job) void {
    assert(!job.held());
    assert(job.pending.load(.acquire) == 0);
    if (!job.admitted) return;
    l.admission_lock.lockUncancelable(system());
    l.states[@backingInt(job.lane)].admitted -= 1;
    l.reserved -= 2;
    if (job.control) l.control_admitted = false;
    job.admitted = false;
    l.admission_lock.unlock(system());
}

/// `job` as a member of its own group on the lane's executor; false when
/// the executor could take no more.
fn start(l: *Lanes, job: *Job) bool {
    const io = l.executor(job.lane);
    l.launch(job.lane);
    defer l.states[@backingInt(job.lane)].launch.unlock(system());
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
    const s = &l.states[@backingInt(lane)];
    s.lock.lockUncancelable(system());
    defer s.lock.unlock(system());
    const class: usize = if (s.head[1] != null and (s.latency_runs < 8 or s.head[0] == null)) 1 else 0;
    const job = s.head[class] orelse {
        s.running -= 1;
        return null;
    };
    s.head[class] = job.next;
    if (s.head[class] == null) s.tail[class] = null;
    if (class == 1) s.latency_runs +|= 1 else s.latency_runs = 0;
    s.queued -= 1;
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
    const s = &l.states[@backingInt(job.lane)];
    s.lock.lockUncancelable(system());
    if (unqueue(s, job)) {
        s.lock.unlock(system());
        job.dropped = true;
        return finish(job);
    }
    defer s.lock.unlock(system());
    var pending = job.pending.load(.acquire);
    while (true) {
        if (pending == 0) return;
        pending = job.pending.cmpxchgWeak(pending, pending + 1, .acq_rel, .acquire) orelse break;
    }
    const io = l.executor(job.lane);
    l.launch(job.lane);
    defer l.states[@backingInt(job.lane)].launch.unlock(system());
    const context: Context = .{ .lanes = l, .job = job };
    io.vtable.groupConcurrent(io.userdata, &job.cancellation, std.mem.asBytes(&context), .of(Context), cancelEntry) catch @panic("reactor: lane executor refused cancellation");
}

fn launch(l: *Lanes, lane: Lane) void {
    const state = &l.states[@backingInt(lane)];
    state.launch.lockUncancelable(system());
    if (l.mode != .owned) return;
    const threaded = &l.threaded[@backingInt(lane)];
    const prepared = 2 * @as(usize, state.cap) + 3;
    var activated = false;
    while (true) {
        threaded.mutex.lockUncancelable(system());
        const available = threaded.busy_count < prepared;
        threaded.mutex.unlock(system());
        if (available) return;
        if (!activated and state.activated < state.dormant.len) {
            activated = true;
            state.dormant[state.activated].gate.set(system());
            state.activated += 1;
        }
        std.atomic.spinLoopHint();
    }
}

fn unqueue(s: *State, job: *Job) bool {
    var prev: ?*Job = null;
    const class = @backingInt(job.priority);
    var it = s.head[class];
    while (it) |j| : ({
        prev = j;
        it = j.next;
    }) {
        if (j != job) continue;
        if (prev) |p| p.next = j.next else s.head[class] = j.next;
        if (s.tail[class] == j) s.tail[class] = prev;
        s.queued -= 1;
        return true;
    }
    return false;
}

fn cancelEntry(context: *const anyopaque) void {
    const c: *const Context = @ptrCast(@alignCast(context)); // safe: `cancel` passed a `Context`
    c.job.group.cancel(c.lanes.executor(c.job.lane));
    finish(c.job);
}

pub fn stats(l: *Lanes, lane: Lane) Stats {
    const s = &l.states[@backingInt(lane)];
    s.lock.lockUncancelable(system());
    defer s.lock.unlock(system());
    return .{ .queued = s.queued, .running = s.running, .threads = s.running, .@"inline" = s.inlined.load(.monotonic) };
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
