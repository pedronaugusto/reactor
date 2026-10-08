const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const shakedown = @import("shakedown");
const Lanes = @import("Lanes.zig");

const Rejecting = shakedown.Layer(u8, .{ .groupConcurrent = struct {
    fn reject(_: ?*anyopaque, _: *Io.Group, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque) void) Io.ConcurrentError!void {
        return error.ConcurrencyUnavailable;
    }
}.reject });

const Observed = struct {
    job: Lanes.Job = .{ .lane = .general, .run = run, .done = done },
    ran: bool = false,
    finished: bool = false,
    fn run(job: *Lanes.Job) void {
        const observed: *Observed = @alignCast(@fieldParentPtr("job", job)); // safe: this test owns the embedded job
        observed.ran = true;
    }
    fn done(job: *Lanes.Job) void {
        const observed: *Observed = @alignCast(@fieldParentPtr("job", job)); // safe: this test owns the embedded job
        observed.finished = true;
    }
};

test "executor rejection finishes without running a lane call inline" {
    var executor: Rejecting = .init(testing.io, 0);
    var lanes: Lanes = undefined;
    try lanes.init(testing.allocator, .{ .injected = executor.io() }, .{});
    defer lanes.deinit(testing.allocator);
    var observed: Observed = .{};
    lanes.submit(&observed.job);
    try testing.expect(observed.finished);
    try testing.expect(!observed.ran);
    try testing.expectEqual(@as(u64, 0), lanes.stats(.general).@"inline");
    try testing.expectEqual(@as(u32, 0), lanes.stats(.general).running);
}

test "a disabled owned lane refuses instead of queueing forever" {
    var lanes: Lanes = undefined;
    try lanes.init(testing.allocator, .{ .owned = .{ .general = 0 } }, .{});
    defer lanes.deinit(testing.allocator);
    var observed: Observed = .{};
    lanes.submit(&observed.job);
    try testing.expect(observed.finished);
    try testing.expect(!observed.ran);
    try testing.expectEqual(@as(u32, 0), lanes.stats(.general).queued);
}
