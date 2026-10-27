//! Calls that can take milliseconds, made where they hold up no worker.
const std = @import("std");
const Io = std.Io;

const Lanes = @import("../Lanes.zig");
const lane_call = @import("../ops/lane_call.zig");
const native = @import("native.zig");

pub const Error = lane_call.OffloadError;

fn Return(comptime F: type) type {
    return lane_call.Result(*const F);
}

/// Runs `function(args)` where it holds up no worker: on `lane` under a
/// runtime, the calling task parked meanwhile; on the calling thread under
/// any other `Io`, whose thread is the caller's own. The caller waits for
/// it either way. A cancel of the caller is forwarded to the lane's
/// `Io.Threaded`, which interrupts what std code the function runs there
/// by std's own mechanism; a call that finishes anyway keeps its result,
/// and the cancel stays pending for the caller's next cancelation point.
/// Every result adds Canceled and ConcurrencyUnavailable, including void.
/// Refusal never invokes the function or falls back to the caller.
pub fn blocking(io: Io, lane: Lanes.Lane, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) Return(@TypeOf(function)) {
    const core = native.runtimeOf(io) orelse return @call(.auto, function, args);
    const entered = native.enter();
    defer native.leave(entered);
    return lane_call.fallible(&core.lanes, lane, &function, args);
}

/// The executor a library that keeps its own syscalls takes for its raw
/// blocking calls (airlock's `Blocking`, for its device flushes): runs
/// `job.execute()` on the runtime's `sync` lane, the calling task parked
/// meanwhile; on the calling thread under any other `Io`. `job` points to
/// whatever the library calls a job, anything with `execute()`. It waits for
/// a lane slot as a `std.Io` slot does and never refuses. `Canceled` only
/// when the call never started; a call that started finishes and succeeds,
/// its cancel left pending for the caller's next cancelation point, so a
/// completed sync's error is never hidden. `job` is borrowed for the call
/// alone, and its `execute` makes no `Io` call.
pub fn syncLane(io: Io, job: anytype) Io.Cancelable!void {
    const core = native.runtimeOf(io) orelse {
        try io.checkCancel();
        return job.execute();
    };
    const entered = native.enter();
    defer native.leave(entered);
    return lane_call.call(&core.lanes, .sync, &Raw(@TypeOf(job)).run, .{job});
}

/// A `Blocking` of the library whose type it is, running every job through
/// `syncLane`: one shaped as airlock's, its `run` taking the `Blocking`, the
/// `Io` and a `*Blocking.Job`. It holds no state, so one value serves every
/// caller.
pub fn syncLaneFor(comptime Blocking: type) Blocking {
    return .{ .run = struct {
        fn run(_: *Blocking, io: Io, job: *Blocking.Job) Io.Cancelable!void {
            return syncLane(io, job);
        }
    }.run };
}

fn Raw(comptime Job: type) type {
    return struct {
        fn run(job: Job) Io.Cancelable!void {
            job.execute();
        }
    };
}
