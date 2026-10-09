const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Runtime = @import("../Runtime.zig");
extern "c" fn reactor_seh(*anyopaque, *const fn (*anyopaque) callconv(.c) void, *u32) c_int;

fn suspended(context: *anyopaque) callconv(.c) void {
    const io: *Io = @ptrCast(@alignCast(context)); // safe: run passes its Io through the fixture
    io.sleep(.fromMilliseconds(1), .awake) catch @panic("SEH fixture sleep canceled");
}
fn run(io: Io) !void {
    var context = io;
    var marker: u32 = 0;
    try testing.expectEqual(@as(c_int, 1), reactor_seh(&context, suspended, &marker));
    try testing.expectEqual(@as(u32, 3), marker);
}
test "V6 SEH unwinds finally and finds its handler after a fiber suspension" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var runtime: Runtime = undefined;
    try runtime.init(testing.allocator, .{ .workers = 0, .max_tasks = 8 });
    defer runtime.deinit();
    try runtime.start();
    var future = try runtime.io().concurrent(run, .{runtime.io()});
    try future.await(runtime.io());
}
