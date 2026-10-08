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
const assert = std.debug.assert;
const Io = std.Io;

const native = @import("../native.zig");
const abort = @import("abort.zig").abort;

/// Held for `watches`; by the task while it scans.
mutex: Io.Mutex = .init,
watches: std.DoublyLinkedList = .{},
/// Watches with an operation armed.
armed: std.atomic.Value(u32) = .init(0),
/// 1 while the task waits for an operation to be armed; the futex it
/// waits on.
parked: std.atomic.Value(u32) = .init(0),
task: ?Io.Future(void) = null,
/// How often the task looks at the armed deadlines.
tick: Io.Duration,

/// One socket's operation deadline.
pub const Watch = struct {
    /// Its place among the watched; not to be touched.
    node: std.DoublyLinkedList.Node = .{},
    socket: Io.net.Socket.Handle,
    /// The armed operation's deadline on the awake clock, in nanoseconds;
    /// 0 when none is armed.
    deadline: std.atomic.Value(i64) = .init(0),
    /// Set once a deadline fired and the socket was aborted.
    fired: std.atomic.Value(bool) = .init(false),

    pub fn init(socket: Io.net.Socket.Handle) Watch {
        return .{ .socket = socket };
    }
};

/// Deadlines no shorter than `shortest`: the watching task ticks at a
/// tenth of it, between a millisecond and a second.
pub fn init(shortest: Io.Duration) Deadlines {
    const tenth = @divTrunc(shortest.nanoseconds, 10);
    return .{ .tick = .fromNanoseconds(std.math.clamp(tenth, std.time.ns_per_ms, std.time.ns_per_s)) };
}

/// Every watch must have been removed.
pub fn deinit(d: *Deadlines, io: Io) void {
    assert(d.watches.first == null);
    if (d.task) |*task| task.cancel(io);
    d.* = undefined;
}

/// Watches `w`. False when this `Io` has no task to keep deadlines with:
/// `w` is not added, and operations on it run unbounded.
pub fn add(d: *Deadlines, io: Io, w: *Watch) bool {
    if (native.runtimeOf(io) != null) return true;
    d.mutex.lockUncancelable(io);
    defer d.mutex.unlock(io);
    if (d.task == null) d.task = io.concurrent(watch, .{ d, io }) catch return false;
    d.watches.append(&w.node);
    return true;
}

/// Stops watching `w`, which has no operation under way. Once this
/// returns, nothing touches `w` or its socket.
pub fn remove(d: *Deadlines, io: Io, w: *Watch) void {
    assert(w.deadline.load(.monotonic) == 0);
    if (native.runtimeOf(io) != null) return;
    d.mutex.lockUncancelable(io);
    defer d.mutex.unlock(io);
    d.watches.remove(&w.node);
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
    const at = if (deadline.clock == .awake) deadline.raw else Io.Clock.awake.now(io).addDuration(deadline.durationFromNow(io).raw);
    w.deadline.store(@intCast(@max(1, at.nanoseconds)), .release);
    if (d.armed.fetchAdd(1, .seq_cst) == 0 and d.parked.load(.seq_cst) == 1) {
        d.parked.store(0, .seq_cst);
        io.futexWake(u32, &d.parked.raw, 1);
    }
}

fn disarm(d: *Deadlines, w: *Watch) void {
    w.deadline.store(0, .release);
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
        io.sleep(d.tick, .awake) catch return;
        d.scan(io);
    }
}

fn scan(d: *Deadlines, io: Io) void {
    d.mutex.lockUncancelable(io);
    defer d.mutex.unlock(io);
    const now: i64 = @intCast(Io.Clock.awake.now(io).nanoseconds);
    var it = d.watches.first;
    while (it) |node| : (it = node.next) {
        const w: *Watch = @fieldParentPtr("node", node);
        const deadline = w.deadline.load(.acquire);
        if (deadline == 0 or now < deadline or w.fired.load(.acquire)) continue;
        w.fired.store(true, .release);
        abort(io, w.socket);
    }
}
