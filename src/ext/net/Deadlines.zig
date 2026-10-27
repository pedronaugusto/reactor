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
const Raised = @import("../../sync/Raised.zig");

/// Watches with an operation armed.
const Armed = aegis.units.Count(Watch, u32);

/// What the lock holds: the watched, and the task that keeps their
/// deadlines. Held by the task while it scans.
const Watching = struct {
    watches: std.DoublyLinkedList = .{},
    task: ?Io.Future(void) = null,
};

watching: aegis.BlockingGuarded(Watching) = .init(.{}),
/// Watches with an operation armed.
armed: aegis.Atomic(Armed) = .init(.fromRaw(0)),
/// 1 while the task waits for an operation to be armed; the futex it
/// waits on.
// aegis: boundary: a futex word: the kernel waits on this u32's address
parked: std.atomic.Value(u32) = .init(0),
/// How often the task looks at the armed deadlines. It only shortens, and
/// `tighten` is what does.
tick: aegis.Atomic(clock.Span),
/// Bumped to cut the task's wait between ticks short; the futex it waits
/// on.
// aegis: boundary: a futex word: the kernel waits on this u32's address
nudge: std.atomic.Value(u32) = .init(0),

const unarmed: clock.Awake = .fromRaw(0);
/// What an `Awake` of zero is armed as: the first nanosecond.
const soonest: clock.Awake = .fromRaw(1);

/// One socket's or named pipe's operation deadline.
pub const Watch = struct {
    /// Its place among the watched; not to be touched.
    node: std.DoublyLinkedList.Node = .{},
    target: Target,
    /// The armed operation's deadline; `unarmed` when none is.
    deadline: aegis.Atomic(clock.Awake) = .init(unarmed),
    /// Raised once a deadline fired and the socket was aborted.
    fired: Raised = .{},

    /// What the operations are on.
    pub const Target = union(enum) {
        socket: Io.net.Socket.Handle,
        /// A named pipe, Windows': its deadlines are kept on a runtime,
        /// where each operation carries its own. No other `Io` can end
        /// one of its operations from outside, so `add` refuses it there.
        pipe: Io.File,
    };

    pub fn init(socket: Io.net.Socket.Handle) Watch {
        return .{ .target = .{ .socket = socket } };
    }

    pub fn initPipe(pipe: Io.File) Watch {
        return .{ .target = .{ .pipe = pipe } };
    }

    /// Ends what is under way on the target and after: a socket's
    /// operations by `abort`; a pipe's operation was ended by its own
    /// deadline, and `fired` refuses the ones after it.
    fn end(w: *const Watch, io: Io) void {
        switch (w.target) {
            .socket => |socket| abort(io, socket),
            .pipe => {},
        }
    }
};

/// Deadlines no shorter than `shortest`: the watching task ticks at a
/// tenth of it, between a millisecond and a second.
pub fn init(shortest: Io.Duration) Deadlines {
    return .{ .tick = .init(tickFor(shortest)) };
}

/// A tenth of `d`, between a millisecond and a second.
fn tickFor(d: Io.Duration) clock.Span {
    const tenth = clock.spanOf(d).divTrunc(10) catch unreachable; // unreachable: the divisor is a constant
    const shortest: clock.Span = .literal("1ms");
    const longest: clock.Span = .literal("1s");
    if (tenth.compare(shortest) == .lt) return shortest;
    if (tenth.compare(longest) == .gt) return longest;
    return tenth;
}

/// Keep deadlines as short as `d` too, which `init` was not told of: the
/// tick shortens to match, at once, even while the task waits out a longer
/// one. A longer `d` changes nothing. On a runtime nothing ticks, and this
/// does nothing.
pub fn tighten(d: *Deadlines, io: Io, shorter: Io.Duration) void {
    if (native.runtimeOf(io) != null) return;
    const want = tickFor(shorter);
    var current = d.tick.load(.monotonic);
    while (want.compare(current) == .lt) {
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

/// Watches `w`. False when this `Io` has no task to keep deadlines with,
/// or `w` is a pipe's off a runtime: `w` is not added, and operations on
/// it run unbounded.
pub fn add(d: *Deadlines, io: Io, w: *Watch) bool {
    if (native.runtimeOf(io) != null) return true;
    // std's own wait on an overlapped call cannot be ended from outside:
    // a cancel it did not ask for is a state it does not expect.
    if (w.target == .pipe) return false;
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
    if (native.runtimeOf(io) != null or w.target == .pipe) return;
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
    if (w.fired.raised()) return error.Timeout;
    if (native.runtimeOf(io) != null) {
        return io.operateTimeout(operation, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Canceled => error.Canceled,
            // Device control has no evented form: unbounded, as std's.
            error.ConcurrencyUnavailable => io.operate(operation),
            error.Timeout => {
                _ = w.fired.raise();
                w.end(io);
                return error.Timeout;
            },
        };
    }
    // A pipe's operation off a runtime runs unbounded, as `add` said.
    if (w.target == .pipe) return io.operate(operation);
    d.arm(io, w, deadline);
    const result = io.operate(operation);
    d.disarm(w);
    const r = try result;
    if (w.fired.raised() and failed(r)) return error.Timeout;
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
    const stamp = if (deadline.clock == .awake) clock.awakeOf(deadline.raw) else clock.carried(deadline.raw, deadline.clock.now(io), Io.Clock.awake.now(io));
    // Zero means unarmed, so a deadline at the very start is the next tick.
    w.deadline.store(if (stamp.eql(unarmed)) soonest else stamp, .release);
    if (d.armed.fetchAddWrapping(.fromRaw(1), .seq_cst).eql(.fromRaw(0)) and d.parked.load(.seq_cst) == 1) {
        d.parked.store(0, .seq_cst);
        io.futexWake(u32, &d.parked.raw, 1);
    }
}

fn disarm(d: *Deadlines, w: *Watch) void {
    w.deadline.store(unarmed, .release);
    _ = d.armed.fetchSubWrapping(.fromRaw(1), .seq_cst);
}

fn watch(d: *Deadlines, io: Io) void {
    var idle_ticks: u32 = 0;
    while (true) {
        if (d.armed.load(.seq_cst).eql(.fromRaw(0))) {
            idle_ticks += 1;
            if (idle_ticks > 1) {
                idle_ticks = 0;
                d.parked.store(1, .seq_cst);
                if (d.armed.load(.seq_cst).eql(.fromRaw(0))) io.futexWait(u32, &d.parked.raw, 1) catch return;
                d.parked.store(0, .seq_cst);
                continue;
            }
        } else idle_ticks = 0;
        const seen = d.nudge.load(.acquire);
        const tick = d.tick.load(.monotonic).toIoDuration();
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
        if (deadline.eql(unarmed) or now.compare(deadline) == .lt or w.fired.raised()) continue;
        _ = w.fired.raise();
        w.end(io);
    }
}
