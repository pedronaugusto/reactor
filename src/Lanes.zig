//! Calls that can take milliseconds run off the workers, on four lanes:
//! `sync` (device flushes), `lookup` (name resolution), `wait` (calls that
//! can wait without bound: locks, CPU-clock sleeps), `general` (the rest).
//! Each lane is an owned `Io.Threaded`, so std's own code runs there with
//! std's own cancellation (its thread status, signals and
//! `CancelSynchronousIo`); or the host's injected executor; or nothing, and
//! calls run inline on the caller, counted.
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

pub const Config = union(enum) {
    owned: Owned,
    /// Any `Io` whose `groupConcurrent` runs on a thread of its own.
    injected: Io,
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
    group: Io.Group = .init,
    next: ?*Job = null,
    /// The call, plus one while a cancel of it runs.
    pending: std.atomic.Value(u32) = .init(1),
    /// Cancelled before it started: `run` never ran.
    dropped: bool = false,

    /// Whether the executor still holds the job's group: wait until not
    /// before the job's frame goes.
    pub fn held(job: *const Job) bool {
        return job.group.token.load(.acquire) != null;
    }
};

pub const Stats = struct { queued: u32, running: u32, threads: u16, @"inline": u64 };

const State = struct {
    cap: u16,
    running: u16 = 0,
    head: ?*Job = null,
    tail: ?*Job = null,
    queued: u32 = 0,
    lock: Io.Mutex = .init,
    inlined: std.atomic.Value(u64) = .init(0),
};

mode: std.meta.Tag(Config),
/// The executors: owned instances, the injected one, or none.
threaded: [count]Io.Threaded = undefined,
injected: Io = undefined,
/// std's code borrowed on the workers and for inline calls.
borrowed: Io.Threaded,
states: [count]State,
pool: SlotPool,
scratch: SlotPool,
/// Where cancels of calls run; never awaited until `deinit`.
cancels: Io.Group = .init,

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
    const scratch = try SlotPool.initSized(gpa, total + 16, bytes);
    l.* = .{
        .mode = config,
        .borrowed = .init(.failing, .{ .async_limit = .nothing, .concurrent_limit = .nothing, .environ = env.environ, .argv0 = env.argv0 }),
        .states = undefined,
        // A closure for each running call, each cancel of one, and each
        // call that has ended but whose thread has not yet let go of it.
        .pool = pool,
        .scratch = scratch,
    };
    l.borrowed.allocator = l.allocator();
    for (&l.states, caps) |*s, c| s.* = .{ .cap = c };
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
        .injected => |io| l.injected = io,
        .none => {},
    }
}

pub fn deinit(l: *Lanes, gpa: Allocator) void {
    l.cancels.cancel(l.executor(.general));
    if (l.mode == .owned) {
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
        .injected => .{ 64, 64, 64, 64 },
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

/// Starts `job` on its lane, or queues it behind the lane's cap.
pub fn submit(l: *Lanes, job: *Job) void {
    const s = &l.states[@backingInt(job.lane)];
    s.lock.lockUncancelable(system());
    if (s.running < s.cap) {
        s.running += 1;
        s.lock.unlock(system());
        if (!l.start(job)) l.runHere(job);
        return;
    }
    job.next = null;
    if (s.tail) |t| t.next = job else s.head = job;
    s.tail = job;
    s.queued += 1;
    s.lock.unlock(system());
}

/// `job` as a member of its own group on the lane's executor; false when
/// the executor could take no more.
fn start(l: *Lanes, job: *Job) bool {
    const io = l.executor(job.lane);
    const context: Context = .{ .lanes = l, .job = job };
    io.vtable.groupConcurrent(io.userdata, &job.group, std.mem.asBytes(&context), .of(Context), runEntry) catch return false;
    return true;
}

/// A call the executor could take no thread for, made on this thread
/// rather than failed (counted), and after it the lane's queued calls, one
/// after another, until one can be started on a thread of its own.
fn runHere(l: *Lanes, first: *Job) void {
    var job = first;
    while (true) {
        const lane = job.lane;
        l.countInline(lane);
        job.run(job);
        const following = l.next(lane);
        finish(job);
        job = following orelse return;
        if (l.start(job)) return;
    }
}

const Context = struct { lanes: *Lanes, job: *Job };

fn runEntry(context: *const anyopaque) void {
    const c: *const Context = @ptrCast(@alignCast(context)); // safe: `start` passed a `Context`
    const l = c.lanes;
    const job = c.job;
    const lane = job.lane;
    job.run(job);
    const following = l.next(lane);
    finish(job);
    if (following) |f| if (!l.start(f)) l.runHere(f);
}

/// A call on `lane` ended: the oldest queued one takes its slot, or the
/// slot is freed.
fn next(l: *Lanes, lane: Lane) ?*Job {
    const s = &l.states[@backingInt(lane)];
    s.lock.lockUncancelable(system());
    defer s.lock.unlock(system());
    const job = s.head orelse {
        s.running -= 1;
        return null;
    };
    s.head = job.next;
    if (s.head == null) s.tail = null;
    s.queued -= 1;
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
    s.lock.unlock(system());
    var pending = job.pending.load(.acquire);
    while (true) {
        if (pending == 0) return;
        pending = job.pending.cmpxchgWeak(pending, pending + 1, .acq_rel, .acquire) orelse break;
    }
    const io = l.executor(job.lane);
    const context: Context = .{ .lanes = l, .job = job };
    io.vtable.groupConcurrent(io.userdata, &l.cancels, std.mem.asBytes(&context), .of(Context), cancelEntry) catch finish(job);
}

fn unqueue(s: *State, job: *Job) bool {
    var prev: ?*Job = null;
    var it = s.head;
    while (it) |j| : ({
        prev = j;
        it = j.next;
    }) {
        if (j != job) continue;
        if (prev) |p| p.next = j.next else s.head = j.next;
        if (s.tail == j) s.tail = prev;
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
