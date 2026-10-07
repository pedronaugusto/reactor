//! `childWait` without a lane on Linux: the task waits for the child's
//! pidfd to be readable on its own loop, a cancelation point that holds no
//! thread, then std's own wait collects the status, which no longer
//! blocks. Elsewhere, and where the kernel has no pidfd, on the `wait`
//! lane.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Child = std.process.Child;

const Core = @import("Core.zig");
const Scheduler = @import("../Scheduler.zig");
const lane_call = @import("../ops/lane_call.zig");
const readiness = @import("../ops/readiness.zig");
const process = @import("../sys/process.zig");

pub fn childWait(userdata: ?*anyopaque, child: *Child) Child.WaitError!Child.Term {
    const r = Core.of(userdata);
    if (builtin.os.tag != .linux or r.backendKind() == null or Scheduler.processor() == null) return onLane(r, child);
    const watch = process.open(child.id.?) catch return onLane(r, child);
    defer process.close(watch);
    switch (watch) {
        .descriptor => |fd| _ = readiness.first(&r.scheduler, &.{.{ .readable = fd }}, null) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Timeout, error.SystemResources, error.Unsupported, error.Unexpected => return onLane(r, child),
        },
        .ended => {},
        .asking => return onLane(r, child),
    }
    // Ended: std's wait reaps it at once.
    const b = r.lanes.borrowedIo();
    return lane_call.borrow(b.vtable.childWait, .{ b.userdata, child });
}

fn onLane(r: *Core, child: *Child) Child.WaitError!Child.Term {
    const lane_io = r.lanes.executor(.wait);
    return lane_call.call(&r.scheduler, &r.lanes, .wait, lane_io.vtable.childWait, .{ lane_io.userdata, child });
}
