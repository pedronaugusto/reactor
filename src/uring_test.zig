//! The runtime and the loop on io_uring itself: shakedown's conformance
//! suite, sockets, files, cancels and timeouts against the real kernel.
//! Linux only; skipped where io_uring is missing or refused.
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const net = Io.net;
const shakedown = @import("shakedown");

const Runtime = @import("Runtime.zig");
const Loop = @import("Loop.zig");
const fiber = @import("fiber.zig");

fn runtime(r: *Runtime, workers: u16) !void {
    if (builtin.os.tag != .linux or !fiber.supported) return error.SkipZigTest;
    r.init(testing.allocator, .{ .workers = workers, .max_tasks = 512, .stack_size = .fromRaw(256 << 10) }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => |e| return e,
    };
    errdefer r.deinit();
    try r.start();
}

test "shakedown's conformance suite passes on io_uring with workers" {
    var r: Runtime = undefined;
    try runtime(&r, 3);
    defer r.deinit();
    var failure: shakedown.conformance.Failure = undefined;
    shakedown.conformance.run(testing.allocator, r.io(), .{ .failure = &failure }) catch {
        std.debug.print("{s}: {t}\n", .{ failure.check, failure.err });
        return error.Nonconforming;
    };
}

test "shakedown's conformance suite passes on io_uring with no thread of reactor's own" {
    var r: Runtime = undefined;
    try runtime(&r, 0);
    defer r.deinit();
    var failure: shakedown.conformance.Failure = undefined;
    shakedown.conformance.run(testing.allocator, r.io(), .{ .failure = &failure }) catch {
        std.debug.print("{s}: {t}\n", .{ failure.check, failure.err });
        return error.Nonconforming;
    };
}

fn echoOnce(io: Io, server: *net.Server) !void {
    var stream = try server.accept(io);
    defer stream.close(io);
    var buffer: [64]u8 = undefined;
    var reader = stream.reader(io, &buffer);
    var out: [64]u8 = undefined;
    var writer = stream.writer(io, &out);
    const line = try reader.interface.takeDelimiterInclusive('\n');
    try writer.interface.writeAll(line);
    try writer.interface.flush();
}

test "a loopback echo: listen, accept, connect, read and write" {
    var r: Runtime = undefined;
    try runtime(&r, 2);
    defer r.deinit();
    const io = r.io();
    const address: net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var echo = try io.concurrent(echoOnce, .{ io, &server });
    var stream = try server.socket.address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var out: [64]u8 = undefined;
    var writer = stream.writer(io, &out);
    try writer.interface.writeAll("hello, ring\n");
    try writer.interface.flush();
    var buffer: [64]u8 = undefined;
    var reader = stream.reader(io, &buffer);
    try testing.expectEqualStrings("hello, ring\n", try reader.interface.takeDelimiterInclusive('\n'));
    try echo.await(io);
}

/// A connected loopback TCP pair (Linux has no `AF_INET` socketpair).
fn tcpPair(io: Io) ![2]net.Stream {
    const address: net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var connecting = try io.concurrent(net.IpAddress.connect, .{ &server.socket.address, io, .{ .mode = .stream } });
    const accepted = try server.accept(io);
    const connected = try connecting.await(io);
    return .{ accepted, connected };
}

fn readOne(io: Io, socket: net.Socket.Handle, buffer: []u8) (Io.Cancelable || Io.Operation.NetRead.Error)!usize {
    var data: [1][]u8 = .{buffer};
    const result = try io.operate(.{ .net_read = .{ .socket_handle = socket, .data = &data } });
    const r = try result.net_read;
    return r.data_len;
}

test "a socket write the send buffer has room for is made at once; one that would wait goes to the ring" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;
    var l: Loop = undefined;
    l.init(testing.allocator, .{ .backend = .io_uring }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => |e| return e,
    };
    defer l.deinit(testing.allocator);
    var sockets: [2]linux.fd_t = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets)));
    defer for (sockets) |fd| {
        _ = linux.close(fd);
    };
    var bytes: [4096]u8 = @splat(0x5a);
    var write: Loop.Op = .{ .kind = .{ .io = .{ .net_write = .{ .socket_handle = sockets[0], .data = &.{&bytes} } } } };
    try testing.expect(try l.start(&write));
    try testing.expectEqual(bytes.len, try (try write.result.io).net_write);
    // Fill the send buffer: the next write waits in the ring for room.
    while (true) {
        var fill: Loop.Op = .{ .kind = .{ .io = .{ .net_write = .{ .socket_handle = sockets[0], .data = &.{&bytes} } } } };
        if (!try l.start(&fill)) {
            var drain: [1 << 16]u8 = undefined;
            while (true) {
                const rc = linux.recvfrom(sockets[1], &drain, drain.len, linux.MSG.DONTWAIT, null, null);
                if (linux.errno(rc) != .SUCCESS) break;
            }
            while (try l.run(.once) == 0) {}
            var out: [1]*Loop.Op = undefined;
            const done = l.reap(&out);
            try testing.expectEqual(@as(usize, 1), done.len);
            try testing.expect(try (try done[0].result.io).net_write > 0);
            break;
        }
    }
}

test "a cancel ends a read the kernel holds" {
    var r: Runtime = undefined;
    try runtime(&r, 1);
    defer r.deinit();
    const io = r.io();
    const pair = try tcpPair(io);
    defer for (pair) |s| s.close(io);
    var buffer: [16]u8 = undefined;
    var reading = try io.concurrent(readOne, .{ io, pair[0].socket.handle, &buffer });
    try io.sleep(.fromMilliseconds(5), .awake);
    try testing.expectError(error.Canceled, reading.cancel(io));
}

test "after operateTimeout returns Timeout, the kernel writes nothing into the buffer" {
    var r: Runtime = undefined;
    try runtime(&r, 0);
    defer r.deinit();
    const io = r.io();
    const pair = try tcpPair(io);
    defer for (pair) |s| s.close(io);
    var buffer: [16]u8 = @splat(0xaa);
    var data: [1][]u8 = .{&buffer};
    const result = io.operateTimeout(.{ .net_read = .{ .socket_handle = pair[0].socket.handle, .data = &data } }, .{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } });
    try testing.expectError(error.Timeout, result);
    // The buffer is "freed": poisoned, then data arrives on the socket.
    @memset(&buffer, 0xdd);
    var send: [1][]const u8 = .{"late"};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = pair[1].socket.handle, .data = &send } })).net_write;
    try io.sleep(.fromMilliseconds(5), .awake);
    for (buffer) |b| try testing.expectEqual(@as(u8, 0xdd), b);
}

test "a positional write, a sync and a positional read of a file" {
    var r: Runtime = undefined;
    try runtime(&r, 1);
    defer r.deinit();
    const io = r.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "ring.bin", .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, "evented bytes", 3);
    try file.sync(io);
    var buffer: [13]u8 = undefined;
    try testing.expectEqual(@as(usize, 13), try file.readPositionalAll(io, &buffer, 3));
    try testing.expectEqualStrings("evented bytes", &buffer);
}

test "the loop alone: a timer and a wake, completions reaped" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var l: Loop = undefined;
    l.init(testing.allocator, .{}) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => |e| return e,
    };
    defer l.deinit(testing.allocator);
    const now = Io.Clock.Timestamp.now(Io.Threaded.global_single_threaded.io(), .awake);
    var timer: Loop.Op = .{ .kind = .{ .timer = now.addDuration(.{ .raw = .fromMilliseconds(2), .clock = .awake }) }, .user_data = 7 };
    try l.submit(&timer);
    try testing.expectEqual(@as(u32, 0), try l.run(.nowait));
    try testing.expect(l.nextTimeout() != null);
    try testing.expectEqual(@as(u32, 1), try l.run(.once));
    var out: [4]*Loop.Op = undefined;
    const done = l.reap(&out);
    try testing.expectEqual(@as(usize, 1), done.len);
    try testing.expectEqual(@as(usize, 7), done[0].user_data);
    // A wake from another thread ends a wait with nothing to deliver.
    const thread = try std.Thread.spawn(.{}, Loop.wake, .{&l});
    defer thread.join();
    try testing.expectEqual(@as(u32, 0), try l.run(.once));
}

fn readUntilClosed(io: Io, socket: net.Socket.Handle, out: *(Io.Operation.NetRead.Error!usize)) Io.Cancelable!void {
    var buffer: [16]u8 = undefined;
    var data: [1][]u8 = .{&buffer};
    const result = try io.operate(.{ .net_read = .{ .socket_handle = socket, .data = &data } });
    out.* = if (result.net_read) |r| r.data_len else |err| err;
}

test "closing a socket another task is reading ends that read, on whichever processor it waits" {
    var r: Runtime = undefined;
    try runtime(&r, 3);
    defer r.deinit();
    const io = r.io();
    for (0..20) |_| {
        const pair = try tcpPair(io);
        defer pair[1].close(io);
        var outcome: Io.Operation.NetRead.Error!usize = 1234;
        var reader = try io.concurrent(readUntilClosed, .{ io, pair[0].socket.handle, &outcome });
        try io.sleep(.fromMilliseconds(2), .awake);
        pair[0].close(io);
        try reader.await(io);
        try testing.expectError(error.SocketUnconnected, outcome);
    }
}

fn wakeSoon(io: Io, word: *std.atomic.Value(u32)) Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(1), .awake);
    word.store(1, .release);
    io.futexWake(u32, &word.raw, 1);
}

/// Overwrites the stack below the caller, where a returned wait's frame was.
noinline fn clobberStack() void {
    var junk: [32 << 10]u8 = undefined;
    @memset(&junk, 0xaa);
    std.mem.doNotOptimizeAway(&junk);
}

test "a wait with a deadline on the real clock leaves nothing in the kernel once it returns" {
    var r: Runtime = undefined;
    try runtime(&r, 0);
    defer r.deinit();
    const io = r.io();
    for (0..20) |_| {
        var word: std.atomic.Value(u32) = .init(0);
        var waker = try io.concurrent(wakeSoon, .{ io, &word });
        // A real-clock deadline is a timer the kernel holds, not the wheel.
        const deadline: Io.Clock.Timestamp = .{ .clock = .real, .raw = Io.Clock.real.now(io).addDuration(.fromSeconds(30)) };
        while (word.load(.acquire) == 0) try io.futexWaitTimeout(u32, &word.raw, 0, .{ .deadline = deadline });
        // The timer's cancel must have come back before the wait returned:
        // nothing may complete into the frame now gone.
        clobberStack();
        try waker.await(io);
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}
