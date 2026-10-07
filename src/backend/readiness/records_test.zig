//! The readiness backend's descriptor table.
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;

const records = @import("records.zig");

test "records are found, freed and found again across a full table" {
    // Descriptors are handles there, and no readiness backend runs.
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const W = struct {
        const Self = @This();
        prev: ?*Self = null,
        next: ?*Self = null,
    };
    var t = try records.Records(W).init(testing.allocator, 16);
    defer t.deinit(testing.allocator);
    var indices: [16]u32 = undefined;
    for (&indices, 0..) |*index, fd| index.* = t.insert(@intCast(fd * 7)).?;
    try testing.expectEqual(@as(?u32, null), t.insert(1000));
    for (indices, 0..) |index, fd| try testing.expectEqual(@as(?u32, index), t.find(@intCast(fd * 7)));
    for (indices, 0..) |index, fd| if (fd % 2 == 0) t.remove(index);
    for (indices, 0..) |index, fd| {
        const found = t.find(@intCast(fd * 7));
        if (fd % 2 == 0) try testing.expectEqual(@as(?u32, null), found) else try testing.expectEqual(@as(?u32, index), found);
    }
    const again = t.insert(14).?;
    try testing.expect(t.at(again).generation > 1);
    try testing.expectEqual(@as(?u32, again), t.find(14));
}
