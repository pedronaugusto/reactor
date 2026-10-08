//! Source layers, lowest first. Every production source has one place;
//! a layer imports only from the ones below it.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "system calls", .patterns = &.{
        "src/sys.zig",
        "src/sys/memory.zig",
        "src/sys/socket.zig",
        "src/sys/file.zig",
    } },
    .{ .name = "fibers, time and lanes", .patterns = &.{
        "src/fiber.zig",
        "src/fiber/Stacks.zig",
        "src/Wheel.zig",
        "src/clock.zig",
        "src/Lanes.zig",
        "src/lanes/SlotPool.zig",
    } },
    .{ .name = "backends", .patterns = &.{
        "src/backend.zig",
        "src/backend/Custom.zig",
        "src/backend/op.zig",
        "src/backend/pending.zig",
        "src/backend/Uring.zig",
        "src/backend/uring/results.zig",
        "src/backend/wait.zig",
        "src/backend/readiness.zig",
        "src/backend/readiness/calls.zig",
        "src/backend/readiness/closes.zig",
        "src/backend/readiness/records.zig",
        "src/backend/readiness/Epoll.zig",
        "src/backend/readiness/Kqueue.zig",
    } },
    .{ .name = "loop", .patterns = &.{
        "src/Loop.zig",
        "src/loop/internal.zig",
    } },
    .{ .name = "scheduler", .patterns = &.{
        "src/Scheduler.zig",
        "src/scheduler/Task.zig",
        "src/scheduler/run_queue.zig",
        "src/scheduler/inbox.zig",
        "src/scheduler/Monitor.zig",
        "src/scheduler/Spares.zig",
    } },
    .{ .name = "operations", .patterns = &.{
        "src/ops.zig",
        "src/ops/perform.zig",
        "src/ops/futex.zig",
        "src/ops/tasks.zig",
        "src/ops/batch.zig",
        "src/ops/lane_call.zig",
    } },
    .{ .name = "runtime", .patterns = &.{
        "src/Runtime.zig",
        "src/runtime/Core.zig",
        "src/runtime/options.zig",
        "src/runtime/route.zig",
        "src/runtime/slots.zig",
        "src/runtime/io_ops.zig",
    } },
    .{ .name = "public", .patterns = &.{
        "src/reactor.zig",
    } },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{};

pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "builtin",
        "shakedown",
        "std",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const required = blk: {
    var count: usize = 0;
    for (layers) |layer| count += layer.patterns.len;
    var paths: [count][]const u8 = undefined;
    var i: usize = 0;
    for (layers) |layer| for (layer.patterns) |path| {
        paths[i] = path;
        i += 1;
    };
    break :blk paths;
};
