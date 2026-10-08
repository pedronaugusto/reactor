//! Fixed-file cache lifetime on a real ring.
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const Files = @import("backend/uring/Files.zig");

test "a positional read of a write-only file reports its missing read capability" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const Runtime = @import("Runtime.zig");
    var runtime: Runtime = undefined;
    runtime.init(testing.allocator, .{ .backend = .io_uring, .workers = 0, .max_tasks = 32 }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer runtime.deinit();
    const io = runtime.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "write-only", .{});
    defer file.close(io);
    var byte: [1]u8 = undefined;
    try testing.expectError(error.NotOpenForReading, file.readPositional(io, &.{&byte}, 0));
}

test "removing a fixed file preserves requests not submitted yet" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var owner: struct { ring: linux.IoUring } = .{ .ring = linux.IoUring.init(32, 0) catch return error.SkipZigTest };
    defer owner.ring.deinit();
    var files = try Files.init(testing.allocator, &owner.ring, 32, true);
    defer files.deinit(testing.allocator);
    if (!files.enabled) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(testing.io, "fixed", .{ .read = true });
    defer file.close(testing.io);
    try file.writePositionalAll(testing.io, "x", 0);
    var byte: [1]u8 = undefined;
    const sqe = try owner.ring.get_sqe();
    sqe.prep_read(file.handle, &byte, 0);
    sqe.user_data = 123;
    files.use(&owner.ring, sqe);
    try testing.expect(files.contains(file.handle));
    try testing.expect(sqe.flags & linux.IOSQE_FIXED_FILE != 0);
    files.remove(&owner, file.handle);
    try testing.expect(!files.contains(file.handle));
    try testing.expectEqual(file.handle, sqe.fd);
    try testing.expectEqual(@as(u8, 0), sqe.flags & linux.IOSQE_FIXED_FILE);
    _ = try owner.ring.submit();
    var cqes: [1]linux.io_uring_cqe = undefined;
    try testing.expectEqual(@as(u32, 1), try owner.ring.copy_cqes(&cqes, 1));
    try testing.expectEqual(@as(i32, 1), cqes[0].res);
    try testing.expectEqual(@as(u8, 'x'), byte[0]);
}
