//! Fixed-file cache lifetime on a real ring.
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const Files = @import("backend/uring/Files.zig");

test "removing a fixed file preserves requests not submitted yet" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var owner: struct { ring: linux.IoUring } = .{ .ring = linux.IoUring.init(32, 0) catch return error.SkipZigTest };
    defer owner.ring.deinit();
    var files = try Files.init(testing.allocator, &owner.ring, 32, true);
    defer files.deinit(testing.allocator);
    if (!files.enabled) return error.SkipZigTest;
    const pipe = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    defer for (pipe) |fd| {
        _ = linux.close(fd);
    };
    var byte: [1]u8 = undefined;
    const sqe = try owner.ring.get_sqe();
    sqe.prep_read(pipe[0], &byte, std.math.maxInt(u64));
    sqe.user_data = 123;
    files.use(&owner.ring, sqe);
    try testing.expect(files.contains(pipe[0]));
    try testing.expect(sqe.flags & linux.IOSQE_FIXED_FILE != 0);
    files.remove(&owner, pipe[0]);
    try testing.expect(!files.contains(pipe[0]));
    try testing.expectEqual(pipe[0], sqe.fd);
    try testing.expectEqual(@as(u8, 0), sqe.flags & linux.IOSQE_FIXED_FILE);
    try testing.expectEqual(@as(usize, 1), linux.write(pipe[1], "x", 1));
    _ = try owner.ring.submit();
    var cqes: [1]linux.io_uring_cqe = undefined;
    try testing.expectEqual(@as(u32, 1), try owner.ring.copy_cqes(&cqes, 1));
    try testing.expectEqual(@as(i32, 1), cqes[0].res);
    try testing.expectEqual(@as(u8, 'x'), byte[0]);
}
