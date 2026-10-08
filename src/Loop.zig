//! One thread's completion engine: operations submitted, the kernel's
//! completions delivered by callback or kept for `reap`, timers on its own
//! wheel. It starts no thread, allocates nothing after `init` and installs
//! no signal handler, so any host loop can drive it: call `run(.nowait)`
//! when `backendHandle` is readable or `nextTimeout` has passed, or let
//! `run(.once)` wait in the kernel.
//!
//! One owner thread at a time; on io_uring the thread that called `init`,
//! for the loop's whole life. Only `wake` is safe from any thread.
//!
//! On epoll and kqueue a regular file has no readiness: positional reads
//! and writes, syncs, and streaming calls on such a file are made in place,
//! inside `submit`.
const Loop = @This();

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const backends = @import("backend.zig");
const op = backends.op;
const clocks = @import("clock.zig");
const Wheel = @import("Wheel.zig");

pub const SqPoll = op.SqPoll;

pub const Backend = enum { auto, io_uring, epoll, kqueue, iocp };

pub const Options = struct {
    backend: Backend = .auto,
    /// Operations in flight at once: sizes the completion queue.
    max_ops: u32 = 1024,
    /// Submission queue entries; null: from `max_ops`.
    submission_entries: ?u16 = null,
    /// io_uring features left off even where the kernel has them (tests,
    /// bisecting).
    uring_off: UringFeatures = .{},
    /// The thread that will own the loop.
    owner: Owner = .caller,
    /// Linux only, explicitly requested; failure is reported, never downgraded.
    sqpoll: ?SqPoll = null,
    /// Minimum contiguous send eligible for SEND_ZC; null disables it.
    zero_copy_min: ?usize = null,
    registered_pools: u16 = 64,
    /// Windows: the host's completion port, which the loop shares. The host
    /// waits on it and hands the entries that carry `completionKey()` to
    /// `complete`; `run` then waits on nothing, so the host calls
    /// `run(.nowait)` for timers and work queued meanwhile.
    port: if (builtin.os.tag == .windows) ?std.os.windows.HANDLE else void = if (builtin.os.tag == .windows) null else {},
};

pub const Owner = enum {
    /// The thread calling `init`.
    caller,
    /// The first thread to call `adopt`: build a loop here, run it there.
    adopter,
};

pub const UringFeatures = packed struct {
    accept_ahead: bool = false,
    fixed_files: bool = false,
    defer_taskrun: bool = false,
    msg_ring: bool = false,
    waitid: bool = false,
    linked_timeout: bool = false,
    zero_copy: bool = false,
};

/// Caller-owned and pinned from `submit` until its completion is
/// delivered: the loop never copies or allocates one.
pub const Op = struct {
    // Keep the completion fields beside the kind, ahead of aligned backend
    // scratch. Wheel cancellation then touches fewer cache lines.
    kind: Kind,
    /// Runs inside `run`, on the loop's thread. Null: the completion waits
    /// for `reap`.
    callback: ?*const fn (l: *Loop, o: *Op) void align(@alignOf(Kind)) = null,
    user_data: usize = 0,
    /// Valid once completed, under the field of `kind`.
    result: Result align(@alignOf(Kind)) = undefined,
    /// The loop's and its backend's from `submit` to delivery.
    state: op.State(backends.Scratch) = .{},

    /// Absolute deadline, linked in the kernel where supported. Other
    /// backends are timed by the runtime's wheel.
    deadline: if (builtin.os.tag == .linux) ?Io.Clock.Timestamp else void = if (builtin.os.tag == .linux) null else {},

    pub const Kind = op.Kind;
    pub const Result = op.Result;
};

pub const Waitable = op.Waitable;

pub const InitError = error{ BackendUnavailable, SystemResources, Unexpected } || Allocator.Error;
pub const SubmitError = error{ QueueFull, SystemResources, Unexpected };
pub const RunError = error{ SystemResources, Unexpected };

pub const RunMode = union(enum) {
    /// Submit, take what is complete, return.
    nowait,
    /// As `nowait`, but wait for at least one completion (or a `wake`) first.
    once,
    /// As `once`, but return at this deadline even with nothing done.
    within: Io.Clock.Timestamp,
    /// Run until this deadline (a frame's budget), returning early only on
    /// `wake`.
    until: Io.Clock.Timestamp,
};

/// Where a batch's completions go: the runtime's, set by it.
pub const BatchSink = struct {
    context: *anyopaque,
    complete: *const fn (context: *anyopaque, token: backends.pending.Token, outcome: backends.pending.Outcome) void,
};

backend: backends.Backend,
clock: clocks.Source,
// Keep wheel heads at the start, independent of the backend union size.
wheel: Wheel align(std.atomic.cache_line),
/// Completed operations not delivered yet (finished at submit or cancel).
ready: List = .{},
/// Delivered operations without a callback, oldest first.
reaped: List = .{},
in_flight: u32 = 0,
max_ops: u32,
woken: std.atomic.Value(bool) = .init(false),
batch_sink: ?BatchSink = null,
owner: std.Thread.Id,

const List = struct {
    head: ?*Op = null,
    tail: ?*Op = null,

    fn push(l: *List, o: *Op) void {
        o.state.next = null;
        if (l.tail) |t| t.state.next = o else l.head = o;
        l.tail = o;
    }

    fn pop(l: *List) ?*Op {
        const o = l.head orelse return null;
        l.head = @ptrCast(@alignCast(o.state.next)); // safe: only `push` links, and it links `*Op`s
        if (l.head == null) l.tail = null;
        o.state.next = null;
        return o;
    }
};

/// Builds the backend `options` names. `.auto` is io_uring on Linux, or
/// epoll where io_uring is missing, older or refused; kqueue on macOS and
/// the BSDs. io_uring: the calling thread is the ring's only submitter for
/// the loop's life.
pub fn init(l: *Loop, gpa: Allocator, options: Options) InitError!void {
    if (options.sqpoll != null and (builtin.os.tag != .linux or (options.backend != .auto and options.backend != .io_uring))) return error.BackendUnavailable;
    const native: backends.Backend = switch (options.backend) {
        .auto => if (builtin.os.tag == .linux)
            initUring(gpa, options) catch |err| switch (err) {
                error.BackendUnavailable => if (options.sqpoll != null) return error.BackendUnavailable else try initEpoll(gpa, options),
                else => |e| return e,
            }
        else if (has_kqueue) try initKqueue(gpa, options) else if (builtin.os.tag == .windows) try iocpBackend(gpa, options) else return error.BackendUnavailable,
        .io_uring => try initUring(gpa, options),
        .epoll => try initEpoll(gpa, options),
        .kqueue => try initKqueue(gpa, options),
        .iocp => if (builtin.os.tag == .windows) try iocpBackend(gpa, options) else return error.BackendUnavailable,
    };
    l.* = .{
        .backend = native,
        .clock = .system,
        .wheel = .init(clocks.Source.ticks(.system)),
        .max_ops = options.max_ops,
        .owner = std.Thread.getCurrentId(),
    };
    l.installPressure();
}

const has_kqueue = backends.Kqueue != void;

fn initUring(gpa: Allocator, options: Options) InitError!backends.Backend {
    if (builtin.os.tag != .linux) return error.BackendUnavailable;
    const entries = options.submission_entries orelse ringEntries(options.max_ops);
    const engine = try gpa.create(backends.Uring);
    errdefer gpa.destroy(engine);
    engine.* = backends.Uring.init(gpa, .{
        .entries = entries,
        // The kernel takes at most 65,536; operations beyond the
        // queue's size wait in the kernel (no completion is dropped).
        .completions = std.math.ceilPowerOfTwoAssert(u32, std.math.clamp(options.max_ops, 2 * @as(u32, entries), 1 << 16)),
        .off = @bitCast(options.uring_off),
        .disabled = options.owner == .adopter,
        .sqpoll = options.sqpoll,
        .zero_copy_min = options.zero_copy_min,
        .registered_pools = options.registered_pools,
        .pending_bound = options.max_ops,
    }) catch |err| return switch (err) {
        error.BackendUnavailable => error.BackendUnavailable,
        error.SystemResources => error.SystemResources,
        error.Unexpected => error.Unexpected,
        error.OutOfMemory => error.OutOfMemory,
    };
    return .{ .io_uring = engine };
}

fn initEpoll(gpa: Allocator, options: Options) InitError!backends.Backend {
    if (backends.Epoll == void) return error.BackendUnavailable;
    const engine = try gpa.create(backends.Epoll);
    errdefer gpa.destroy(engine);
    engine.* = try .init(gpa, options.max_ops);
    return .{ .epoll = engine };
}

fn initKqueue(gpa: Allocator, options: Options) InitError!backends.Backend {
    if (!has_kqueue) return error.BackendUnavailable;
    const engine = try gpa.create(backends.Kqueue);
    errdefer gpa.destroy(engine);
    engine.* = try .init(gpa, options.max_ops);
    return .{ .kqueue = engine };
}

fn iocpBackend(gpa: Allocator, options: Options) InitError!backends.Backend {
    // Batch operations in flight, at most 65,536 (as io_uring's completion
    // queue): beyond, a batch operation fails as out of resources.
    const engine = try gpa.create(backends.Iocp);
    errdefer gpa.destroy(engine);
    engine.* = try .init(gpa, .{ .port = options.port, .slots = @min(options.max_ops, 1 << 16) });
    return .{ .iocp = engine };
}

/// The calling thread becomes the loop's owner. For a loop built with
/// `owner = .adopter`, once, on the thread that will run it.
pub fn adopt(l: *Loop) void {
    l.owner = std.Thread.getCurrentId();
    switch (l.backend) {
        .io_uring => |u| if (builtin.os.tag == .linux) u.enable(),
        // A poller serves whichever thread waits on it.
        .epoll, .kqueue, .iocp, .custom => {},
    }
}

pub fn deinit(l: *Loop, gpa: Allocator) void {
    assert(l.in_flight == 0);
    l.backend.deinit(gpa);
    l.* = undefined;
}

fn ringEntries(max_ops: u32) u16 {
    return @intCast(std.math.ceilPowerOfTwoAssert(u32, std.math.clamp(max_ops, 8, 4096)));
}

/// The kernel mechanism under this loop; null for a test's own backend.
pub fn kind(l: *const Loop) ?backends.Kind {
    return l.backend.kind();
}

/// Queued for the next `run`; never blocks. A timer goes on the loop's
/// wheel, or, on the `real` and `boot` clocks, the kernel's absolute
/// timers. An operation that completes at once (a zero-length read or
/// write; on epoll and kqueue, a call the descriptor is ready for) is
/// delivered by the next `run` like any other.
pub fn submit(l: *Loop, o: *Op) SubmitError!void {
    if (!try l.start(o)) return;
    l.in_flight += 1;
    o.state.phase = .done;
    l.ready.push(o);
}

/// As `submit`, but an operation that completes at once is not queued:
/// this returns true, `o.result` is set, and nothing is delivered for it.
/// A host that runs its own tasks saves a trip through its scheduler.
pub fn start(l: *Loop, o: *Op) SubmitError!bool {
    l.assertOwner();
    assert(o.state.phase == .idle);
    if (l.in_flight == l.max_ops) return error.QueueFull;
    o.state = .{};
    switch (o.kind) {
        .timer => |deadline| if (l.backend.kind() == null or (deadline.clock != .real and deadline.clock != .boot)) {
            o.state.phase = .timer;
            l.wheel.arm(&o.state.storage.node, l.deadlineTicks(deadline));
            l.in_flight += 1;
            return false;
        },
        .io => |*operation| if (empty(operation)) |result| {
            o.result = .{ .io = result };
            return true;
        },
        .read_at => |r| if (r.buffer.len == 0) {
            o.result = .{ .read_at = 0 };
            return true;
        },
        .write_at => |w| if (w.bytes.len == 0) {
            o.result = .{ .write_at = 0 };
            return true;
        },
        else => {},
    }
    o.state.storage = .{ .scratch = undefined };
    o.state.phase = .kernel;
    const done = l.backend.submit(o) catch |err| {
        o.state.phase = .idle;
        return err;
    };
    if (done) {
        o.state.phase = .idle;
        return true;
    }
    l.in_flight += 1;
    return false;
}

/// Before `fd` is closed other than by a `close` operation: every loop in
/// the process forgets what it knew of it. A readiness backend keeps a
/// descriptor registered across waits, and the kernel drops that
/// registration when the descriptor closes; were the number to come back
/// for another file unannounced, a loop would wait on a registration that
/// is gone. Nothing to do on io_uring.
pub fn closing(fd: Io.File.Handle) void {
    if (builtin.os.tag == .windows) return;
    backends.readiness.forget(fd);
}

/// Asks the kernel to end `o`. Its completion still arrives: `Canceled`,
/// or its result if it won. A timer on the wheel completes at once, inside
/// this call.
pub fn cancel(l: *Loop, o: *Op) void {
    l.assertOwner();
    switch (o.state.phase) {
        .idle, .done => {},
        .timer => {
            l.wheel.disarm(&o.state.storage.node);
            o.state.canceled = true;
            o.result = .{ .timer = error.Canceled };
            l.deliver(o);
        },
        .kernel => @call(.never_inline, cancelKernel, .{ l, o }),
    }
}

// Keep backend dispatch out of the wheel's cancellation path.
fn cancelKernel(l: *Loop, o: *Op) void {
    if (o.state.canceled) return;
    o.state.canceled = true;
    if (l.backend.cancel(o)) {
        o.state.phase = .done;
        l.ready.push(o);
    }
}

/// Delivers completions (callbacks run, or queued for `reap`) as `mode`
/// allows and returns how many.
pub fn run(l: *Loop, mode: RunMode) RunError!u32 {
    l.assertOwner();
    var delivered: u32 = 0;
    const deadline: ?u64 = switch (mode) {
        .until, .within => |t| l.awakeNs(t),
        else => null,
    };
    while (true) {
        delivered += l.deliverReady();
        delivered += l.expire();
        const wait: backends.Wait = switch (mode) {
            .nowait => .nowait,
            .once => if (delivered > 0) .nowait else l.waitFor(null),
            .within => if (delivered > 0) .nowait else l.waitFor(deadline),
            .until => l.waitFor(deadline),
        };
        var counted: Counted = .{ .loop = l };
        try l.backend.poll(wait, &counted);
        delivered += counted.count;
        delivered += l.expire();
        delivered += l.deliverReady();
        const woken = l.woken.swap(false, .acq_rel);
        switch (mode) {
            .nowait => return delivered,
            .once => if (delivered > 0 or woken) return delivered,
            .within => if (delivered > 0 or woken or l.clock.awake() >= deadline.?) return delivered,
            .until => if (woken or l.clock.awake() >= deadline.?) return delivered,
        }
    }
}

/// Callback-less completions, oldest first, for the host's own scheduler.
pub fn reap(l: *Loop, out: []*Op) []*Op {
    l.assertOwner();
    var n: usize = 0;
    while (n < out.len) : (n += 1) {
        const o = l.reaped.pop() orelse break;
        o.state.phase = .idle;
        out[n] = o;
    }
    return out[0..n];
}

/// Readable when `run(.nowait)` has work: io_uring an eventfd the ring
/// signals, epoll and kqueue their own descriptor. For a host's epoll,
/// GLib or CFRunLoop.
pub fn backendHandle(l: *Loop) error{ Unsupported, SystemResources, Unexpected }!Io.File.Handle {
    return try l.backend.handle() orelse error.Unsupported;
}

/// The longest a host may wait before calling `run(.nowait)`; null when
/// no timer is armed and nothing is ready.
pub fn nextTimeout(l: *const Loop) ?Io.Duration {
    if (l.ready.head != null or l.backend.hasCompletions()) return .zero;
    const next = l.wheel.next() orelse return null;
    const now = l.clock.awake();
    const at = next * std.time.ns_per_us;
    return .fromNanoseconds(if (at > now) at - now else 0);
}

/// From any thread: makes `backendHandle` readable and returns a waiting
/// `run`.
pub fn wake(l: *Loop) void {
    l.woken.store(true, .release);
    l.backend.wake();
}

/// Windows: one entry a host took from its completion port (laid out as
/// `OVERLAPPED_ENTRY`).
pub const PortEntry = if (builtin.os.tag == .windows) backends.Iocp.Entry else void;

/// Windows: the completion key of reactor's entries, on any port.
pub fn completionKey() usize {
    if (builtin.os.tag != .windows) @compileError("completion keys are Windows'");
    return backends.Iocp.key();
}

/// Windows, with `Options.port`: delivers the completions in `entries`, the
/// including Job notifications. Pass every entry from the shared port;
/// entries belonging to the host are ignored. Delivers them as
/// `run` would (callbacks run, or queued for `reap`). Returns how many.
pub fn complete(l: *Loop, entries: []const PortEntry) u32 {
    l.assertOwner();
    var counted: Counted = .{ .loop = l };
    switch (l.backend) {
        .iocp => |b| if (builtin.os.tag == .windows) b.complete(entries, &counted),
        .io_uring, .epoll, .kqueue, .custom => {},
    }
    return counted.count + l.deliverReady();
}

// The loop's own.

fn assertOwner(l: *const Loop) void {
    if (builtin.mode == .debug) assert(l.owner == std.Thread.getCurrentId());
}

/// The result of an operation that moves no bytes, which needs no
/// syscall; null for one that does.
fn empty(operation: *const Io.Operation) ?Io.Cancelable!Io.Operation.Result {
    switch (operation.*) {
        .file_read_streaming => |o| if (total(o.data) == 0) return .{ .file_read_streaming = 0 },
        .file_write_streaming => |o| if (o.header.len == 0 and writeTotal(o.data, o.splat) == 0) return .{ .file_write_streaming = 0 },
        .net_write => |o| if (o.header.len == 0 and o.control.len == 0 and writeTotal(o.data, o.splat) == 0) return .{ .net_write = 0 },
        else => {},
    }
    return null;
}

fn total(data: []const []u8) usize {
    var n: usize = 0;
    for (data) |d| n += d.len;
    return n;
}

fn writeTotal(data: []const []const u8, splat: usize) usize {
    if (data.len == 0) return 0;
    var n: usize = 0;
    for (data[0 .. data.len - 1]) |d| n += d.len;
    return n + data[data.len - 1].len * splat;
}

/// A timestamp on any clock as nanoseconds on the loop's awake timeline.
fn awakeNs(l: *const Loop, t: Io.Clock.Timestamp) u64 {
    const now_awake: i96 = l.clock.now(.awake).nanoseconds;
    const ns: i96 = if (t.clock == .awake) t.raw.nanoseconds else now_awake + (t.raw.nanoseconds - l.clock.now(t.clock).nanoseconds);
    return @intCast(@max(ns, 0));
}

fn deadlineTicks(l: *const Loop, t: Io.Clock.Timestamp) u64 {
    return std.math.divCeil(u64, l.awakeNs(t), std.time.ns_per_us) catch unreachable; // unreachable: the divisor is a constant
}

fn waitFor(l: *const Loop, deadline: ?u64) backends.Wait {
    if (l.ready.head != null) return .nowait;
    const timer: ?u64 = if (l.wheel.count == 0) null else if (l.wheel.next()) |ticks| ticks * std.time.ns_per_us else null;
    const until = if (timer) |t| (if (deadline) |d| @min(t, d) else t) else deadline orelse return .forever;
    const now = l.clock.awake();
    return if (until <= now) .nowait else .{ .ns = until - now };
}

fn expire(l: *Loop) u32 {
    // No timer armed: no clock to read.
    if (l.wheel.count == 0) return 0;
    var fired: Fired = .{ .loop = l };
    l.wheel.advance(l.clock.ticks(), &fired);
    return fired.count;
}

fn deliverReady(l: *Loop) u32 {
    var n: u32 = 0;
    // Only what is queued now: a callback that queues more waits a turn.
    var batch = l.ready;
    l.ready = .{};
    while (batch.pop()) |o| {
        l.deliver(o);
        n += 1;
    }
    return n;
}

/// The completion reaches its owner: a callback now, or the reap queue.
fn deliver(l: *Loop, o: *Op) void {
    l.in_flight -= 1;
    if (o.callback) |callback| {
        o.state.phase = .idle;
        callback(l, o);
    } else {
        o.state.phase = .done;
        l.reaped.push(o);
    }
}

/// The sink a backend's poll delivers to.
const Counted = struct {
    loop: *Loop,
    count: u32 = 0,

    pub fn notified(c: *Counted) void {
        c.count += 1;
    }

    pub fn complete(c: *Counted, o: *Op) void {
        c.count += 1;
        c.loop.deliver(o);
    }

    pub fn completePending(c: *Counted, token: backends.pending.Token, outcome: backends.pending.Outcome) void {
        c.count += 1;
        c.loop.in_flight -= 1;
        const sink = c.loop.batch_sink.?;
        sink.complete(sink.context, token, outcome);
    }
};

/// The sink the wheel fires timers into.
const Fired = struct {
    loop: *Loop,
    count: u32 = 0,

    pub fn fire(f: *Fired, node: *Wheel.Node) void {
        const storage: *op.State(backends.Scratch).Storage = @ptrCast(@alignCast(node)); // safe: the timer owns this union's node
        const state: *op.State(backends.Scratch) = @alignCast(@fieldParentPtr("storage", storage)); // safe: the storage belongs to the operation's state
        const o: *Op = @alignCast(@fieldParentPtr("state", state)); // safe: the state is a field of an operation
        o.result = .{ .timer = {} };
        f.count += 1;
        f.loop.deliver(o);
    }
};

/// The caller owns source on this thread. A message wakes another ring;
/// other backends and foreign threads use the target's ordinary wake.
pub fn wakeFrom(l: *Loop, source: *Loop) void {
    l.woken.store(true, .release);
    if (comptime builtin.os.tag == .linux) if (source != l and source.backend == .io_uring and l.backend == .io_uring) {
        if (source.backend.io_uring.messageWake(l.backend.io_uring)) return;
    };
    l.backend.wake();
}

/// Backend pressure can release kernel references during submission, but
/// user callbacks remain owned by run's ready queue.
fn installPressure(l: *Loop) void {
    if (comptime builtin.os.tag == .linux) if (l.backend == .io_uring) {
        l.backend.io_uring.pressure = .{ .context = l, .complete = Pressure.dispatch };
    };
}
const Pressure = struct {
    loop: *Loop,
    fn dispatch(raw: *anyopaque, cqe: std.os.linux.io_uring_cqe) void {
        const loop: *Loop = @ptrCast(@alignCast(raw)); // safe: installPressure retains the owning loop
        var sink: Pressure = .{ .loop = loop };
        loop.backend.io_uring.complete(cqe, &sink);
    }
    pub fn complete(p: *Pressure, o: *Op) void {
        o.state.phase = .done;
        p.loop.ready.push(o);
    }
    pub fn completePending(p: *Pressure, token: backends.pending.Token, outcome: backends.pending.Outcome) void {
        p.loop.in_flight -= 1;
        const sink = p.loop.batch_sink.?;
        sink.complete(sink.context, token, outcome);
        p.notified();
    }
    pub fn notified(p: *Pressure) void {
        p.loop.woken.store(true, .release);
    }
};
