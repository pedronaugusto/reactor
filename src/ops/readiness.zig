//! A task waiting for the first of several descriptors to be ready, on its
//! own processor: each a `wait` operation of the processor's loop, all
//! ended together at the first that completes, at a deadline, or at a
//! cancel. The operations live in the task's frame, so every one is back
//! from the kernel before the wait returns; the task is held on its
//! processor meanwhile, where all of them complete.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const Loop = @import("../Loop.zig");
const Task = @import("../scheduler/Task.zig");
const Scheduler = @import("../Scheduler.zig");
const Processor = Scheduler.Processor;
const perform = @import("perform.zig");

/// The most members one wait takes.
pub const max = 64;

pub const Error = error{ Canceled, Timeout, SystemResources } || Loop.Waitable.Error;

const Waiter = struct {
    hook: Task.Hook = .{ .cancel = cancelHook },
    task: *Task,
    processor: *Processor,
    scheduler: *Scheduler,
    ops: []Loop.Op,
    /// Operations the loop still holds.
    outstanding: u32 = 0,
    /// The member that became ready first.
    first: ?usize = null,
    failure: ?Error = null,
    /// This task's cancel ended the wait.
    requested: bool = false,
    timed_out: bool = false,
    /// The cancels are sent.
    ending: bool = false,
    deadline: perform.Deadline = .{ .fire = expired },

    /// On the processor: asks the loop to end every operation still held.
    fn endAll(w: *Waiter) void {
        if (w.ending) return;
        w.ending = true;
        for (w.ops) |*o| w.processor.loop.cancel(o);
    }

    fn cancelHook(hook: *Task.Hook, t: *Task) void {
        const w: *Waiter = @alignCast(@fieldParentPtr("hook", hook)); // safe: the field belongs to this record
        if (Scheduler.processor() != w.processor) return w.processor.pushCancel(t);
        w.requested = true;
        w.endAll();
    }

    fn done(l: *Loop, o: *Loop.Op) void {
        _ = l;
        const w: *Waiter = @ptrFromInt(o.user_data); // safe: `first` stored the waiter's address
        const index = (@intFromPtr(o) - @intFromPtr(w.ops.ptr)) / @sizeOf(Loop.Op); // safe: `o` is an element of `w.ops`
        w.processor.release(handleOf(o.kind.wait));
        if (o.result.wait) |_| {
            if (w.first == null) w.first = index;
        } else |err| switch (err) {
            // Ended by this wait's own cancels, or, when nobody here asked,
            // by a close of the descriptor: a read or write now reports it.
            error.Canceled => if (!o.state.canceled and w.first == null) {
                w.first = index;
            },
            else => |e| if (w.failure == null) {
                w.failure = e;
            },
        }
        if (w.first != null or w.failure != null) w.endAll();
        w.outstanding -= 1;
        if (w.outstanding == 0) w.scheduler.ready(w.task, .completed);
    }

    fn expired(d: *perform.Deadline) void {
        const w: *Waiter = @alignCast(@fieldParentPtr("deadline", d)); // safe: the field belongs to this record
        w.timed_out = true;
        w.endAll();
    }
};

fn handleOf(w: Loop.Waitable) Io.File.Handle {
    return switch (w) {
        .readable, .writable => |h| h,
    };
}

/// The lowest-numbered member that became ready, waited for by the running
/// task until `deadline`. A member that completes in the same pass as an
/// earlier one is not reported: the earliest completion wins.
pub fn first(s: *Scheduler, members: []const Loop.Waitable, deadline: ?Io.Clock.Timestamp) Error!usize {
    assert(members.len > 0);
    assert(members.len <= max);
    const p = Scheduler.processor().?;
    const t = p.current.?;
    var ops: [max]Loop.Op = undefined;
    var w: Waiter = .{ .task = t, .processor = p, .scheduler = s, .ops = ops[0..members.len] };
    try t.enterWait(&w.hook);
    // Every completion comes back to this processor, which resumes the task.
    t.pins += 1;
    for (members, w.ops, 0..) |m, *o, i| {
        o.* = .{ .kind = .{ .wait = m }, .callback = Waiter.done, .user_data = @intFromPtr(&w) }; // safe: read back by the callback while this frame waits
        p.hold(handleOf(m));
        p.loop.submit(o) catch {
            p.release(handleOf(m));
            w.failure = error.SystemResources;
            w.ops = w.ops[0..i];
            break;
        };
        w.outstanding += 1;
    }
    if (w.outstanding > 0) {
        if (w.failure != null) {
            w.endAll();
        } else if (deadline) |at| if (!w.deadline.arm(s, at)) {
            // No room for a timer: as if it had passed.
            w.timed_out = true;
            w.endAll();
        };
        Scheduler.park(null);
    }
    w.deadline.disarm();
    t.pins -= 1;
    t.leaveWait();
    if (w.first) |i| return i;
    if (w.failure) |e| return e;
    if (w.requested) return t.acknowledge();
    assert(w.timed_out);
    return error.Timeout;
}
