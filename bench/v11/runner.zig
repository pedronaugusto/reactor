//! Runs the actual imported suite functions, serially, on measured task stacks.
//! The suite's Threaded test infrastructure remains available for std helpers.
const std = @import("std");
const builtin = @import("builtin");
const v11 = @import("v11");
const testing = std.testing;
pub const fuzz = @import("preflight_default_test_runner").fuzz;
pub const std_options: std.Options = .{ .logFn = log };
var log_errors: usize = 0;

pub fn main(init: std.process.Init.Minimal) !void {
    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var parked: usize = 0;
    var overall: usize = 0;
    const log_io = std.Io.Threaded.global_single_threaded.io();
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(log_io, &buffer);
    for (builtin.test_functions) |test_fn| {
        testing.allocator_instance = .init(std.heap.page_allocator, .{ .canary = 0xc3a701ba, .check_write_after_free = true });
        testing.io_instance = .init(testing.allocator, .{ .argv0 = .init(init.args), .environ = init.environ });
        testing.environ = init.environ;
        testing.random_seed = 0x726536;
        testing.log_level = .warn;
        log_errors = 0;
        var runtime: v11.reactor.Runtime = undefined;
        try runtime.init(std.heap.page_allocator, .{ .workers = 0, .measure_stacks = true, .environ = init.environ, .argv0 = .init(init.args) });
        try runtime.start();
        v11.io = runtime.io();
        try output.interface.print("{{\"event\":\"start\",\"test\":{f}}}\n", .{std.json.fmt(test_fn.name, .{})});
        try output.interface.flush();
        var task = try v11.io.concurrent(runTest, .{test_fn.func});
        const result = task.await(v11.io);
        const stats = runtime.stats();
        parked = @max(parked, stats.parked_high_water);
        overall = @max(overall, stats.stack_high_water.?);
        runtime.deinit();
        testing.io_instance.deinit();
        const leaks = testing.allocator_instance.deinit();
        const status: []const u8 = if (result) |_| status: {
            passed += 1;
            break :status "pass";
        } else |err| status: {
            if (err == error.SkipZigTest) {
                skipped += 1;
                break :status "skip";
            }
            failed += 1;
            std.debug.print("{s}: {t}\n", .{ test_fn.name, err });
            break :status "fail";
        };
        if (leaks != 0 or log_errors != 0) failed += 1;
        try output.interface.print("{{\"event\":\"result\",\"test\":{f},\"status\":\"{s}\",\"parked_high_water\":{d},\"stack_high_water\":{d},\"leaks\":{d}}}\n", .{ std.json.fmt(test_fn.name, .{}), status, stats.parked_high_water, stats.stack_high_water.?, leaks });
        try output.interface.flush();
    }
    try output.interface.print("{{\"event\":\"summary\",\"tests\":{d},\"passed\":{d},\"skipped\":{d},\"failed\":{d},\"parked_high_water\":{d},\"stack_high_water\":{d},\"stack_size\":1048576,\"workers\":0,\"os\":\"{s}\",\"arch\":\"{s}\"}}\n", .{ builtin.test_functions.len, passed, skipped, failed, parked, overall, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
    try output.interface.flush();
    if (failed != 0) return error.SuiteFailed;
}

fn runTest(function: *const fn () anyerror!void) anyerror!void {
    return function();
}

fn log(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (level == .err) log_errors +|= 1;
    if (@backingInt(level) <= @backingInt(testing.log_level)) std.log.defaultLog(level, scope, format, args);
}
