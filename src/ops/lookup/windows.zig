//! The extended Windows resolver through an overlapped event: on a
//! runtime its wait packet goes to the task's completion port.
const std = @import("std");
const Io = std.Io;
const lookup = @import("../../sys/lookup_windows.zig");
const win32 = @import("../../sys/win32.zig");
const Scheduler = @import("../../Scheduler.zig");
const Loop = @import("../../Loop.zig");
const perform = @import("../perform.zig");

pub const Error = lookup.Error || Io.Cancelable;

pub fn resolve(io: Io, name: []const u8, port: u16, family: ?Io.net.IpAddress.Family, out: []Io.net.IpAddress, canonical_buffer: ?*[254]u8) Error!lookup.Result {
    var request: lookup.Request = .{};
    defer request.deinit();
    try request.start(name, port, family);
    var canceled = false;
    if (request.pending) {
        if (Scheduler.processor()) |p| {
            var op: Loop.Op = .{ .kind = .{ .wait = .{ .object = request.overlapped.event.? } } };
            perform.run(p.scheduler, &op, .{}) catch |err| {
                request.cancel();
                canceled = err == error.Canceled;
                // Canceling the wait packet does not release Winsock's request.
                // Reap its event on the port before the stack frame can leave.
                var drain: Loop.Op = .{ .kind = .{ .wait = .{ .object = request.overlapped.event.? } } };
                perform.run(p.scheduler, &drain, .{ .cancelable = false }) catch return error.Unexpected;
                drain.result.wait catch return error.Unexpected;
            };
            if (!canceled) op.result.wait catch return error.Unexpected;
        } else {
            while (win32.WaitForSingleObject(request.overlapped.event.?, 0) == win32.wait_timeout) {
                io.sleep(.fromMilliseconds(1), .awake) catch {
                    request.cancel();
                    canceled = true;
                    const protection = io.swapCancelProtection(.blocked);
                    defer _ = io.swapCancelProtection(protection);
                    while (win32.WaitForSingleObject(request.overlapped.event.?, 0) == win32.wait_timeout) io.sleep(.fromMilliseconds(1), .awake) catch unreachable; // unreachable: cancellation is protected
                    break;
                };
            }
        }
    }
    const result = request.finish(out, canonical_buffer) catch |err| return if (canceled) error.Canceled else err;
    if (canceled) io.recancel();
    return result;
}
