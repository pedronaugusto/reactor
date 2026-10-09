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
    try lanes.init(testing.allocator, .{ .injected = .{ .io = executor.io(), .capacity = 128 } }, .{});
    defer lanes.deinit(testing.allocator);
    if (lanes.mode == .injected) try lanes.prepare();
    var observed: Observed = .{};
    lanes.submit(&observed.job);
    try testing.expect(observed.finished);
    try testing.expect(!observed.ran);
    try testing.expectEqual(@as(u64, 0), lanes.stats(.general).@"inline");
    lanes.retire(&observed.job);
    try testing.expectEqual(@as(u32, 0), lanes.stats(.general).running);
}

test "a disabled owned lane refuses instead of queueing forever" {
    var lanes: Lanes = undefined;
    try lanes.init(testing.allocator, .{ .owned = .{ .general = 0 } }, .{});
    defer lanes.deinit(testing.allocator);
    if (lanes.mode == .injected) try lanes.prepare();
    var observed: Observed = .{};
    lanes.submit(&observed.job);
    try testing.expect(observed.finished);
    try testing.expect(!observed.ran);
    lanes.retire(&observed.job);
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
    try lanes.prepare();
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
    try blocker.job.group.await(lanes.executor(.general));
    lanes.retire(&blocker.job);
    for (&jobs) |*job| {
        try job.finished.wait(testing.io);
        try job.job.group.await(lanes.executor(.general));
        lanes.retire(&job.job);
    }
    try blocker.job.group.await(lanes.executor(.general));
    try testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1 }, &order);
    try testing.expectEqual(@as(u64, 0), lanes.stats(.general).@"inline");
}

test "admission: startup refuses disabled owned lanes before fixed operations" {
    const Driver = @import("testing/Driver.zig");
    var driver: Driver = undefined;
    try driver.initUnstarted(testing.allocator, 19, .{
        .max_tasks = 4,
        .offload = .{ .owned = .{ .sync = 0, .lookup = 0, .wait = 0, .general = 0 } },
    });
    defer driver.deinit();
    for (&driver.runtime.core.lanes.threaded) |*threaded| try testing.expectEqual(@as(usize, 0), @as(usize, @intFromBool(threaded.worker_threads.load(.acquire) != null)));
    try testing.expectError(error.SystemResources, driver.runtime.start());
    try testing.expect(!driver.runtime.core.started.load(.acquire));
}

const Retained = struct {
    bytes: [256]u8 align(16) = undefined,
    run: *const fn (*const anyopaque) void = undefined,
    fn complete(state: *Retained) void {
        state.run(&state.bytes);
    }
};
const Retaining = shakedown.Layer(Retained, .{
    .groupConcurrent = struct {
        fn submit(userdata: ?*anyopaque, group: *Io.Group, context: []const u8, _: std.mem.Alignment, run_: *const fn (*const anyopaque) void) Io.ConcurrentError!void {
            // The test executor retains its group after the callback returns.
            group.token.store(group, .release);
            const state: *Retained = @ptrCast(@alignCast(userdata.?)); // safe: the layer passes its retained fake state
            @memcpy(state.bytes[0..context.len], context);
            state.run = run_;
        }
    }.submit,
});

test "admission: retiring groups hold capacity and full admission never runs inline" {
    var executor: Retaining = .init(testing.io, .{});
    var lanes: Lanes = undefined;
    try lanes.init(testing.allocator, .{ .injected = .{ .io = executor.io(), .capacity = 4 } }, .{});
    defer lanes.deinit(testing.allocator);
    try lanes.prepare();
    var first: Observed = .{};
    lanes.submit(&first.job);
    executor.state.complete();
    try testing.expect(first.ran and first.finished and first.job.held());
    var refused: Observed = .{};
    lanes.submit(&refused.job);
    try testing.expect(refused.finished and refused.job.rejected and !refused.ran);
    lanes.retire(&refused.job);
    var termination: Observed = .{};
    termination.job.control = true;
    lanes.submit(&termination.job);
    executor.state.complete();
    try testing.expect(termination.ran and !termination.job.rejected);
    termination.job.group.token.store(null, .release);
    lanes.retire(&termination.job);
    first.job.group.token.store(null, .release);
    // Control retirement independently keeps the reservation held.
    first.job.cancellation.token.store(&first, .release);
    try testing.expect(first.job.held());
    var still_full: Observed = .{};
    lanes.submit(&still_full.job);
    try testing.expect(still_full.job.rejected and !still_full.ran);
    lanes.retire(&still_full.job);
    first.job.cancellation.token.store(null, .release);
    lanes.retire(&first.job);
    var accepted: Observed = .{};
    lanes.submit(&accepted.job);
    executor.state.complete();
    try testing.expect(accepted.ran and !accepted.job.rejected);
    accepted.job.group.token.store(null, .release);
    lanes.retire(&accepted.job);
    try testing.expectEqual(@as(u64, 0), lanes.stats(.general).@"inline");
    try testing.expectEqual(@as(u32, 0), lanes.reserved);
}
