//! Per-operation deadlines over many sockets, on any `Io`.
//!
//! On a runtime each operation carries its own deadline into the kernel
//! (`operateTimeout`, which never returns while the kernel holds the
//! buffer), and no task watches. Any other `Io` cannot always bound a
//! socket operation itself (`Io.Threaded` refuses a timed read or write on
//! Windows, and on POSIX a timed write waits only for the socket to take
//! bytes, then blocks in `sendmsg` while the peer keeps its window shut),
//! so one task watches every armed operation and ends the late ones by
//! aborting their sockets. It ticks at a tenth of the shortest timeout
//! while operations are armed and parks when none has been for a tick, so
//! an idle set costs no wake-ups.
//!
//! Either way a deadline that fires poisons the socket: it is aborted, so
//! whatever the operation left half done, nothing more moves on it.
const Deadlines = @This();

const std = @import("std");
const aegis = @import("aegis");
const assert = std.debug.assert;
const Io = std.Io;

const clock = @import("../../clock.zig");
const native = @import("../native.zig");
const abort = @import("abort.zig").abort;

/// What the lock holds: the watched, and the task that keeps their
/// deadlines. Held by the task while it scans.
const Watching = struct {
    watches: std.DoublyLinkedList = .{},
    task: ?Io.Future(void) = null,
};

watching: aegis.BlockingGuarded(Watching) = .init(.{}),
/// Watches with an operation armed.
armed: std.atomic.Value(u32) = .init(0),
/// 1 while the task waits for an operation to be armed; the futex it
/// waits on.
parked: std.atomic.Value(u32) = .init(0),
/// How often the task looks at the armed deadlines, in nanoseconds. It only
/// shortens, and `tighten` is what does.
tick: std.atomic.Value(i64),
/// Bumped to cut the task's wait between ticks short; the futex it waits
/// on.
nudge: std.atomic.Value(u32) = .init(0),

const unarmed: clock.Awake = .fromRaw(0);
/// What an `Awake` of zero is armed as: the first nanosecond.
const soonest: clock.Awake = .fromRaw(1);

/// One socket's operation deadline.
pub const Watch = struct {
    /// Its place among the watched; not to be touched.
    node: std.DoublyLinkedList.Node = .{},
    socket: Io.net.Socket.Handle,
    /// The armed operation's deadline; `unarmed` when none is.
    deadline: aegis.Atomic(clock.Awake) = .init(unarmed),
    /// Set once a deadline fired and the socket was aborted.
    fired: std.atomic.Value(bool) = .init(false),

    pub fn init(socket: Io.net.Socket.Handle) Watch {
        return .{ .socket = socket };
    }
};

/// Deadlines no shorter than `shortest`: the watching task ticks at a
/// tenth of it, between a millisecond and a second.
pub fn init(shortest: Io.Duration) Deadlines {
    return .{ .tick = .init(tickFor(shortest)) };
}

/// A tenth of `d`, between a millisecond and a second.
fn tickFor(d: Io.Duration) i64 {
    return @intCast(std.math.clamp(@divTrunc(d.nanoseconds, 10), std.time.ns_per_ms, std.time.ns_per_s)); // safe: clamped to between a millisecond and a second
}

/// Keep deadlines as short as `d` too, which `init` was not told of: the
/// tick shortens to match, at once, even while the task waits out a longer
/// one. A longer `d` changes nothing. On a runtime nothing ticks, and this
/// does nothing.
pub fn tighten(d: *Deadlines, io: Io, shorter: Io.Duration) void {
    if (native.runtimeOf(io) != null) return;
    const want = tickFor(shorter);
    var current = d.tick.load(.monotonic);
    while (want < current) {
        current = d.tick.cmpxchgWeak(current, want, .monotonic, .monotonic) orelse {
            _ = d.nudge.fetchAdd(1, .release);
            io.futexWake(u32, &d.nudge.raw, 1);
            return;
        };
    }
}

/// Every watch must have been removed.
pub fn deinit(d: *Deadlines, io: Io) void {
    var held = d.watching.acquireUncancelable(io);
    assert(held.value().watches.first == null);
    var task = held.value().task;
    held.deinit(io);
    if (task) |*running| running.cancel(io);
    d.* = undefined;
}

/// Watches `w`. False when this `Io` has no task to keep deadlines with:
/// `w` is not added, and operations on it run unbounded.
pub fn add(d: *Deadlines, io: Io, w: *Watch) bool {
    if (native.runtimeOf(io) != null) return true;
    var held = d.watching.acquireUncancelable(io);
    defer held.deinit(io);
    const watching = held.value();
    if (watching.task == null) watching.task = io.concurrent(watch, .{ d, io }) catch return false;
    watching.watches.append(&w.node);
    return true;
}

/// Stops watching `w`, which has no operation under way. Once this
/// returns, nothing touches `w` or its socket.
pub fn remove(d: *Deadlines, io: Io, w: *Watch) void {
    assert(w.deadline.load(.monotonic).eql(unarmed));
    if (native.runtimeOf(io) != null) return;
    var held = d.watching.acquireUncancelable(io);
    defer held.deinit(io);
    held.value().watches.remove(&w.node);
}

pub const OperateError = Io.Cancelable || error{Timeout};

/// One operation on `w`'s socket, ended at `deadline`: `Timeout` when the
/// deadline ended it, else its result. A result the operation reached
/// before the deadline is returned even when the deadline fired, though
/// the socket is aborted then.
pub fn operate(d: *Deadlines, io: Io, w: *Watch, operation: Io.Operation, deadline: Io.Clock.Timestamp) OperateError!Io.Operation.Result {
    if (w.fired.load(.acquire)) return error.Timeout;
    if (native.runtimeOf(io) != null) {
        return io.operateTimeout(operation, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Canceled => error.Canceled,
            // Device control has no evented form: unbounded, as std's.
            error.ConcurrencyUnavailable => io.operate(operation),
            error.Timeout => {
                w.fired.store(true, .release);
                abort(io, w.socket);
                return error.Timeout;
            },
        };
    }
    d.arm(io, w, deadline);
    const result = io.operate(operation);
    d.disarm(w);
    const r = try result;
    if (w.fired.load(.acquire) and failed(r)) return error.Timeout;
    return r;
}

fn failed(r: Io.Operation.Result) bool {
    return switch (r) {
        .file_read_streaming => |x| if (x) |_| false else |_| true,
        .file_write_streaming => |x| if (x) |_| false else |_| true,
        .net_read => |x| if (x) |v| v.data_len == 0 else |_| true,
        .net_write => |x| if (x) |_| false else |_| true,
        .net_receive => |x| x[0] != null,
        .net_send => |x| x[0] != null,
        .device_io_control => false,
    };
}

fn arm(d: *Deadlines, io: Io, w: *Watch, deadline: Io.Clock.Timestamp) void {
    // The watching task reads the awake clock.
    const at: Io.Timestamp = if (deadline.clock == .awake) deadline.raw else .{ .nanoseconds = Io.Clock.awake.now(io).nanoseconds +| deadline.durationFromNow(io).raw.nanoseconds };
    // Zero means unarmed, so a deadline at the very start is the next tick.
    const stamp = clock.awakeOf(at);
    w.deadline.store(if (stamp.eql(unarmed)) soonest else stamp, .release);
    if (d.armed.fetchAdd(1, .seq_cst) == 0 and d.parked.load(.seq_cst) == 1) {
        d.parked.store(0, .seq_cst);
        io.futexWake(u32, &d.parked.raw, 1);
    }
}

fn disarm(d: *Deadlines, w: *Watch) void {
    w.deadline.store(unarmed, .release);
    _ = d.armed.fetchSub(1, .seq_cst);
}

fn watch(d: *Deadlines, io: Io) void {
    var idle_ticks: u32 = 0;
    while (true) {
        if (d.armed.load(.seq_cst) == 0) {
            idle_ticks += 1;
            if (idle_ticks > 1) {
                idle_ticks = 0;
                d.parked.store(1, .seq_cst);
                if (d.armed.load(.seq_cst) == 0) io.futexWait(u32, &d.parked.raw, 1) catch return;
                d.parked.store(0, .seq_cst);
                continue;
            }
        } else idle_ticks = 0;
        const seen = d.nudge.load(.acquire);
        const tick: Io.Duration = .fromNanoseconds(d.tick.load(.monotonic));
        io.futexWaitTimeout(u32, &d.nudge.raw, seen, .{ .duration = .{ .raw = tick, .clock = .awake } }) catch return;
        d.scan(io);
    }
}

fn scan(d: *Deadlines, io: Io) void {
    var held = d.watching.acquireUncancelable(io);
    defer held.deinit(io);
    const now = clock.awakeOf(Io.Clock.awake.now(io));
    var it = held.value().watches.first;
    while (it) |node| : (it = node.next) {
        const w: *Watch = @fieldParentPtr("node", node);
        const deadline = w.deadline.load(.acquire);
        if (deadline.eql(unarmed) or now.compare(deadline) == .lt or w.fired.load(.acquire)) continue;
        w.fired.store(true, .release);
        abort(io, w.socket);
    }
}
