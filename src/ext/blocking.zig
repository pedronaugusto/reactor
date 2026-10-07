//! Calls that can take milliseconds, made where they hold up no worker.
const std = @import("std");
const Io = std.Io;

const Lanes = @import("../Lanes.zig");
const lane_call = @import("../ops/lane_call.zig");
const native = @import("native.zig");

fn Return(comptime F: type) type {
    return @typeInfo(F).@"fn".return_type.?;
}

/// Runs `function(args)` where it holds up no worker: on `lane` under a
/// runtime, the calling task parked meanwhile; on the calling thread under
/// any other `Io`, whose thread is the caller's own. The caller waits for
/// it either way. A cancel of the caller is forwarded to the lane's
/// `Io.Threaded`, which interrupts what std code the function runs there
/// by std's own mechanism; a call that finishes anyway keeps its result,
/// and the cancel stays pending for the caller's next cancelation point.
pub fn blocking(io: Io, lane: Lanes.Lane, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) Return(@TypeOf(function)) {
    const core = native.runtimeOf(io) orelse return @call(.auto, function, args);
    return lane_call.call(&core.scheduler, &core.lanes, lane, &function, args);
}
