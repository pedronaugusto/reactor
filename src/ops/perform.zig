//! A task waiting on one loop operation: submitted on the processor the
//! task runs on, completed there, and cancelled there. A cancel from
//! another thread becomes a message to that processor, which asks its own
//! kernel queue; the operation's completion still decides the outcome, so
//! an operation that finished first keeps its result. A deadline is a
//! timer on the same processor that asks the kernel to end the operation
//! the same way.
const std = @import("std");
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
    timer: Loop.Op = .{ .kind = .{ .timer = undefined } },

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
        w.scheduler.ready(w.task, .completed);
    }

    fn expired(l: *Loop, o: *Loop.Op) void {
        const w: *Waiter = @alignCast(@fieldParentPtr("timer", o)); // safe: the field belongs to this record
        if (o.result.timer) |_| {} else |_| return; // disarmed: the operation completed
        w.timed_out = true;
        l.cancel(w.o);
    }
};

/// Runs `o` for the running task and waits for its completion. Returns
/// `Canceled` only when this task's cancel ended it, `Timeout` only when
/// the deadline did; `o.result` holds the result otherwise.
pub fn run(s: *Scheduler, o: *Loop.Op, options: Options) Error!void {
    const p = Scheduler.processor().?;
    const t = p.current.?;
    var w: Waiter = .{ .task = t, .processor = p, .scheduler = s, .o = o };
    o.callback = Waiter.done;
    o.user_data = @intFromPtr(&w); // safe: read back by the callback while this frame waits
    if (options.cancelable) try t.enterWait(&w.hook);
    p.loop.submit(o) catch {
        t.leaveWait();
        return error.SystemResources;
    };
    var timed = false;
    if (options.deadline) |at| {
        w.timer.kind = .{ .timer = at };
        w.timer.callback = Waiter.expired;
        if (p.loop.submit(&w.timer)) |_| {
            timed = true;
        } else |_| {
            // No room for the timer: end the operation now.
            w.timed_out = true;
            p.loop.cancel(o);
        }
    }
    Scheduler.park(null);
    if (timed) p.loop.cancel(&w.timer);
    t.leaveWait();
    if (!canceledResult(o)) return;
    if (w.requested) return t.acknowledge();
    if (w.timed_out) return error.Timeout;
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
        .close => false,
        .timer => if (o.result.timer) |_| false else |err| err == error.Canceled,
        .wait => if (o.result.wait) |_| false else |err| err == error.Canceled,
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
