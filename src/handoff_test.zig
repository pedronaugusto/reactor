//! The monitor on the readiness backends: a worker stuck in a blocking
//! file call loses its processor to a spare thread, so the tasks it held
//! go on; a task that holds its processor without switching out is
//! recorded as a stall.
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const posix = std.posix;

const Runtime = @import("Runtime.zig");
const Loop = @import("Loop.zig");
const Scheduler = @import("Scheduler.zig");
const fiber = @import("fiber.zig");

const readiness: ?Loop.Backend = switch (builtin.os.tag) {
    .linux => .epoll,
    .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => .kqueue,
    else => null,
};

const libc = struct {
    extern "c" fn mkfifo(path: [*:0]const u8, mode: posix.mode_t) c_int;
};

/// A named pipe at `path`: opening it for reading waits, in the kernel,
/// until someone opens it for writing.
fn makeFifo(path: [:0]const u8) !void {
    const rc = switch (builtin.os.tag) {
        .linux => std.os.linux.mknodat(std.os.linux.AT.FDCWD, path, std.os.linux.S.IFIFO | 0o600, 0),
        .windows => return error.SkipZigTest,
        else => libc.mkfifo(path, 0o600),
    };
    if (posix.errno(rc) != .SUCCESS) return error.NoFifo;
}

const Rendezvous = struct {
    path: [:0]const u8,
    /// The processor the blocked open began on.
    blocked_on: u16 = 0,
};

/// Opens the pipe for writing, which lets the reader's open return.
fn writeSide(io: Io, rendezvous: *Rendezvous) !void {
    const file = try Io.Dir.cwd().openFile(io, rendezvous.path, .{ .mode = .write_only });
    file.close(io);
}

/// On a worker: starts the writer, which waits in this processor's LIFO
/// slot (no other worker can steal it from there), then opens the pipe
/// for reading, which blocks the thread until the writer runs. Only a
/// handoff of this processor lets the writer run.
fn readSide(io: Io, rendezvous: *Rendezvous) !void {
    rendezvous.blocked_on = Scheduler.processor().?.index;
    var writer = try io.concurrent(writeSide, .{ io, rendezvous });
    const file = try Io.Dir.cwd().openFile(io, rendezvous.path, .{ .mode = .read_only });
    file.close(io);
    try writer.await(io);
}

/// A thread outside the runtime starts the reader, so a worker takes it:
/// the home thread meanwhile waits in no `Io` call, and runs nothing.
fn fromOutside(io: Io, rendezvous: *Rendezvous, out: *anyerror!void) void {
    var reader = io.concurrent(readSide, .{ io, rendezvous }) catch |err| {
        out.* = err;
        return;
    };
    out.* = reader.await(io);
}

test "a worker stuck in a blocking file call hands its processor to a spare, and the tasks queued there run" {
    const backend = readiness orelse return error.SkipZigTest;
    if (!fiber.supported) return error.SkipZigTest;
    var r: Runtime = undefined;
    r.init(testing.allocator, .{ .backend = backend, .workers = 2, .max_tasks = 64, .stack_size = .fromRaw(256 << 10) }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => |e| return e,
    };
    defer r.deinit();
    try r.start();
    const io = r.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buffer);
    var path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buffer, "{s}/pipe", .{dir_buffer[0..dir_len]}, 0);
    try makeFifo(path);
    for (0..3) |_| {
        var rendezvous: Rendezvous = .{ .path = path };
        var outcome: anyerror!void = error.NotRun;
        const thread = try std.Thread.spawn(.{}, fromOutside, .{ io, &rendezvous, &outcome });
        thread.join();
        try outcome;
        try testing.expect(rendezvous.blocked_on != 0);
    }
    try testing.expect(r.stats().handoffs >= 3);
}

fn fifoRuntime(r: *Runtime, workers: u16) !void {
    const backend = readiness orelse return error.SkipZigTest;
    if (!fiber.supported) return error.SkipZigTest;
    r.init(testing.allocator, .{ .backend = backend, .workers = workers, .max_tasks = 64, .stack_size = .fromRaw(256 << 10) }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => |e| return e,
    };
    errdefer r.deinit();
    try r.start();
}

test "the root stuck in a blocking file call lends the home processor to a spare, and has it back" {
    var r: Runtime = undefined;
    try fifoRuntime(&r, 1);
    defer r.deinit();
    const io = r.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buffer);
    var path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buffer, "{s}/pipe", .{dir_buffer[0..dir_len]}, 0);
    try makeFifo(path);
    const home = std.Thread.getCurrentId();
    for (0..3) |_| {
        // The root's own reader: the writer waits in the home processor's
        // LIFO slot, which only a handoff lets run.
        var rendezvous: Rendezvous = .{ .path = path };
        try readSide(io, &rendezvous);
        try testing.expectEqual(@as(u16, 0), rendezvous.blocked_on);
        try testing.expectEqual(home, std.Thread.getCurrentId());
        // A task on the home processor: it leaves the home thread, which
        // gets the processor back for the root.
        var task = try io.concurrent(readSide, .{ io, &rendezvous });
        try task.await(io);
        try testing.expectEqual(home, std.Thread.getCurrentId());
    }
    try testing.expect(r.stats().handoffs >= 6);
}

fn spinUntilStall(r: *Runtime) !void {
    const clock_io = Io.Threaded.global_single_threaded.io();
    const start = Io.Clock.awake.now(clock_io);
    while (r.stats().stalls == 0) {
        if (start.durationTo(Io.Clock.awake.now(clock_io)).nanoseconds > 2 * std.time.ns_per_s) return error.StallNotRecorded;
        std.atomic.spinLoopHint();
    }
}

test "a task that holds its processor past report_after without switching out is recorded as a stall" {
    const backend = readiness orelse return error.SkipZigTest;
    if (!fiber.supported) return error.SkipZigTest;
    var r: Runtime = undefined;
    r.init(testing.allocator, .{ .backend = backend, .workers = 1, .max_tasks = 64, .stack_size = .fromRaw(256 << 10), .report_after = .fromMilliseconds(5) }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => |e| return e,
    };
    defer r.deinit();
    try r.start();
    const io = r.io();
    var task = try io.concurrent(spinUntilStall, .{&r});
    try task.await(io);
    try testing.expect(r.stats().stalls >= 1);
}

const windows = std.os.windows;
const Pipe = struct {
    extern "kernel32" fn CreateNamedPipeW([*:0]const u16, u32, u32, u32, u32, u32, u32, ?*windows.SECURITY_ATTRIBUTES) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*windows.SECURITY_ATTRIBUTES, u32, u32, ?windows.HANDLE) callconv(.winapi) windows.HANDLE;

    fn send(handle: windows.HANDLE) !void {
        var status: windows.IO_STATUS_BLOCK = undefined;
        const byte = [_]u8{'x'};
        try testing.expectEqual(windows.NTSTATUS.SUCCESS, windows.ntdll.NtWriteFile(handle, null, null, null, &status, &byte, 1, null, null));
    }

    fn read(io: Io, file: Io.File, writer: windows.HANDLE) !void {
        var sending = try io.concurrent(send, .{writer});
        // glint-ignore: Z026 -- cleanup after the test has judged the task; cancel hands back the task's own result, which the test no longer reads
        defer sending.cancel(io) catch {};
        var byte: [1]u8 = undefined;
        try testing.expectEqual(@as(usize, 1), try file.readStreaming(io, &.{&byte}));
        try testing.expectEqual(@as(u8, 'x'), byte[0]);
        try sending.await(io);
    }

    fn outside(io: Io, file: Io.File, writer: windows.HANDLE, result: *anyerror!void) void {
        var reading = io.concurrent(read, .{ io, file, writer }) catch |err| {
            result.* = err;
            return;
        };
        result.* = reading.await(io);
    }
};

test "a synchronous Windows pipe read hands its IOCP processor to a spare" {
    if (builtin.os.tag != .windows or !fiber.supported) return error.SkipZigTest;
    var r: Runtime = undefined;
    try r.init(testing.allocator, .{ .workers = 1, .max_tasks = 64, .stack_size = .fromRaw(256 << 10) });
    defer r.deinit();
    try r.start();
    const io = r.io();
    const name = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\reactor-handoff");
    const server = Pipe.CreateNamedPipeW(name, 1, 0, 1, 64, 64, 0, null);
    try testing.expect(server != windows.INVALID_HANDLE_VALUE);
    const file: Io.File = .{ .handle = server, .flags = .{ .nonblocking = false } };
    defer file.close(io);
    const client = Pipe.CreateFileW(name, 0x40000000, 0, null, 3, 0, null);
    try testing.expect(client != windows.INVALID_HANDLE_VALUE);
    defer windows.CloseHandle(client);
    var outcome: anyerror!void = error.NotRun;
    const thread = try std.Thread.spawn(.{}, Pipe.outside, .{ io, file, client, &outcome });
    thread.join();
    try outcome;
    try testing.expect(r.stats().handoffs > 0);
}
