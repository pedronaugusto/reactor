//! A task waiting on one loop operation: submitted on the processor the
//! task runs on, completed there, and cancelled there; or not waiting at
//! all, when the loop makes the operation at once. A cancel from
//! another thread becomes a message to that processor, which asks its own
//! kernel queue; the operation's completion still decides the outcome, so
//! an operation that finished first keeps its result. A deadline is a
//! timer on the same processor that asks the kernel to end the operation
//! the same way.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Io = std.Io;

const Loop = @import("../Loop.zig");
const Task = @import("../scheduler/Task.zig");
const Processor = @import("../Scheduler.zig").Processor;
const Scheduler = @import("../Scheduler.zig");

pub const Error = error{ Canceled, Timeout, SystemResources };

pub const Options = struct {
    /// A cancel request ends the wait.
    cancelable: bool = true,
    /// The operation is ended here, and `run` returns `Timeout`, unless it
    /// completed first.
    deadline: ?Io.Clock.Timestamp = null,
};

const Waiter = struct {
    hook: Task.Hook = .{ .cancel = cancelHook },
    task: *Task,
    processor: *Processor,
    scheduler: *Scheduler,
    o: *Loop.Op,
    /// Set on the processor when this task's cancel ended the operation.
    requested: bool = false,
    timed_out: bool = false,
    deadline: Deadline = .{ .fire = expired },

    fn cancelHook(hook: *Task.Hook, t: *Task) void {
        const w: *Waiter = @alignCast(@fieldParentPtr("hook", hook)); // safe: the field belongs to this record
        if (Scheduler.processor() == w.processor) {
            w.requested = true;
            w.processor.loop.cancel(w.o);
        } else {
            w.processor.pushCancel(t);
        }
    }

    fn done(l: *Loop, o: *Loop.Op) void {
        _ = l;
        const w: *Waiter = @ptrFromInt(o.user_data); // safe: `run` stored the waiter's address
        if (descriptorOf(o.kind)) |fd| w.processor.release(fd);
        w.scheduler.ready(w.task, .completed);
    }

    fn expired(d: *Deadline) void {
        const w: *Waiter = @alignCast(@fieldParentPtr("deadline", d)); // safe: the field belongs to this record
        w.timed_out = true;
        w.processor.loop.cancel(w.o);
    }
};

/// A deadline on the running task's processor: a timer whose `fire` runs
/// there when it passes. The task is held on that processor from `arm` to
/// `disarm`, so the timer is only ever touched by the thread that owns its
/// loop; and `disarm` returns only once the loop has let go of the timer,
/// waiting for the cancel of one the kernel holds (the `real` and `boot`
/// clocks' timers are the kernel's), since the timer lives in the task's
/// frame.
pub const Deadline = struct {
    op: Loop.Op = .{ .kind = .{ .timer = undefined } },
    /// On the processor, when the deadline passes before `disarm`.
    fire: *const fn (d: *Deadline) void,
    scheduler: *Scheduler = undefined,
    processor: *Processor = undefined,
    task: *Task = undefined,
    armed: bool = false,
    /// The owner waits for the cancel of a timer the kernel holds.
    waiting: bool = false,

    /// Arms it for the running task; false when its loop has no room.
    pub fn arm(d: *Deadline, s: *Scheduler, at: Io.Clock.Timestamp) bool {
        const p = Scheduler.processor().?;
        d.scheduler = s;
        d.processor = p;
        d.task = p.current.?;
        d.op.kind = .{ .timer = at };
        d.op.callback = callback;
        p.loop.submit(&d.op) catch return false;
        d.task.pins += 1;
        d.armed = true;
        return true;
    }

    fn callback(l: *Loop, o: *Loop.Op) void {
        _ = l;
        const d: *Deadline = @alignCast(@fieldParentPtr("op", o)); // safe: the field belongs to this record
        if (d.waiting) {
            d.waiting = false;
            return d.scheduler.ready(d.task, .completed);
        }
        if (o.result.timer) |_| d.fire(d) else |_| {}
    }

    /// From the task that armed it: no `fire` after this, and the loop
    /// holds the timer no longer.
    pub fn disarm(d: *Deadline) void {
        if (!d.armed) return;
        d.armed = false;
        const p = d.processor;
        assert(Scheduler.processor() == p);
        if (d.op.state.phase != .idle) {
            p.loop.cancel(&d.op);
            // A wheel timer is delivered inside the cancel; the kernel's
            // comes back later.
            if (d.op.state.phase != .idle) {
                d.waiting = true;
                Scheduler.park(null);
            }
        }
        d.task.pins -= 1;
    }
};

/// Runs `o` for the running task and waits for its completion. Returns
/// `Canceled` only when this task's cancel ended it, `Timeout` only when
/// the deadline did; `o.result` holds the result otherwise.
pub fn run(s: *Scheduler, o: *Loop.Op, options: Options) Error!void {
    const p = Scheduler.processor().?;
    const t = p.current.?;
    const previous_operation = t.operation;
    t.operation = std.meta.activeTag(o.kind);
    defer t.operation = previous_operation;
    var w: Waiter = .{ .task = t, .processor = p, .scheduler = s, .o = o };
    o.callback = Waiter.done;
    o.user_data = @intFromPtr(&w); // safe: read back by the callback while this frame waits
    if (options.cancelable) try t.enterWait(&w.hook);
    const fd = descriptorOf(o.kind);
    if (fd) |d| p.hold(d);
    if (builtin.os.tag == .linux) o.linked = .of(options.deadline);
    const done = p.loop.start(o) catch {
        if (fd) |d| p.release(d);
        t.leaveWait();
        return error.SystemResources;
    };
    if (done) {
        // Made at once (a readiness backend's call the descriptor was
        // ready for): no park, but the task's budget pays for it.
        if (fd) |d| p.release(d);
        t.leaveWait();
        s.spend();
        return;
    }
    if (!o.state.uring.timeout_pending) if (options.deadline) |at| {
        // No room for the timer: end the operation now.
        if (!w.deadline.arm(s, at)) {
            w.timed_out = true;
            p.loop.cancel(o);
        }
    };
    Scheduler.park(null);
    w.deadline.disarm();
    t.leaveWait();
    if (!canceledResult(o)) return;
    if (w.requested) return t.acknowledge();
    if (w.timed_out or o.state.uring.timed_out) return error.Timeout;
}

/// Runs an accept on its listener's one processor. Persistent accept queues
/// cannot follow a task when it is stolen by another worker.
pub fn accept(s: *Scheduler, p: *Processor, o: *Loop.Op) Error!void {
    if (Scheduler.processor() == p) return run(s, o, .{});
    const t = Scheduler.current().?;
    const previous = t.operation;
    t.operation = .accept;
    defer t.operation = previous;
    var request: RemoteAccept = .{ .task = t, .processor = p, .scheduler = s, .op = o };
    try t.enterWait(&request.hook);
    Scheduler.park(.{ .func = RemoteAccept.publish, .context = &request });
    t.leaveWait();
    if (request.failure) |err| {
        if (err == error.Canceled) return t.acknowledge();
        return err;
    }
    if (canceledResult(o) and request.requested) return t.acknowledge();
}

const RemoteAccept = struct {
    errand: Scheduler.Errand = .{ .run = submit },
    hook: Task.Hook = .{ .cancel = cancel },
    task: *Task,
    processor: *Processor,
    scheduler: *Scheduler,
    op: *Loop.Op,
    submitted: bool = false,
    requested: bool = false,
    failure: ?Error = null,

    fn publish(raw: *anyopaque, _: *Task) void {
        const request: *RemoteAccept = @ptrCast(@alignCast(raw)); // safe: accept parks this request
        request.processor.send(&request.errand);
    }

    fn submit(e: *Scheduler.Errand, p: *Processor) void {
        const request: *RemoteAccept = @alignCast(@fieldParentPtr("errand", e)); // safe: embedded errand
        if (request.requested) {
            request.failure = error.Canceled;
            return request.scheduler.ready(request.task, .completed);
        }
        const o = request.op;
        o.callback = done;
        o.user_data = @intFromPtr(request); // safe: retained until the completion callback
        p.hold(o.kind.accept);
        p.loop.submit(o) catch {
            p.release(o.kind.accept);
            request.failure = error.SystemResources;
            return request.scheduler.ready(request.task, .completed);
        };
        request.submitted = true;
    }

    fn done(_: *Loop, o: *Loop.Op) void {
        const request: *RemoteAccept = @ptrFromInt(o.user_data); // safe: submit retained the request
        request.processor.release(o.kind.accept);
        request.scheduler.ready(request.task, .completed);
    }

    fn cancel(h: *Task.Hook, t: *Task) void {
        const request: *RemoteAccept = @alignCast(@fieldParentPtr("hook", h)); // safe: embedded hook
        if (Scheduler.processor() != request.processor) return request.processor.pushCancel(t);
        request.requested = true;
        if (request.submitted) request.processor.loop.cancel(request.op);
    }
};

/// The descriptor an operation waits on in the kernel, which a close
/// elsewhere must end it on.
pub fn descriptorOf(kind: Loop.Op.Kind) ?Io.File.Handle {
    return switch (kind) {
        .io => |operation| switch (operation) {
            .file_read_streaming => |o| o.file.handle,
            .file_write_streaming => |o| o.file.handle,
            .device_io_control => |o| o.file.handle,
            .net_receive => |o| o.socket_handle,
            .net_send => |o| o.socket_handle,
            .net_read => |o| o.socket_handle,
            .net_write => |o| o.socket_handle,
        },
        .accept => |fd| fd,
        .connect => |c| c.socket,
        .read_at => |r| r.file,
        .write_at => |w| w.file,
        .sync => |fd| fd,
        .wait => |w| switch (w) {
            .readable, .writable, .priority => |fd| fd,
            .object => |h| if (builtin.os.tag == .windows) h else unreachable, // unreachable: only Windows has objects
        },
        .raw => |raw| switch (raw) {
            .uring => null,
            .windows => |request| if (builtin.os.tag == .windows) request.handle else unreachable, // unreachable: only Windows issues overlapped requests
        },
        .close, .abort, .timer => null,
    };
}

/// Whether a completed operation's result is the kernel's cancel.
fn canceledResult(o: *const Loop.Op) bool {
    if (!o.state.canceled) return false;
    return switch (o.kind) {
        .io => if (o.result.io) |_| false else |err| err == error.Canceled,
        .accept => if (o.result.accept) |_| false else |err| err == error.Canceled,
        .connect => if (o.result.connect) |_| false else |err| err == error.Canceled,
        .read_at => if (o.result.read_at) |_| false else |err| err == error.Canceled,
        .write_at => if (o.result.write_at) |_| false else |err| err == error.Canceled,
        .sync => if (o.result.sync) |_| false else |err| err == error.Canceled,
        .close, .abort => false,
        .timer => if (o.result.timer) |_| false else |err| err == error.Canceled,
        .wait => if (o.result.wait) |_| false else |err| err == error.Canceled,
        .raw => if (o.result.raw) |_| false else |err| err == error.Canceled,
    };
}

/// Sleeps until `at` on the running task's processor.
pub fn sleep(s: *Scheduler, at: Io.Clock.Timestamp) error{ Canceled, SystemResources }!void {
    var o: Loop.Op = .{ .kind = .{ .timer = at } };
    run(s, &o, .{}) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        error.SystemResources => error.SystemResources,
        error.Timeout => unreachable, // unreachable: no deadline given
    };
}

/// `timeout` as a deadline on `p`'s clocks; null for `.none`.
pub fn deadline(p: *Processor, timeout: Io.Timeout) ?Io.Clock.Timestamp {
    return switch (timeout) {
        .none => null,
        .duration => |d| .{ .clock = d.clock, .raw = p.loop.clock.now(d.clock).addDuration(d.raw) },
        .deadline => |d| d,
    };
}

/// From a thread outside the runtime: `o` runs on processor `p`, and the
/// thread waits for it on a kernel futex. Nothing cancels such a thread;
/// a deadline ends the operation as it does a task's.
pub fn runElsewhere(p: *Processor, o: *Loop.Op, at: ?Io.Clock.Timestamp) error{ Timeout, SystemResources }!void {
    var e: Elsewhere = .{ .op = o, .deadline = at };
    p.send(&e.errand);
    const system = Scheduler.system();
    while (e.done.load(.acquire) == 0) system.futexWaitUncancelable(u32, &e.done.raw, 0);
    if (e.failed) return error.SystemResources;
    if (e.timed_out and canceledResult(o)) return error.Timeout;
}

/// An operation a thread outside the runtime has a processor run, and its
/// deadline's timer; only that processor's thread touches it until `done`.
const Elsewhere = struct {
    errand: Scheduler.Errand = .{ .run = start },
    op: *Loop.Op,
    deadline: ?Io.Clock.Timestamp,
    timer: Loop.Op = .{ .kind = .{ .timer = undefined } },
    processor: *Processor = undefined,
    /// Completions still to come: the operation's, and its timer's.
    left: u8 = 1,
    timed_out: bool = false,
    failed: bool = false,
    done: std.atomic.Value(u32) = .init(0),

    fn start(errand: *Scheduler.Errand, p: *Processor) void {
        const e: *Elsewhere = @alignCast(@fieldParentPtr("errand", errand)); // safe: the field belongs to this record
        e.processor = p;
        const o = e.op;
        o.callback = finished;
        o.user_data = @intFromPtr(e); // safe: read back by `finished` while the thread waits
        const fd = descriptorOf(o.kind);
        if (fd) |d| p.hold(d);
        p.loop.submit(o) catch {
            if (fd) |d| p.release(d);
            e.failed = true;
            return e.signal();
        };
        const at = e.deadline orelse return;
        e.timer.kind = .{ .timer = at };
        e.timer.callback = expired;
        if (p.loop.submit(&e.timer)) |_| {
            e.left += 1;
        } else |_| {
            // No room for the timer: end the operation now.
            e.timed_out = true;
            p.loop.cancel(o);
        }
    }

    fn finished(l: *Loop, o: *Loop.Op) void {
        const e: *Elsewhere = @ptrFromInt(o.user_data); // safe: `start` stored it
        if (descriptorOf(o.kind)) |fd| e.processor.release(fd);
        // The timer still armed: its cancel completes it, now or later.
        if (e.left == 2) l.cancel(&e.timer);
        e.settle();
    }

    fn expired(l: *Loop, t: *Loop.Op) void {
        const e: *Elsewhere = @alignCast(@fieldParentPtr("timer", t)); // safe: the field belongs to this record
        if (t.result.timer) |_| {
            e.timed_out = true;
            l.cancel(e.op);
        } else |_| {}
        e.settle();
    }

    fn settle(e: *Elsewhere) void {
        e.left -= 1;
        if (e.left == 0) e.signal();
    }

    fn signal(e: *Elsewhere) void {
        e.done.store(1, .release);
        Scheduler.system().futexWake(u32, &e.done.raw, 1);
    }
};
