//! One thread's completion engine: operations submitted, the kernel's
//! completions delivered by callback or kept for `reap`, timers on its own
//! wheel. It starts no thread, allocates nothing after `init` and installs
//! no signal handler, so any host loop can drive it: call `run(.nowait)`
//! when `backendHandle` is readable or `nextTimeout` has passed, or let
//! `run(.once)` wait in the kernel.
//!
//! One owner thread at a time; on io_uring the thread that called `init`,
//! for the loop's whole life. Only `wake` is safe from any thread.
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
    /// Windows: the host's completion port, which the loop shares. The host
    /// waits on it and hands the entries that carry `completion_key` to
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
    multishot_accept: bool = false,
    fixed_files: bool = false,
    defer_taskrun: bool = false,
    msg_ring: bool = false,
    waitid: bool = false,
    linked_timeout: bool = false,
};

/// Caller-owned and pinned from `submit` until its completion is
/// delivered: the loop never copies or allocates one.
pub const Op = struct {
    kind: Kind,
    /// Runs inside `run`, on the loop's thread. Null: the completion waits
    /// for `reap`.
    callback: ?*const fn (l: *Loop, o: *Op) void = null,
    user_data: usize = 0,
    /// Valid once completed, under the field of `kind`.
    result: Result = undefined,
    /// The loop's and its backend's from `submit` to delivery.
    state: op.State(backends.Scratch) = .{},

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
wheel: Wheel,
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

/// Builds the backend `options` names. io_uring: the calling thread is
/// the ring's only submitter for the loop's life.
pub fn init(l: *Loop, gpa: Allocator, options: Options) InitError!void {
    const linux = builtin.os.tag == .linux;
    const windows = builtin.os.tag == .windows;
    const native: backends.Backend = switch (options.backend) {
        .auto => if (linux) try uringBackend(options) else if (windows) try iocpBackend(gpa, options) else return error.BackendUnavailable,
        .io_uring => if (linux) try uringBackend(options) else return error.BackendUnavailable,
        .iocp => if (windows) try iocpBackend(gpa, options) else return error.BackendUnavailable,
        .epoll, .kqueue => return error.BackendUnavailable,
    };
    l.* = .{
        .backend = native,
        .clock = .system,
        .wheel = .init(clocks.Source.ticks(.system)),
        .max_ops = options.max_ops,
        .owner = std.Thread.getCurrentId(),
    };
}

fn uringBackend(options: Options) InitError!backends.Backend {
    const entries = options.submission_entries orelse ringEntries(options.max_ops);
    return .{ .io_uring = backends.Uring.init(.{
        .entries = entries,
        // The kernel takes at most 65,536; operations beyond the queue's
        // size wait in the kernel (no completion is dropped).
        .completions = std.math.ceilPowerOfTwoAssert(u32, std.math.clamp(options.max_ops, 2 * @as(u32, entries), 1 << 16)),
        .off = @bitCast(options.uring_off),
        .disabled = options.owner == .adopter,
    }) catch |err| return switch (err) {
        error.BackendUnavailable => error.BackendUnavailable,
        error.SystemResources => error.SystemResources,
        error.Unexpected => error.Unexpected,
    } };
}

fn iocpBackend(gpa: Allocator, options: Options) InitError!backends.Backend {
    return .{ .iocp = try backends.Iocp.init(gpa, .{ .port = options.port, .slots = options.max_ops }) };
}

/// The calling thread becomes the loop's owner. For a loop built with
/// `owner = .adopter`, once, on the thread that will run it.
pub fn adopt(l: *Loop) void {
    l.owner = std.Thread.getCurrentId();
    switch (l.backend) {
        .io_uring => |*u| if (builtin.os.tag == .linux) u.enable(),
        .iocp, .custom => {},
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
/// wheel (awake clock) or the kernel's absolute timers (real, boot); a
/// zero-length read or write completes at once.
pub fn submit(l: *Loop, o: *Op) SubmitError!void {
    l.assertOwner();
    assert(o.state.phase == .idle);
    if (l.in_flight == l.max_ops) return error.QueueFull;
    o.state = .{};
    l.in_flight += 1;
    errdefer l.in_flight -= 1;
    switch (o.kind) {
        .timer => |deadline| if (deadline.clock == .awake or l.backend.kind() == null) {
            o.state.phase = .timer;
            l.wheel.arm(&o.state.node, l.deadlineTicks(deadline));
            return;
        },
        .io => |*operation| if (empty(operation)) |result| {
            o.result = .{ .io = result };
            o.state.phase = .done;
            l.ready.push(o);
            return;
        },
        .read_at => |r| if (r.buffer.len == 0) {
            o.result = .{ .read_at = 0 };
            o.state.phase = .done;
            l.ready.push(o);
            return;
        },
        .write_at => |w| if (w.bytes.len == 0) {
            o.result = .{ .write_at = 0 };
            o.state.phase = .done;
            l.ready.push(o);
            return;
        },
        else => {},
    }
    o.state.phase = .kernel;
    errdefer o.state.phase = .idle;
    // Finished at once (IOCP's skip on success): delivered by the next
    // `run`, as a completion finished at submit always is.
    if (try l.backend.submit(o)) {
        o.state.phase = .done;
        l.ready.push(o);
    }
}

/// Asks the kernel to end `o`. Its completion still arrives: `Canceled`,
/// or its result if it won. A timer on the wheel completes at once, inside
/// this call.
pub fn cancel(l: *Loop, o: *Op) void {
    l.assertOwner();
    switch (o.state.phase) {
        .idle, .done => {},
        .timer => {
            l.wheel.disarm(&o.state.node);
            o.state.canceled = true;
            o.result = .{ .timer = error.Canceled };
            l.deliver(o);
        },
        .kernel => if (!o.state.canceled) {
            o.state.canceled = true;
            if (l.backend.cancel(o)) {
                o.state.phase = .done;
                l.ready.push(o);
            }
        },
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
    while (n < out.len) : (n += 1) out[n] = l.reaped.pop() orelse break;
    return out[0..n];
}

/// What a host waits on for `run(.nowait)`'s work. io_uring: an eventfd the
/// ring signals, readable then (for a host's epoll, GLib or CFRunLoop).
/// IOCP: the completion port (ports cannot be waited on by other means; a
/// host with a port of its own shares it through `Options.port`).
pub fn backendHandle(l: *Loop) error{ Unsupported, SystemResources, Unexpected }!Io.File.Handle {
    return try l.backend.handle() orelse error.Unsupported;
}

/// The longest a host may wait before calling `run(.nowait)`; null when
/// no timer is armed and nothing is ready.
pub fn nextTimeout(l: *const Loop) ?Io.Duration {
    if (l.ready.head != null) return .zero;
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
/// ones the host took from its port that carry `completionKey()`, as
/// `run` would (callbacks run, or queued for `reap`). Returns how many.
pub fn complete(l: *Loop, entries: []const PortEntry) u32 {
    l.assertOwner();
    var counted: Counted = .{ .loop = l };
    switch (l.backend) {
        .iocp => |*b| if (builtin.os.tag == .windows) b.complete(entries, &counted),
        .io_uring, .custom => {},
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
        const state: *op.State(backends.Scratch) = @alignCast(@fieldParentPtr("node", node)); // safe: the node is a field of an operation's state
        const o: *Op = @alignCast(@fieldParentPtr("state", state)); // safe: the state is a field of an operation
        o.result = .{ .timer = {} };
        f.count += 1;
        f.loop.deliver(o);
    }
};
