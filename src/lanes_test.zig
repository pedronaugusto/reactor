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
    try testing.expect(refused.finished and refused.job.rejected and !refused.job.short and !refused.ran);
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
    try testing.expectEqual(@as(u32, 0), lanes.charged());
}

fn workerCount(threaded: *Io.Threaded) usize {
    var next = threaded.worker_threads.load(.acquire);
    var count_: usize = 0;
    while (next) |thread| {
        count_ += 1;
        next = thread.next;
    }
    return count_;
}
const Prepared = struct {
    job: Lanes.Job = .{ .lane = .general, .run = run, .done = done },
    finished: Io.Event = .unset,
    fn run(_: *Lanes.Job) void {}
    fn done(job: *Lanes.Job) void {
        const call: *Prepared = @alignCast(@fieldParentPtr("job", job)); // safe: the test retains this frame through retirement
        call.finished.set(testing.io);
    }
};
test "admission: owned lanes start no thread until a call needs one, then keep what they made" {
    var lanes: Lanes = undefined;
    try lanes.init(testing.allocator, .{ .owned = .{ .sync = 1, .lookup = 1, .wait = 1, .general = 1 } }, .{});
    defer lanes.deinit(testing.allocator);
    try lanes.prepare();
    for (&lanes.threaded) |*threaded| try testing.expectEqual(@as(usize, 0), workerCount(threaded));
    for (0..32) |_| {
        var call: Prepared = .{};
        lanes.submit(&call.job);
        call.finished.waitUncancelable(testing.io);
        while (call.job.held()) std.Thread.yield() catch std.atomic.spinLoopHint();
        lanes.retire(&call.job);
    }
    // One call at a time: its thread, one for a cancel of it, three more;
    // made once and reused.
    try testing.expectEqual(@as(u32, 5), lanes.stats(.general).threads);
    try testing.expect(workerCount(&lanes.threaded[@backingInt(Lanes.Lane.general)]) <= 5);
    for ([_]Lanes.Lane{ .sync, .lookup, .wait }) |lane| {
        try testing.expectEqual(@as(u32, 0), lanes.stats(lane).threads);
        try testing.expectEqual(@as(usize, 0), workerCount(&lanes.threaded[@backingInt(lane)]));
    }
    try testing.expectEqual(@as(u32, 0), lanes.charged());
}

test "admission: an owned lane grows two threads for each call it runs at once, up to its cap" {
    var lanes: Lanes = undefined;
    try lanes.init(testing.allocator, .{ .owned = .{ .general = 3 } }, .{});
    defer lanes.deinit(testing.allocator);
    try lanes.prepare();
    var order: [11]u8 = undefined;
    var used: usize = 0;
    var gate: Io.Event = .unset;
    var begun: [4]Io.Event = @splat(.unset);
    var jobs: [4]Ordered = undefined;
    for (&jobs, &begun) |*job, *b| job.* = .{ .order = &order, .used = &used, .begun = b, .gate = &gate };
    for (jobs[0..3], begun[0..3], 1..) |*job, *b, running| {
        lanes.submit(&job.job);
        try b.wait(testing.io);
        try testing.expectEqual(@as(u32, @intCast(2 * running + 3)), lanes.stats(.general).threads);
    }
    // Past the cap the call queues, and the lane grows no further.
    lanes.submit(&jobs[3].job);
    try testing.expectEqual(@as(u32, 1), lanes.stats(.general).queued);
    try testing.expectEqual(@as(u32, 9), lanes.stats(.general).threads);
    // A cancel of a running call takes a thread the lane already holds.
    lanes.cancel(&jobs[0].job);
    gate.set(testing.io);
    for (&jobs) |*job| {
        try job.finished.wait(testing.io);
        try job.job.group.await(lanes.executor(.general));
        try job.job.cancellation.await(lanes.executor(.general));
        lanes.retire(&job.job);
    }
    try testing.expectEqual(@as(u32, 9), lanes.stats(.general).threads);
    try testing.expect(workerCount(&lanes.threaded[@backingInt(Lanes.Lane.general)]) <= 9);
}

test "admission: a lane that cannot make threads queues behind its running calls, and refuses when it runs none" {
    var lanes: Lanes = undefined;
    try lanes.init(testing.allocator, .{ .owned = .{ .general = 2 } }, .{});
    defer lanes.deinit(testing.allocator);
    try lanes.prepare();
    const executor = &lanes.threaded[@backingInt(Lanes.Lane.general)];
    // The executor refuses past six jobs: the first call's five threads
    // can be made, a second running call's seven cannot.
    executor.concurrent_limit = .limited(6);
    var order: [11]u8 = undefined;
    var used: usize = 0;
    var gate: Io.Event = .unset;
    var begun: Io.Event = .unset;
    var first: Ordered = .{ .order = &order, .used = &used, .begun = &begun, .gate = &gate };
    lanes.submit(&first.job);
    try begun.wait(testing.io);
    var second: Ordered = .{ .order = &order, .used = &used, .value = 2 };
    lanes.submit(&second.job);
    // Queued behind the first, which holds its threads, not refused.
    try testing.expectEqual(@as(u32, 1), lanes.stats(.general).queued);
    try testing.expect(!second.job.rejected);
    gate.set(testing.io);
    for ([_]*Ordered{ &first, &second }) |job| {
        try job.finished.wait(testing.io);
        try job.job.group.await(lanes.executor(.general));
        lanes.retire(&job.job);
    }
    try testing.expect(!second.job.rejected and used == 1 and order[0] == 2);
    // A lane running nothing that can make no thread refuses the call, which
    // never runs: a raw call's `ConcurrencyUnavailable`.
    var other: Lanes = undefined;
    try other.init(testing.allocator, .{ .owned = .{ .general = 2 } }, .{});
    defer other.deinit(testing.allocator);
    try other.prepare();
    other.threaded[@backingInt(Lanes.Lane.general)].concurrent_limit = .nothing;
    var refused: Observed = .{};
    other.submit(&refused.job);
    try testing.expect(refused.finished and refused.job.rejected and refused.job.short and !refused.ran);
    other.retire(&refused.job);
    try testing.expectEqual(@as(u32, 0), other.charged());
}

/// A task of the test's own on a lane's executor, kept busy until let go:
/// a thread of that executor no reserve job ever ran on.
const Outsider = struct {
    gate: Io.Event = .unset,
    begun: Io.Event = .unset,
    group: Io.Group = .init,

    fn occupy(o: *Outsider, executor: Io) !void {
        try executor.vtable.groupConcurrent(executor.userdata, &o.group, std.mem.asBytes(&o), .of(*Outsider), run);
        try o.begun.wait(testing.io);
    }

    fn run(context: *const anyopaque) void {
        const o: *const *Outsider = @ptrCast(@alignCast(context)); // safe: `occupy` passed a pointer to itself
        o.*.begun.set(testing.io);
        o.*.gate.waitUncancelable(testing.io);
    }
};

test "a lane counts every thread its executor made, whatever ran on it first, so a call never waits for one it cannot see" {
    var lanes: Lanes = undefined;
    try lanes.init(testing.allocator, .{ .owned = .{ .sync = 1 } }, .{});
    defer lanes.deinit(testing.allocator);
    try lanes.prepare();
    const executor = &lanes.threaded[@backingInt(Lanes.Lane.sync)];
    // A thread of the executor the lane did not make for a reserve job, as
    // when a busy thread takes a reserve job a new thread was made for. Up
    // to 0.8.3 the lane counted only threads a reserve job found new: here
    // it made its five beside this one, let one go, and then waited for a
    // thread under five busy that never came, holding the lane's queue lock
    // the thread finishing a call takes (the sync-lane deadlock).
    var outsider: Outsider = .{};
    try outsider.occupy(executor.io());
    for (0..4) |_| {
        var call: Prepared = .{};
        call.job.lane = .sync;
        lanes.submit(&call.job);
        call.finished.waitUncancelable(testing.io);
        while (call.job.held()) std.Thread.yield() catch std.atomic.spinLoopHint();
        lanes.retire(&call.job);
    }
    try testing.expectEqual(@as(u32, @intCast(workerCount(executor))), lanes.stats(.sync).threads);
    outsider.gate.set(testing.io);
    try outsider.group.await(executor.io());
}
