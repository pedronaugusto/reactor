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

const Ordered = struct {
    job: Lanes.Job = .{ .lane = .general, .run = run, .done = done },
    begun: ?*Io.Event = null,
    gate: ?*Io.Event = null,
    order: *[11]u8,
    used: *usize,
    value: u8 = 0,
    finished: Io.Event = .unset,
    fn run(job: *Lanes.Job) void {
        const self: *Ordered = @alignCast(@fieldParentPtr("job", job)); // safe: the test retains every job until its group ends
        if (self.begun) |event| event.set(testing.io);
        if (self.gate) |event| event.waitUncancelable(testing.io) else {
            self.order[self.used.*] = self.value;
            self.used.* += 1;
        }
    }
    fn done(job: *Lanes.Job) void {
        const self: *Ordered = @alignCast(@fieldParentPtr("job", job)); // safe: same retained embedded job
        self.finished.set(testing.io);
    }
};
test "disk lane latency jobs pass queued normal jobs without starving them" {
    var lanes: Lanes = undefined;
    try lanes.init(testing.allocator, .{ .owned = .{ .general = 1 } }, .{});
    defer lanes.deinit(testing.allocator);
    var begun: Io.Event = .unset;
    var gate: Io.Event = .unset;
    var order: [11]u8 = undefined;
    var used: usize = 0;
    var blocker: Ordered = .{ .order = &order, .used = &used, .begun = &begun, .gate = &gate };
    lanes.submit(&blocker.job);
    try begun.wait(testing.io);
    defer gate.set(testing.io);
    var jobs: [11]Ordered = undefined;
    for (&jobs, 0..) |*job, at| {
        job.* = .{ .order = &order, .used = &used, .value = if (at == 0) 0 else 1 };
        if (at != 0) job.job.priority = .latency;
        lanes.submit(&job.job);
    }
    try testing.expectEqual(@as(u32, 11), lanes.stats(.general).queued);
    gate.set(testing.io);
    for (&jobs) |*job| {
        try job.finished.wait(testing.io);
        try job.job.group.await(lanes.executor(.general));
    }
    try blocker.job.group.await(lanes.executor(.general));
    try testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1 }, &order);
    try testing.expectEqual(@as(u64, 0), lanes.stats(.general).@"inline");
}
