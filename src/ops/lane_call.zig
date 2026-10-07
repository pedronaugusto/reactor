//! Running a call where it holds up no worker: on a lane, the task parked
//! meanwhile; inline when the runtime has no lanes or the caller is a
//! thread outside the runtime; or "borrowed": std's code run on the worker
//! itself, for calls that never block.
const std = @import("std");
const Io = std.Io;

const Task = @import("../scheduler/Task.zig");
const Scheduler = @import("../Scheduler.zig");
const Lanes = @import("../Lanes.zig");

fn ReturnOf(comptime F: type) type {
    return @typeInfo(@typeInfo(F).pointer.child).@"fn".return_type.?;
}

/// Whether a result type can carry `error.Canceled`.
pub fn cancelable(comptime R: type) bool {
    return switch (@typeInfo(R)) {
        .error_union => |eu| for (@typeInfo(eu.error_set).error_set.error_names orelse return true) |name| {
            if (std.mem.eql(u8, name, "Canceled")) break true;
        } else false,
        else => false,
    };
}

fn isCanceled(comptime R: type, result: R) bool {
    if (comptime !cancelable(R)) return false;
    if (result) |_| return false else |err| return err == error.Canceled;
}

/// Calls `func(args)` on `lane` and waits for it.
pub fn call(s: *Scheduler, lanes: *Lanes, lane: Lanes.Lane, func: anytype, args: anytype) ReturnOf(@TypeOf(func)) {
    const R = ReturnOf(@TypeOf(func));
    const t = Scheduler.current() orelse return direct(lanes, lane, func, args);
    if (lanes.inlined()) return direct(lanes, lane, func, args);
    const Call = struct {
        const Self = @This();

        job: Lanes.Job,
        func: @TypeOf(func),
        args: @TypeOf(args),
        result: R = undefined,
        task: *Task,
        scheduler: *Scheduler,
        lanes: *Lanes,
        hook: Task.Hook = .{ .cancel = cancelHook },

        fn run(job: *Lanes.Job) void {
            const c: *Self = @alignCast(@fieldParentPtr("job", job)); // safe: the field belongs to this record
            c.result = @call(.auto, c.func, c.args);
        }

        fn done(job: *Lanes.Job) void {
            const c: *Self = @alignCast(@fieldParentPtr("job", job)); // safe: the field belongs to this record
            c.scheduler.ready(c.task, .completed);
        }

        fn cancelHook(hook: *Task.Hook, task: *Task) void {
            _ = task;
            const c: *Self = @alignCast(@fieldParentPtr("hook", hook)); // safe: the field belongs to this record
            c.lanes.cancel(&c.job);
        }

        /// Off the task's stack: hand the call to the lane.
        fn submit(context: *anyopaque, task: *Task) void {
            _ = task;
            const c: *Self = @ptrCast(@alignCast(context)); // safe: `call` passed its `Call`
            c.lanes.submit(&c.job);
        }
    };
    var c: Call = .{
        .job = .{ .run = Call.run, .done = Call.done, .lane = lane },
        .func = func,
        .args = args,
        .task = t,
        .scheduler = s,
        .lanes = lanes,
    };
    if (comptime cancelable(R)) t.enterWait(&c.hook) catch return error.Canceled;
    Scheduler.park(.{ .func = Call.submit, .context = &c });
    t.leaveWait();
    // The executor lets go of the job's group just after the call returns.
    while (c.job.held()) Scheduler.yield();
    if (comptime cancelable(R)) {
        if (c.job.dropped) return t.acknowledge();
        if (isCanceled(R, c.result)) t.acknowledged();
    }
    return c.result;
}

fn direct(lanes: *Lanes, lane: Lanes.Lane, func: anytype, args: anytype) ReturnOf(@TypeOf(func)) {
    lanes.countInline(lane);
    return @call(.auto, func, args);
}

/// std's code run on the calling worker: for calls that never block and
/// never call back into their own `Io`. A cancelation point at entry.
pub fn borrow(func: anytype, args: anytype) ReturnOf(@TypeOf(func)) {
    const R = ReturnOf(@TypeOf(func));
    if (comptime cancelable(R)) {
        if (Scheduler.current()) |t| if (t.takeCancel()) return error.Canceled;
    }
    return @call(.auto, func, args);
}
