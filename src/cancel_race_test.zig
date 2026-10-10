//! A cancel sent from one thread to a task parked on another processor,
//! racing the task's own end: the request waits in the task's processor's
//! inbox, so the record it names must still be there when the processor
//! looks.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const fiber = @import("fiber.zig");
const Runtime = @import("Runtime.zig");

fn napper(io: Io, nap: Io.Duration) Io.Cancelable!void {
    try io.sleep(nap, .awake);
}

test "a cancel that races the end of its task finds the task's record intact" {
    if (!fiber.supported) return error.SkipZigTest;
    const runtime = try testing.allocator.create(Runtime);
    defer testing.allocator.destroy(runtime);
    runtime.init(testing.allocator, .{ .workers = 3, .max_tasks = 256, .stack_size = .fromRaw(256 << 10), .offload = .none }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => |e| return e,
    };
    defer runtime.deinit();
    try runtime.start();
    const io = runtime.io();
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    for (0..4000) |_| {
        var group: Io.Group = .init;
        const nap: Io.Duration = .fromMicroseconds(100);
        for (0..12) |_| try group.concurrent(io, napper, .{ io, nap });
        // About when the tasks' own sleeps end.
        try io.sleep(.fromMicroseconds(70 + random.uintLessThan(u32, 60)), .awake);
        group.cancel(io);
    }
}
