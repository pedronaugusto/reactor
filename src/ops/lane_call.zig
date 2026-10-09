//! Running a call where it holds up no worker: on a lane, the task parked
//! meanwhile; inline when the runtime has no lanes or the caller is a
//! thread outside the runtime; on the worker inside a blocking bracket,
//! which the monitor can rescue by handing on the processor; or "borrowed": std's code run on the worker
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

pub const OffloadError = error{ Canceled, ConcurrencyUnavailable };

pub fn Result(comptime F: type) type {
    const R = ReturnOf(F);
    return switch (@typeInfo(R)) {
        .error_union => |eu| (eu.error_set || OffloadError)!eu.payload,
        else => OffloadError!R,
    };
}

/// Fixed std.Io slots keep their specified result and cancellation shape.
pub fn call(s: *Scheduler, lanes: *Lanes, lane: Lanes.Lane, func: anytype, args: anytype) ReturnOf(@TypeOf(func)) {
    return perform(ReturnOf(@TypeOf(func)), false, s, lanes, lane, func, args);
}

/// A refused raw call never ran; all result shapes report the refusal.
pub fn fallible(s: *Scheduler, lanes: *Lanes, lane: Lanes.Lane, func: anytype, args: anytype) Result(@TypeOf(func)) {
    const owner = if (Scheduler.processor()) |p| p.scheduler else s;
    if (Scheduler.current() == null and !lanes.inlined()) return fromThread(lanes, lane, func, args);
    return perform(Result(@TypeOf(func)), true, owner, lanes, lane, func, args);
}

/// A caller outside the fiber scheduler still submits raw work to its lane.
/// Its stack remains pinned through completion and executor group retirement.
fn fromThread(lanes: *Lanes, lane: Lanes.Lane, func: anytype, args: anytype) Result(@TypeOf(func)) {
    const Call = struct {
        const Self = @This();
        job: Lanes.Job,
        func: @TypeOf(func),
        args: @TypeOf(args),
        result: Result(@TypeOf(func)) = undefined,
        finished: Io.Event = .unset,

        fn run(job: *Lanes.Job) void {
            const c: *Self = @alignCast(@fieldParentPtr("job", job)); // safe: the waiting caller owns the record
            c.result = @call(.auto, c.func, c.args);
        }
        fn done(job: *Lanes.Job) void {
            const c: *Self = @alignCast(@fieldParentPtr("job", job)); // safe: the caller retains it through executor retirement
            c.finished.set(Scheduler.system());
        }
    };
    var c: Call = .{
        .job = .{ .run = Call.run, .done = Call.done, .lane = lane },
        .func = func,
        .args = args,
    };
    lanes.submit(&c.job);
    c.finished.waitUncancelable(Scheduler.system());
    // Completion precedes the executor releasing its group token. No
    // cancelable wait may abandon the caller's frame in this interval.
    while (c.job.held()) std.Thread.yield() catch std.atomic.spinLoopHint();
    if (c.job.rejected) return error.ConcurrencyUnavailable;
    return c.result;
}

fn perform(comptime R: type, comptime raw: bool, s: *Scheduler, lanes: *Lanes, lane: Lanes.Lane, func: anytype, args: anytype) R {
    const t = Scheduler.current() orelse return direct(lanes, lane, func, args);
    if (lanes.inlined()) return direct(lanes, lane, func, args);
    const previous_lane = t.lane;
    t.lane = lane;
    defer t.lane = previous_lane;
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
        .job = .{ .run = Call.run, .done = Call.done, .lane = lane, .priority = t.policy.priority },
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
    if (c.job.rejected) {
        if (comptime raw) return error.ConcurrencyUnavailable;
        return unavailable(R);
    }
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

/// std's code run on the calling worker, inside a blocking call's bracket:
/// should it block, the monitor hands the worker's processor to a spare
/// thread and the task goes on wherever it lands. For calls that may block
/// on a disk but never call back into their own `Io`. Null when no bracket
/// can be had here (no handoff, the home processor): nothing ran.
pub fn onWorker(func: anytype, args: anytype) ?ReturnOf(@TypeOf(func)) {
    const R = ReturnOf(@TypeOf(func));
    // Once the bracket is published, a spare may own the processor. Read
    // the task's cancel state first, then call std without touching it.
    if (comptime cancelable(R)) {
        if (Scheduler.current()) |t| if (t.takeCancel()) return @as(R, error.Canceled);
    }
    var b = Scheduler.enterBlocking() orelse return null;
    const result = @call(.auto, func, args);
    Scheduler.leaveBlocking(&b);
    return result;
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

/// A void or narrow result cannot invent a successful result for a call
/// that never ran. Resource failures are explicit, including injected
/// executors that violate their ability to accept cancellation jobs.
fn unavailable(comptime R: type) R {
    if (comptime @typeInfo(R) == .error_union) {
        const names = @typeInfo(@typeInfo(R).error_union.error_set).error_set.error_names orelse return error.SystemResources;
        inline for (names) |name| {
            if (comptime std.mem.eql(u8, name, "SystemResources")) return error.SystemResources;
        }
        inline for (names) |name| {
            if (comptime std.mem.eql(u8, name, "Unexpected")) return error.Unexpected;
            if (comptime std.mem.eql(u8, name, "ConcurrencyUnavailable")) return error.ConcurrencyUnavailable;
        }
    }
    @panic("reactor: lane executor refused a call whose result cannot report resource exhaustion");
}
