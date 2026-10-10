//! Costs whose old and new implementations share the published std.Io API.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const reactor = @import("reactor");

const Parks = struct {
    io: Io,
    deep_entered: Io.Event = .unset,
    deep_release: Io.Event = .unset,
    shallow_entered: Io.Event = .unset,
    shallow_release: Io.Event = .unset,
};
noinline fn deep(parks: *Parks) u8 {
    var bytes: [192 << 10]u8 = undefined;
    const memory: *volatile [192 << 10]u8 = &bytes;
    for (0..bytes.len / 4096) |page| memory[page * 4096] = 73;
    std.mem.doNotOptimizeAway(&bytes);
    parks.deep_entered.set(parks.io);
    parks.deep_release.waitUncancelable(parks.io);
    var sum: u8 = 0;
    for (0..bytes.len / 4096) |page| sum +%= memory[page * 4096];
    return sum;
}
noinline fn deepThenShallow(parks: *Parks) u8 {
    const value = deep(parks);
    parks.shallow_entered.set(parks.io);
    parks.shallow_release.waitUncancelable(parks.io);
    return value;
}
fn stacks(io: Io, count: usize) !void {
    for (0..count) |_| {
        var parks: Parks = .{ .io = io };
        var task = try io.concurrent(deepThenShallow, .{&parks});
        parks.deep_entered.waitUncancelable(io);
        parks.deep_release.set(io);
        parks.shallow_entered.waitUncancelable(io);
        parks.shallow_release.set(io);
        if (task.await(io) != 176) return error.LiveStackCorrupted;
    }
}
fn verifyDepth(gpa: std.mem.Allocator, runtime: *reactor.Runtime) !void {
    const io = runtime.io();
    var parks: Parks = .{ .io = io };
    var task = try io.concurrent(deepThenShallow, .{&parks});
    parks.deep_entered.waitUncancelable(io);
    var dump: Io.Writer.Allocating = .init(gpa);
    defer dump.deinit();
    try runtime.dump(&dump.writer);
    parks.deep_release.set(io);
    parks.shallow_entered.waitUncancelable(io);
    parks.shallow_release.set(io);
    if (task.await(io) != 176) return error.LiveStackCorrupted;
    const prefix = "parked_stack=";
    const start = (std.mem.find(u8, dump.written(), prefix) orelse return error.NoParkedTask) + prefix.len;
    const end = std.mem.findScalarPos(u8, dump.written(), start, '\n') orelse dump.written().len;
    const depth = try std.fmt.parseInt(usize, dump.written()[start..end], 10);
    if (depth < 192 << 10) return error.DeepFrameOptimizedAway;
}
fn processes(io: Io, spawn_io: Io, count: usize) !void {
    for (0..count) |_| {
        var child = try std.process.spawn(spawn_io, .{
            .argv = if (builtin.os.tag == .windows) &.{ "cmd.exe", "/c", "exit 0" } else &.{ "/bin/sh", "-c", "exit 0" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        errdefer child.kill(spawn_io);
        const term = try child.wait(io);
        if (term != .exited or term.exited != 0) return error.ChildFailed;
    }
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--smoke")) return;
    if (args.len != 2) return error.ExpectedWorkload;
    const stack = std.mem.eql(u8, args[1], "stacks");
    if (!stack and !std.mem.eql(u8, args[1], "process")) return error.UnknownWorkload;
    var runtime: reactor.Runtime = undefined;
    try runtime.init(init.gpa, .{ .workers = 0, .max_tasks = 64, .stack_size = .fromRaw(512 << 10), .offload = .none });
    defer runtime.deinit();
    try runtime.start();
    const count: usize = if (stack) 2000 else 200;
    if (stack) try verifyDepth(init.gpa, &runtime);
    const before = Io.Clock.awake.now(init.io);
    if (stack) try stacks(runtime.io(), count) else try processes(runtime.io(), init.io, count);
    const elapsed = before.durationTo(Io.Clock.awake.now(init.io)).nanoseconds;
    var buffer: [1024]u8 = undefined;
    var stdout = Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print("{{\"io\":\"reactor\",\"workload\":\"{s}\",\"name\":\"{s}\",\"value\":{d:.3},\"unit\":\"ns/call\"}}\n", .{
        args[1],
        if (stack) "deep and shallow park + await" else "spawn exit-zero child + wait",
        @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(count)),
    });
    try stdout.interface.flush();
}
