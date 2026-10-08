//! Regressions that also build on the published R2-R5 main.
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Runtime = @import("Runtime.zig");
const Driver = @import("testing/Driver.zig");

fn init(r: *Runtime) !void {
    r.init(testing.allocator, .{ .workers = 0, .max_tasks = 32, .offload = .none }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => return err,
    };
}

test "R1 native child wait uses no inline wait lane" {
    var r: Runtime = undefined;
    try init(&r);
    defer r.deinit();
    var child = try std.process.spawn(testing.io, .{
        .argv = if (builtin.os.tag == .windows) &.{ "cmd.exe", "/c", "exit 7" } else &.{ "/bin/sh", "-c", "sleep 0.02; exit 7" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    errdefer child.kill(testing.io);
    const before = r.stats().lanes[@backingInt(Runtime.Lane.wait)].@"inline";
    try testing.expectEqual(std.process.Child.Term{ .exited = 7 }, try child.wait(r.io()));
    try testing.expectEqual(before, r.stats().lanes[@backingInt(Runtime.Lane.wait)].@"inline");
}

test "R1 native open and stat use no inline file lane" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Runtime = undefined;
    try init(&r);
    defer r.deinit();
    if (r.backendKind() != .io_uring) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const before = r.stats().lanes[@backingInt(Runtime.Lane.general)].@"inline";
    const file = try tmp.dir.createFile(r.io(), "native", .{ .read = true });
    defer file.close(r.io());
    try file.writePositionalAll(r.io(), "native", 0);
    const opened = try tmp.dir.openFile(r.io(), "native", .{});
    defer opened.close(r.io());
    try testing.expectEqual(@as(u64, 6), (try opened.stat(r.io())).size);
    try testing.expectEqual(@as(u64, 6), (try tmp.dir.statFile(r.io(), "native", .{})).size);
    try testing.expectEqual(before, r.stats().lanes[@backingInt(Runtime.Lane.general)].@"inline");
}

noinline fn deepPark(io: Io, address: *usize) Io.Cancelable!u8 {
    var bytes: [192 << 10]u8 = @splat(73);
    const memory: *volatile [192 << 10]u8 = &bytes;
    memory[0] = 73;
    address.* = @intFromPtr(&bytes[16 << 10]); // safe: the runtime owns the mapping until deinit
    try io.sleep(.fromMilliseconds(1), .awake);
    return memory[16 << 10];
}

test "R1 ended deep stacks discard unused pages before recycling" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var d: Driver = undefined;
    try d.init(testing.allocator, 1, .{ .max_tasks = 8, .stack_size = 512 << 10, .offload = .none });
    defer d.deinit();
    var address: usize = 0;
    var future = try d.io().concurrent(deepPark, .{ d.io(), &address });
    try testing.expectEqual(@as(u8, 73), try future.await(d.io()));
    const byte: *volatile u8 = @ptrFromInt(address); // safe: reserved anonymous mapping, now free in the owned stack pool
    try testing.expectEqual(@as(u8, 0), byte.*);
}
