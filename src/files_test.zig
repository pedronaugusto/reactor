//! Fixed-file cache lifetime on a real ring.
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const Files = @import("backend/uring/Files.zig");
const Kept = @import("backend/uring/Kept.zig");

test "a positional read of a write-only file reports its missing read capability" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const Runtime = @import("Runtime.zig");
    var runtime: Runtime = undefined;
    runtime.init(testing.allocator, .{ .backend = .io_uring, .workers = 0, .max_tasks = 32 }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => return err,
    };
    try runtime.start();
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
    var owner: struct {
        const Self = @This();
        ring: linux.IoUring,
        pub fn consumePublished(self: *Self) void {
            std.debug.assert(self.ring.flags & linux.IORING_SETUP_SQPOLL == 0);
        }
    } = .{ .ring = linux.IoUring.init(32, 0) catch return error.SkipZigTest };
    defer owner.ring.deinit();
    var kept = try Kept.init(testing.allocator);
    defer kept.deinit(testing.allocator);
    var files = try Files.init(testing.allocator, &owner.ring, 32, true, &kept);
    defer files.deinit(testing.allocator);
    if (!files.enabled) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(testing.io, "fixed", .{ .read = true });
    defer file.close(testing.io);
    kept.record(file.handle);
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

/// One task's close of a file two rings hold, made on the second ring while
/// the first ends its hold: it resumes on the first unless its close keeps it
/// where it began. The second ring's processor is kept busy until then, and
/// the home processor never runs, so no processor takes the task back.
const Migration = struct {
    const Scheduler = @import("Scheduler.zig");
    const Task = @import("scheduler/Task.zig");
    const native = @import("ext/native.zig");

    io: std.Io,
    dir: std.Io.Dir,
    first: *Scheduler.Processor,
    second: *Scheduler.Processor,
    started: std.atomic.Value(bool) = .init(false),
    closed: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    /// What the second ring read from the file opened at the closed one's number.
    read: [8]u8 = undefined,
    read_len: usize = 0,
    reused: bool = false,
    held_after: bool = false,

    fn moveTo(target: *Scheduler.Processor) void {
        const Move = struct {
            fn run(raw: *anyopaque, task: *Task) void {
                const processor: *Scheduler.Processor = @ptrCast(@alignCast(raw)); // safe: the target passed to park
                task.processor_loop = &processor.loop;
                processor.pushRemote(task);
            }
        };
        if (Scheduler.processor() != target) Scheduler.park(.{ .func = Move.run, .context = target });
    }

    fn readOn(m: *Migration, file: std.Io.File, buffer: []u8) !void {
        moveTo(m.first);
        m.started.store(true, .release);
        _ = try file.readStreaming(m.io, &.{buffer});
        moveTo(m.second);
        _ = file.readStreaming(m.io, &.{buffer}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => |e| return e,
        };
    }

    /// Holds the second processor until the closing task is queued back on
    /// it or has closed elsewhere: it spins without parking.
    fn hold(m: *Migration) void {
        while (!m.closed.load(.acquire) and m.second.remote.inbox.isEmpty()) std.atomic.spinLoopHint();
    }

    fn run(m: *Migration) !void {
        defer m.finished.store(true, .release);
        const task = Scheduler.current().?;
        var old = try m.dir.openFile(m.io, "old", .{});
        var old_open = true;
        defer if (old_open) old.close(m.io);
        var buffer: [5]u8 = undefined;
        task.pins += 1;
        try m.readOn(old, &buffer);
        try testing.expect(m.first.loop.backend.io_uring.files.contains(old.handle));
        try testing.expect(m.second.loop.backend.io_uring.files.contains(old.handle));
        var holder = try m.io.concurrent(hold, .{m});
        task.pins -= 1;
        const number = old.handle;
        old_open = false;
        old.close(m.io);
        m.closed.store(true, .release);
        holder.await(m.io);
        m.held_after = m.first.loop.backend.io_uring.files.contains(number) or m.second.loop.backend.io_uring.files.contains(number);
        task.pins += 1;
        defer task.pins -= 1;
        moveTo(m.second);
        const new = try m.dir.openFile(m.io, "new", .{});
        defer new.close(m.io);
        m.reused = new.handle == number;
        m.read_len = new.readStreaming(m.io, &.{&m.read}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => |e| return e,
        };
    }
};

test "a close removes the file from every ring that held it, whichever processor its aborts resume the task on, so a reused number reads its own file" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const Runtime = @import("Runtime.zig");
    var runtime: Runtime = undefined;
    runtime.init(testing.allocator, .{ .backend = .io_uring, .workers = 2, .monitor = false, .max_tasks = 32, .stack_size = .fromRaw(256 << 10) }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer runtime.deinit();
    try runtime.start();
    const io = runtime.io();
    const core = Migration.native.runtimeOf(io).?;
    if (!core.processors[1].loop.backend.io_uring.files.enabled) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "old", .data = "old.." });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "new", .data = "new.." });
    var m: Migration = .{ .io = io, .dir = tmp.dir, .first = &core.processors[1], .second = &core.processors[2] };
    var closing = try io.concurrent(Migration.run, .{&m});
    // The home processor runs the task until it moves to a worker; then the
    // home thread stays out of the runtime until it is done, so its
    // processor takes nothing from the workers.
    while (!m.started.load(.acquire)) try io.sleep(.fromMilliseconds(1), .awake);
    while (!m.finished.load(.acquire)) try testing.io.sleep(.fromMilliseconds(1), .awake);
    try closing.await(io);
    try testing.expect(m.reused);
    try testing.expectEqualStrings("new..", m.read[0..m.read_len]);
    try testing.expect(!m.held_after);
}

// A descriptor opened and closed outside the `Io`, as airlock's temps
// are (a raw `openat`, writes through the `Io`, a raw `close` for its
// EIO), then a second file opened outside it that gets the same number:
// the second's writes through the `Io` go to the second file.
test "a descriptor number another file reuses, opened and closed outside the Io, writes to its own file" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const Runtime = @import("Runtime.zig");
    var runtime: Runtime = undefined;
    runtime.init(testing.allocator, .{ .backend = .io_uring, .workers = 0, .max_tasks = 32 }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => return err,
    };
    try runtime.start();
    defer runtime.deinit();
    const io = runtime.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true };
    const first_fd: linux.fd_t = @intCast(linux.openat(tmp.dir.handle, "first", flags, 0o600));
    try testing.expect(first_fd >= 0);
    const first: std.Io.File = .{ .handle = first_fd, .flags = .{ .nonblocking = false } };
    try first.writePositionalAll(io, "first", 0);
    _ = linux.close(first_fd);
    const second_fd: linux.fd_t = @intCast(linux.openat(tmp.dir.handle, "second", flags, 0o600));
    try testing.expect(second_fd >= 0);
    defer _ = linux.close(second_fd);
    // The kernel gives the lowest free number: the one just closed.
    if (second_fd != first_fd) return error.SkipZigTest;
    const second: std.Io.File = .{ .handle = second_fd, .flags = .{ .nonblocking = false } };
    try second.writePositionalAll(io, "second", 0);
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("first", try tmp.dir.readFile(testing.io, "first", &buffer));
    try testing.expectEqualStrings("second", try tmp.dir.readFile(testing.io, "second", &buffer));
}

test "a file the runtime opens is held as a fixed file, and its close lets go of the number" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const Runtime = @import("Runtime.zig");
    var runtime: Runtime = undefined;
    runtime.init(testing.allocator, .{ .backend = .io_uring, .workers = 0, .max_tasks = 32 }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => return err,
    };
    try runtime.start();
    defer runtime.deinit();
    const ring = runtime.core.scheduler.processors[0].loop.backend.io_uring;
    if (!ring.features.fixed_files) return error.SkipZigTest;
    const io = runtime.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "kept", .{ .read = true });
    try testing.expect(runtime.core.kept.contains(file.handle));
    try file.writePositionalAll(io, "kept", 0);
    try testing.expect(ring.files.contains(file.handle));
    const handle = file.handle;
    file.close(io);
    try testing.expect(!runtime.core.kept.contains(handle));
    try testing.expect(!ring.files.contains(handle));
}
