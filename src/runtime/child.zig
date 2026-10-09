//! Native child readiness holds no lane thread: pidfd on Linux, an
//! EVFILT_PROC watch on kqueue systems, a process handle on Windows.
//! Once ready, std's own wait collects the status without blocking.
//! Systems without a watch use the wait lane.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Child = std.process.Child;

const Core = @import("Core.zig");
const Scheduler = @import("../Scheduler.zig");
const lane_call = @import("../ops/lane_call.zig");
const readiness = @import("../ops/readiness.zig");
const Loop = @import("../Loop.zig");
const perform = @import("../ops/perform.zig");
const process = @import("../sys/process.zig");

pub fn childWait(userdata: ?*anyopaque, child: *Child) Child.WaitError!Child.Term {
    const r = Core.running(userdata);
    if (r.backendKind() == null or Scheduler.processor() == null) return onLane(r, child);
    if (builtin.os.tag == .windows) {
        _ = readiness.first(&r.scheduler, &.{.{ .object = child.id.? }}, null) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return onLane(r, child),
        };
        return reap(r, child);
    }
    if (builtin.os.tag == .linux and Scheduler.processor().?.loop.backend == .io_uring and Scheduler.processor().?.loop.backend.io_uring.features.waitid) {
        const linux = std.os.linux;
        const Request = struct {
            const Self = @This();
            pid: linux.pid_t,
            info: linux.siginfo_t = std.mem.zeroes(linux.siginfo_t),
            fn prepare(context: *anyopaque, sqe: *linux.io_uring_sqe) void {
                const request: *Self = @ptrCast(@alignCast(context)); // safe: childWait retains request through completion
                sqe.prep_waitid(.PID, request.pid, &request.info, linux.W.EXITED | linux.W.NOWAIT, 0);
            }
        };
        var request: Request = .{ .pid = child.id.? };
        var op: Loop.Op = .{ .kind = .{ .raw = .{ .uring = .{ .context = &request, .prepare = Request.prepare } } } };
        perform.run(&r.scheduler, &op, .{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return onLane(r, child),
        };
        const result = op.result.raw catch return error.Canceled;
        if (result.uring == 0) return reap(r, child);
        // Opcode support does not guarantee support for every child type.
    }
    const watch = process.open(child.id.?) catch return onLane(r, child);
    defer process.close(watch, r.io());
    switch (watch) {
        .descriptor => |fd| _ = readiness.first(&r.scheduler, &.{.{ .readable = fd }}, null) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Timeout, error.SystemResources, error.Unsupported, error.Unexpected => return onLane(r, child),
        },
        .ended => {},
        .asking => return onLane(r, child),
    }
    // Ended: std's wait reaps it at once.
    return reap(r, child);
}

fn reap(r: *Core, child: *Child) Child.WaitError!Child.Term {
    const b = r.lanes.borrowedIo();
    return lane_call.borrow(b.vtable.childWait, .{ b.userdata, child });
}

fn onLane(r: *Core, child: *Child) Child.WaitError!Child.Term {
    const lane_io = r.lanes.executor(.wait);
    return lane_call.call(&r.scheduler, &r.lanes, .wait, lane_io.vtable.childWait, .{ lane_io.userdata, child });
}
