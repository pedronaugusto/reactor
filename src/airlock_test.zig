//! airlock's raw device flushes through `syncLane`, the executor reactor
//! supplies for airlock's `Blocking`: each runs on the `sync` lane, the task
//! parked meanwhile, and a sync that ran keeps its own result.
const std = @import("std");
const current_thread = @import("testing/thread.zig");
const testing = std.testing;
const Io = std.Io;
const airlock = @import("airlock");
const reactor = @import("reactor.zig");
const supported = @import("Scheduler.zig").supported;
const Threads = @import("testing/Threads.zig");

/// `syncLane`, with the thread each raw sync ran on noted.
const Noting = struct {
    var caller: std.atomic.Value(u64) = .init(0);
    var elsewhere: std.atomic.Value(u32) = .init(0);
    var calls: std.atomic.Value(u32) = .init(0);

    /// The job airlock gave, noted where it runs.
    const Call = struct {
        job: *airlock.Blocking.Job,
        pub fn execute(call: *Call) void {
            if (@as(u64, current_thread.now()) != caller.load(.monotonic)) _ = elsewhere.fetchAdd(1, .monotonic);
            call.job.execute();
        }
    };

    fn run(_: *airlock.Blocking, io: Io, job: *airlock.Blocking.Job) Io.Cancelable!void {
        var call: Call = .{ .job = job };
        _ = calls.fetchAdd(1, .monotonic);
        return reactor.syncLane(io, &call);
    }
};

fn syncs(io: Io, dir: Io.Dir) !void {
    Noting.caller.store(current_thread.now(), .monotonic);
    var blocking: airlock.Blocking = .{ .run = Noting.run };
    const file = try dir.createFile(io, "file", .{});
    defer file.close(io);
    try file.writePositionalAll(io, "contents", 0);
    _ = try airlock.syncFile(io, file, .{ .blocking = &blocking });
    _ = try airlock.syncDir(io, dir, .{ .blocking = &blocking });
}

test "airlock's syncs run on the sync lane through syncLane, from a task and from the root" {
    if (!supported) return error.SkipZigTest;
    var t: Threads = undefined;
    try t.init(testing.allocator, .{ .workers = 1, .max_tasks = 8, .stack_size = .fromRaw(256 << 10) });
    defer t.deinit();
    const io = t.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try syncs(io, tmp.dir);
    var task = try io.concurrent(syncs, .{ io, tmp.dir });
    try task.await(io);
    try testing.expect(Noting.calls.load(.monotonic) > 0);
    try testing.expectEqual(Noting.calls.load(.monotonic), Noting.elsewhere.load(.monotonic));
}

test "a Blocking made by syncLaneFor runs airlock's syncs on the sync lane" {
    if (!supported) return error.SkipZigTest;
    var t: Threads = undefined;
    try t.init(testing.allocator, .{ .workers = 1, .max_tasks = 8, .stack_size = .fromRaw(256 << 10) });
    defer t.deinit();
    const io = t.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var lane = reactor.syncLaneFor(airlock.Blocking);
    const file = try tmp.dir.createFile(io, "file", .{});
    defer file.close(io);
    try file.writePositionalAll(io, "contents", 0);
    _ = try airlock.syncFile(io, file, .{ .blocking = &lane });
    _ = try airlock.syncDir(io, tmp.dir, .{ .blocking = &lane });
}
