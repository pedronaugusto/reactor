//! Sizes and deadlines that come from the caller, at the far end of their
//! range: refused or saturated, never wrapped.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const Loop = @import("Loop.zig");
const Runtime = @import("Runtime.zig");
const Stacks = @import("fiber/Stacks.zig");
const clock = @import("clock.zig");
const loop_internal = @import("loop/internal.zig");
const Fake = @import("testing/Fake.zig");

test "a task count past what slabs can number is refused" {
    // The slab count rounds the task count up; at the top of the range that sum wrapped.
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var stacks: Stacks = undefined;
    // Linux without guard regions counts the mappings first and refuses the count itself.
    if (stacks.init(failing.allocator(), .{ .count = std.math.maxInt(u32), .size = .fromRaw(64 << 10) })) |_| {
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.OutOfMemory, error.TooManyTasks => {},
        else => return err,
    }
}

test "a stack size past the address space is refused" {
    var stacks: Stacks = undefined;
    try testing.expectError(error.SystemResources, stacks.init(testing.allocator, .{ .count = 4, .size = .fromRaw(std.math.maxInt(usize)) }));
    try testing.expectError(error.SystemResources, stacks.init(testing.allocator, .{ .count = 4, .size = .fromRaw(1 << 62) }));
}

test "a deadline beyond the end of the timeline waits and cancels" {
    var virtual: clock.Virtual = .{};
    var fake = Fake.init(testing.allocator, .{ .seeded = .{ .seed = 1, .virtual = &virtual } });
    defer fake.deinit();
    var loop: Loop = undefined;
    loop_internal.initWith(&loop, .{ .custom = fake.custom() }, .{ .virtual = &virtual }, 4);
    defer loop.deinit(testing.allocator);
    const far: Io.Clock.Timestamp = .{ .clock = .awake, .raw = .{ .nanoseconds = std.math.maxInt(i96) } };
    var timer: Loop.Op = .{ .kind = .{ .timer = far } };
    try loop.submit(&timer);
    // Armed at the end of the timeline: a wait is long but never negative or wrapped.
    const left = loop.nextTimeout().?;
    try testing.expect(left.nanoseconds > 0);
    try testing.expectEqual(@as(u32, 0), try loop.run(.nowait));
    loop.cancel(&timer);
    var reaped: [1]*Loop.Op = undefined;
    try testing.expectEqual(@as(usize, 1), loop.reap(&reaped).len);
    try testing.expectError(error.Canceled, timer.result.timer);
}

test "a worker count past the processors a runtime can number is refused" {
    var runtime: Runtime = undefined;
    try testing.expectError(error.SystemResources, runtime.init(testing.allocator, .{ .workers = std.math.maxInt(u16) }));
}
