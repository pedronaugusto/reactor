//! Source layers, lowest first. Every production source has one place;
//! a layer imports only from the ones below it.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "system calls", .patterns = &.{
        "src/sys.zig",
        "src/sys/memory.zig",
        "src/sys/socket.zig",
        "src/sys/dial.zig",
        "src/sys/BufferRing.zig",
        "src/sys/Notify.zig",
        "src/sys/poll.zig",
        "src/sys/process.zig",
        "src/sys/win32.zig",
        "src/sys/getaddrinfo.zig",
        "src/sys/lookup_windows.zig",
        "src/sys/receive.zig",
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
        "src/backend/uring/Accept.zig",
        "src/backend/uring/Receive.zig",
        "src/backend/uring/Files.zig",
        "src/backend/wait.zig",
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
    } },
    .{ .name = "operations", .patterns = &.{
        "src/ops.zig",
        "src/ops/perform.zig",
        "src/ops/futex.zig",
        "src/ops/tasks.zig",
        "src/ops/batch.zig",
        "src/ops/lane_call.zig",
        "src/ops/readiness.zig",
        "src/ops/resolve.zig",
        "src/ops/resolve/order.zig",
        "src/ops/lookup/windows.zig",
        "src/ops/Lookup.zig",
    } },
    .{ .name = "runtime", .patterns = &.{
        "src/Runtime.zig",
        "src/runtime/Core.zig",
        "src/runtime/options.zig",
        "src/runtime/route.zig",
        "src/runtime/slots.zig",
        "src/runtime/io_ops.zig",
        "src/runtime/child.zig",
    } },
    .{ .name = "extensions", .patterns = &.{
        "src/ext.zig",
        "src/ext/native.zig",
        "src/ext/kernel.zig",
        "src/ext/Wake.zig",
        "src/ext/Process.zig",
        "src/ext/wait.zig",
        "src/ext/Job.zig",
        "src/ext/blocking.zig",
        "src/ext/Signals.zig",
        "src/ext/net.zig",
        "src/ext/net/connect.zig",
        "src/ext/net/resolve.zig",
        "src/ext/net/abort.zig",
        "src/ext/net/Deadlines.zig",
        "src/ext/net/Receiver.zig",
        "src/ext/net/receiver/Groups.zig",
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
