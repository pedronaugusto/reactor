const std = @import("std");
const reactor = @import("reactor");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    // --- README:usage ---
    var runtime: reactor.Runtime = undefined;
    runtime.init(gpa, .{}) catch |err| switch (err) {
        // No evented backend on this system yet.
        error.BackendUnavailable => return,
        else => |e| return e,
    };
    defer runtime.deinit();
    try runtime.start();
    const io = runtime.io();

    // Plain std.Io code: a thousand tasks, each a stack of its own, none a
    // thread.
    var total: std.atomic.Value(u64) = .init(0);
    var group: std.Io.Group = .init;
    for (0..1000) |i| group.async(io, work, .{ io, i, &total });
    try group.await(io);
    std.debug.assert(total.load(.monotonic) == 1000 * 999 / 2);
    // --- README:usage ---
}

fn work(io: std.Io, i: u64, total: *std.atomic.Value(u64)) std.Io.Cancelable!void {
    try io.sleep(.fromMicroseconds(@intCast(i % 7)), .awake);
    _ = total.fetchAdd(i, .monotonic);
}
