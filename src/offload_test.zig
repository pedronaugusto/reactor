//! Raw offloads retain lane refusal and caller ownership across thread boundaries.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const shakedown = @import("shakedown");
const reactor = @import("reactor.zig");
const fiber = @import("fiber.zig");
const Scheduler = @import("Scheduler.zig");
const Threads = @import("testing/Threads.zig");

const Refusing = shakedown.Layer(u8, .{ .groupConcurrent = struct {
    fn refuse(_: ?*anyopaque, _: *Io.Group, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque) void) Io.ConcurrentError!void {
        return error.ConcurrencyUnavailable;
    }
}.refuse });

fn mark(ran: *bool) void {
    ran.* = true;
}
fn hookMark(context: *anyopaque) void {
    const ran: *bool = @ptrCast(@alignCast(context)); // safe: the retained test boolean
    mark(ran);
}
fn raw(io: Io, ran: *bool) anyerror!void {
    return reactor.blocking(io, .general, mark, .{ran});
}
fn hooked(io: Io, ran: *bool) anyerror!void {
    const hook = reactor.blockingHook(io);
    return hook.call(hook.context, hookMark, ran);
}
const Outside = struct {
    io: Io,
    outcome: anyerror!void = error.NotRun,
    fn refusal(c: *Outside) void {
        c.outcome = checkRefusal(c.io);
    }
    fn checkRefusal(io: Io) !void {
        var ran = false;
        try testing.expectError(error.ConcurrencyUnavailable, raw(io, &ran));
        try testing.expectError(error.ConcurrencyUnavailable, hooked(io, &ran));
        try testing.expect(!ran);
    }
    fn accepted(c: *Outside) void {
        c.outcome = checkAccepted(c.io);
    }
    fn threadId() std.Thread.Id {
        return std.Thread.getCurrentId();
    }
    fn hookId(context: *anyopaque) void {
        const id: *std.Thread.Id = @ptrCast(@alignCast(context)); // safe: the retained test result
        id.* = threadId();
    }
    fn offloadId(io: Io) anyerror!std.Thread.Id {
        return reactor.blocking(io, .general, threadId, .{});
    }
    fn hookedId(io: Io, id: *std.Thread.Id) anyerror!void {
        const hook = reactor.blockingHook(io);
        return hook.call(hook.context, hookId, id);
    }
    fn checkAccepted(io: Io) !void {
        const caller = threadId();
        try testing.expect(caller != try offloadId(io));
        var id: std.Thread.Id = caller;
        try hookedId(io, &id);
        try testing.expect(caller != id);
    }
};

test "r6: raw offload refusal survives a caller outside every runtime" {
    if (!fiber.supported) return error.SkipZigTest;
    var refusing: Refusing = .init(testing.io, 0);
    var target: Threads = undefined;
    try target.init(testing.allocator, .{ .workers = 0, .max_tasks = 8, .offload = .{ .injected = refusing.io() } });
    defer target.deinit();
    var c: Outside = .{ .io = target.io() };
    const thread = try std.Thread.spawn(.{}, Outside.refusal, .{&c});
    thread.join();
    try c.outcome;
    for (target.runtime.stats().lanes) |lane| try testing.expectEqual(@as(u64, 0), lane.@"inline");
}

test "r6: accepted raw offloads from outside run on their lanes" {
    if (!fiber.supported) return error.SkipZigTest;
    var target: Threads = undefined;
    try target.init(testing.allocator, .{ .workers = 0, .max_tasks = 8 });
    defer target.deinit();
    var c: Outside = .{ .io = target.io() };
    const thread = try std.Thread.spawn(.{}, Outside.accepted, .{&c});
    thread.join();
    try c.outcome;
    for (target.runtime.stats().lanes) |lane| try testing.expectEqual(@as(u64, 0), lane.@"inline");
}

const Cross = struct {
    published: Io.Event = .unset,
    release: Io.Event = .unset,
    io: Io = undefined,
    outcome: anyerror!void = error.NotRun,
    fn target(c: *Cross) void {
        var t: Threads = undefined;
        t.init(testing.allocator, .{ .workers = 1, .max_tasks = 8, .monitor = false }) catch |err| {
            c.outcome = err;
            c.published.set(testing.io);
            return;
        };
        defer t.deinit();
        c.io = t.io();
        c.outcome = {};
        c.published.set(testing.io);
        c.release.waitUncancelable(testing.io);
    }
    fn source(target_io: Io) !void {
        const owner = Scheduler.processor().?.scheduler;
        const thread = std.Thread.getCurrentId();
        _ = try Outside.offloadId(target_io);
        try testing.expectEqual(owner, Scheduler.processor().?.scheduler);
        // Root-only operations remain on their original home thread too.
        if (Scheduler.current().?.kind == .root) try testing.expectEqual(thread, std.Thread.getCurrentId());
        var id: std.Thread.Id = thread;
        try Outside.hookedId(target_io, &id);
        try testing.expectEqual(owner, Scheduler.processor().?.scheduler);
    }
};

test "r6: a foreign raw offload wakes its caller on the caller scheduler" {
    if (!fiber.supported) return error.SkipZigTest;
    var c: Cross = .{};
    const thread = try std.Thread.spawn(.{}, Cross.target, .{&c});
    defer thread.join();
    defer c.release.set(testing.io);
    c.published.waitUncancelable(testing.io);
    try c.outcome;
    var source: Threads = undefined;
    try source.init(testing.allocator, .{ .workers = 1, .max_tasks = 8, .monitor = false });
    defer source.deinit();
    try Cross.source(c.io);
    for (0..32) |_| {
        var task = try source.io().concurrent(Cross.source, .{c.io});
        try task.await(source.io());
    }
}
