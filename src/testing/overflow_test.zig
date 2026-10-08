//! A real fault in a child, never a caught language panic in the parent.
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const order = @import("preflight_order");
const options = @import("preflight_runner_options");
const Runtime = @import("../Runtime.zig");

noinline fn recurse(depth: usize) usize {
    var frame: [2048]u8 = undefined;
    const bytes: *volatile [2048]u8 = &frame;
    for (0..frame.len) |i| bytes[i] = @truncate(depth + i);
    if (depth == 0) return bytes[0];
    return recurse(depth - 1) + bytes[17];
}
fn overflow() usize {
    return recurse(256);
}

const name = "R1 guard overflow terminates the isolated child";
test "R1 guard overflow terminates the isolated child" {
    if (builtin.sanitize_thread) return error.SkipZigTest;
    if (try testing.environ.contains(testing.allocator, "REACTOR_OVERFLOW_CHILD")) {
        if (builtin.os.tag != .windows) {
            const action: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
            std.posix.sigaction(.SEGV, &action, null);
            std.posix.sigaction(.BUS, &action, null);
        }
        var r: Runtime = undefined;
        try r.init(testing.allocator, .{ .workers = 0, .stack_size = 64 << 10, .max_tasks = 2, .offload = .none });
        defer r.deinit();
        var future = try r.io().concurrent(overflow, .{});
        var buffer: [32]u8 = undefined;
        var out = Io.File.stdout().writerStreaming(testing.io, &buffer);
        try out.interface.writeAll("overflow armed\n");
        try out.interface.flush();
        _ = future.await(r.io());
        return error.GuardDidNotFault;
    }
    const path = try std.process.executablePathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(path);
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    try env.put("REACTOR_OVERFLOW_CHILD", "1");
    // Use preflight's real assignment algorithm and its embedded durations,
    // so the child runs just this test from the same portable binary.
    const names = try testing.allocator.alloc([]const u8, builtin.test_functions.len);
    defer testing.allocator.free(names);
    var target: usize = 0;
    for (builtin.test_functions, names, 0..) |test_fn, *slot, i| {
        slot.* = test_fn.name;
        if (std.mem.endsWith(u8, test_fn.name, name)) target = i;
    }
    const weights = try order.weigh(testing.allocator, if (options.durations.len == 0) "{}" else options.durations, names, order.key);
    defer testing.allocator.free(weights);
    var selected: usize = 0;
    for (0..names.len) |i| {
        const indices = try order.assign(testing.allocator, names, weights, .{ .index = i, .count = names.len });
        defer testing.allocator.free(indices);
        if (std.mem.findScalar(usize, indices, target) != null) {
            selected = i;
            break;
        }
    }
    var shard_buffer: [64]u8 = undefined;
    try env.put("PREFLIGHT_SHARD", try std.mem.print(&shard_buffer, "{d}/{d}", .{ selected + 1, names.len }));
    var child = try std.process.spawn(testing.io, .{ .argv = &.{path}, .environ_map = &env, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore });
    errdefer child.kill(testing.io);
    var read_buffer: [256]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(testing.io, &read_buffer);
    try testing.expectEqualStrings("overflow armed", try reader.interface.takeDelimiterExclusive('\n'));
    const term = try child.wait(testing.io);
    if (builtin.os.tag == .windows) {
        try testing.expect(term == .exited and (term.exited == 5 or term.exited == 253));
    } else {
        try testing.expect(term == .signal and (term.signal == .SEGV or term.signal == .BUS));
    }
}
