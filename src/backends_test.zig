//! The runtime and the loop on each kernel backend this system has: epoll
//! (forced, on Linux) and kqueue (macOS, the BSDs), and io_uring for the
//! checks its own file does not make. shakedown's conformance suite,
//! sockets, pipes, files, timers on each clock, cancels, timeouts and
//! closes, against the real kernel.
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const net = Io.net;
const posix = std.posix;
const shakedown = @import("shakedown");

const Runtime = @import("Runtime.zig");
const Loop = @import("Loop.zig");
const fiber = @import("fiber.zig");
const reactor = @import("reactor.zig");
const wait_ext = @import("ext/wait.zig");
const kqueue_poller = @import("backend/readiness/Kqueue.zig");
const epoll_poller = @import("backend/readiness/Epoll.zig");

/// The readiness backends this system has.
const readiness: []const Loop.Backend = switch (builtin.os.tag) {
    .linux => &.{.epoll},
    .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => &.{.kqueue},
    else => &.{},
};

/// Every backend this system has.
const all: []const Loop.Backend = switch (builtin.os.tag) {
    .linux => &.{ .io_uring, .epoll },
    else => readiness,
};

fn runtime(r: *Runtime, backend: Loop.Backend, workers: u16) !void {
    if (!fiber.supported) return error.SkipZigTest;
    r.init(testing.allocator, .{ .backend = backend, .workers = workers, .max_tasks = 512, .stack_size = .fromRaw(256 << 10) }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => |e| return e,
    };
    errdefer r.deinit();
    try r.start();
}

fn conformance(backend: Loop.Backend, workers: u16) !void {
    var r: Runtime = undefined;
    try runtime(&r, backend, workers);
    defer r.deinit();
    var failure: shakedown.conformance.Failure = undefined;
    shakedown.conformance.run(testing.allocator, r.io(), .{ .failure = &failure }) catch {
        std.debug.print("{t}, {d} workers: {s}: {t}\n", .{ backend, workers, failure.check, failure.err });
        return error.Nonconforming;
    };
}

test "shakedown's conformance suite passes on each readiness backend, with workers and with none" {
    for (readiness) |backend| {
        try conformance(backend, 3);
        try conformance(backend, 0);
    }
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

fn echo(backend: Loop.Backend, workers: u16) !void {
    var r: Runtime = undefined;
    try runtime(&r, backend, workers);
    defer r.deinit();
    const io = r.io();
    const address: net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var task = try io.concurrent(echoOnce, .{ io, &server });
    var stream = try server.socket.address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var out: [64]u8 = undefined;
    var writer = stream.writer(io, &out);
    try writer.interface.writeAll("hello, poller\n");
    try writer.interface.flush();
    var buffer: [64]u8 = undefined;
    var reader = stream.reader(io, &buffer);
    try testing.expectEqualStrings("hello, poller\n", try reader.interface.takeDelimiterInclusive('\n'));
    try task.await(io);
}

test "a loopback echo on each readiness backend: listen, accept, connect, read and write" {
    for (readiness) |backend| {
        try echo(backend, 2);
        try echo(backend, 0);
    }
}

/// A connected loopback TCP pair.
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
    const got = try result.net_read;
    return got.data_len;
}

test "a cancel ends a read waiting for readiness" {
    for (readiness) |backend| {
        var r: Runtime = undefined;
        try runtime(&r, backend, 1);
        defer r.deinit();
        const io = r.io();
        const pair = try tcpPair(io);
        defer for (pair) |s| s.close(io);
        var buffer: [16]u8 = undefined;
        var reading = try io.concurrent(readOne, .{ io, pair[0].socket.handle, &buffer });
        try io.sleep(.fromMilliseconds(5), .awake);
        try testing.expectError(error.Canceled, reading.cancel(io));
    }
}

test "after operateTimeout returns Timeout on a readiness backend, nothing writes into the buffer" {
    for (readiness) |backend| {
        var r: Runtime = undefined;
        try runtime(&r, backend, 0);
        defer r.deinit();
        const io = r.io();
        const pair = try tcpPair(io);
        defer for (pair) |s| s.close(io);
        var buffer: [16]u8 = @splat(0xaa);
        var data: [1][]u8 = .{&buffer};
        const result = io.operateTimeout(.{ .net_read = .{ .socket_handle = pair[0].socket.handle, .data = &data } }, .{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } });
        try testing.expectError(error.Timeout, result);
        @memset(&buffer, 0xdd);
        var send: [1][]const u8 = .{"late"};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = pair[1].socket.handle, .data = &send } })).net_write;
        try io.sleep(.fromMilliseconds(5), .awake);
        for (buffer) |b| try testing.expectEqual(@as(u8, 0xdd), b);
        // The read the timeout took back is made again, and gets the bytes.
        try testing.expectEqual(@as(usize, 4), try readOne(io, pair[0].socket.handle, &buffer));
        try testing.expectEqualStrings("late", buffer[0..4]);
    }
}

test "a positional write, a sync and a positional read of a file on each readiness backend" {
    for (readiness) |backend| {
        var r: Runtime = undefined;
        try runtime(&r, backend, 1);
        defer r.deinit();
        const io = r.io();
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const file = try tmp.dir.createFile(io, "poller.bin", .{ .read = true });
        defer file.close(io);
        try file.writePositionalAll(io, "readiness bytes", 3);
        try file.sync(io);
        var buffer: [15]u8 = undefined;
        try testing.expectEqual(@as(usize, 15), try file.readPositionalAll(io, &buffer, 3));
        try testing.expectEqualStrings("readiness bytes", &buffer);
    }
}

fn readUntilClosed(io: Io, socket: net.Socket.Handle, out: *(Io.Operation.NetRead.Error!usize)) Io.Cancelable!void {
    var buffer: [16]u8 = undefined;
    var data: [1][]u8 = .{&buffer};
    const result = try io.operate(.{ .net_read = .{ .socket_handle = socket, .data = &data } });
    out.* = if (result.net_read) |got| got.data_len else |err| err;
}

test "closing a socket another task is reading ends that read, on whichever processor's poller it waits" {
    for (readiness) |backend| {
        var r: Runtime = undefined;
        try runtime(&r, backend, 3);
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
}

test "a descriptor number closed and opened again is waited on afresh, on every processor" {
    for (readiness) |backend| {
        var r: Runtime = undefined;
        try runtime(&r, backend, 3);
        defer r.deinit();
        const io = r.io();
        // Each pair registers its sockets on whichever pollers its reads
        // wait on; the numbers come back for the next pair.
        for (0..50) |i| {
            const pair = try tcpPair(io);
            defer for (pair) |s| s.close(io);
            var buffer: [8]u8 = undefined;
            var reading = try io.concurrent(readOne, .{ io, pair[0].socket.handle, &buffer });
            if (i % 2 == 0) try io.sleep(.fromMicroseconds(200), .awake);
            var send: [1][]const u8 = .{"ping"};
            _ = try (try io.operate(.{ .net_write = .{ .socket_handle = pair[1].socket.handle, .data = &send } })).net_write;
            try testing.expectEqual(@as(usize, 4), try reading.await(io));
        }
    }
}

fn sleepOn(io: Io, clock: Io.Clock, ms: i64) !i96 {
    const start = Io.Clock.awake.now(io);
    try io.sleep(.fromMilliseconds(ms), clock);
    return start.durationTo(Io.Clock.awake.now(io)).nanoseconds;
}

test "sleeps on the real and boot clocks wait on the kernel's own timers, and end on time" {
    for (all) |backend| {
        var r: Runtime = undefined;
        try runtime(&r, backend, 1);
        defer r.deinit();
        const io = r.io();
        for ([_]Io.Clock{ .real, .boot }) |clock| {
            const slept = try sleepOn(io, clock, 20);
            try testing.expect(slept >= 15 * std.time.ns_per_ms);
            try testing.expect(slept < 2 * std.time.ns_per_s);
        }
        // Two at once, the later armed first.
        var late = try io.concurrent(sleepOn, .{ io, Io.Clock.real, 30 });
        var early = try io.concurrent(sleepOn, .{ io, Io.Clock.real, 10 });
        const e = try early.await(io);
        const l = try late.await(io);
        try testing.expect(e < l);
    }
}

fn sleepRealHour(io: Io) Io.Cancelable!void {
    try io.sleep(.fromSeconds(3600), .real);
}

test "a cancel ends a sleep on the real clock" {
    for (all) |backend| {
        var r: Runtime = undefined;
        try runtime(&r, backend, 1);
        defer r.deinit();
        const io = r.io();
        var task = try io.concurrent(sleepRealHour, .{io});
        try io.sleep(.fromMilliseconds(2), .awake);
        try testing.expectError(error.Canceled, task.cancel(io));
    }
}

fn receiveOne(io: Io, socket: *net.Socket, buffer: []u8) !net.IncomingMessage {
    return socket.receive(io, buffer);
}

test "datagrams: a receive waits for one, a send delivers it" {
    for (all) |backend| {
        var r: Runtime = undefined;
        try runtime(&r, backend, 1);
        defer r.deinit();
        const io = r.io();
        const any: net.IpAddress = .{ .ip4 = .loopback(0) };
        var a = try any.bind(io, .{ .mode = .dgram });
        defer a.close(io);
        var b = try any.bind(io, .{ .mode = .dgram });
        defer b.close(io);
        var buffer: [32]u8 = undefined;
        var receiving = try io.concurrent(receiveOne, .{ io, &a, &buffer });
        try io.sleep(.fromMilliseconds(2), .awake);
        try b.send(io, &a.address, "datagram");
        const message = try receiving.await(io);
        try testing.expectEqualStrings("datagram", message.data);
        try testing.expectEqual(b.address.getPort(), message.from.getPort());
    }
}

test "short reads of datagrams queued together each return one, none waits for more" {
    for (all) |backend| {
        var r: Runtime = undefined;
        try runtime(&r, backend, 1);
        defer r.deinit();
        const io = r.io();
        const any: net.IpAddress = .{ .ip4 = .loopback(0) };
        var a = try any.bind(io, .{ .mode = .dgram });
        defer a.close(io);
        var b = try any.bind(io, .{ .mode = .dgram });
        defer b.close(io);
        // The first read waits, so the socket is registered and its event
        // says what is queued.
        var buffer: [64]u8 = undefined;
        var first = try io.concurrent(readOne, .{ io, a.handle, &buffer });
        try io.sleep(.fromMilliseconds(2), .awake);
        for ([_][]const u8{ "one", "two", "three" }) |m| try b.send(io, &a.address, m);
        try testing.expectEqual(@as(usize, 3), try first.await(io));
        // Each read is short of its buffer, and the next is still there.
        try testing.expectEqual(@as(usize, 3), try readOne(io, a.handle, &buffer));
        try testing.expectEqual(@as(usize, 5), try readOne(io, a.handle, &buffer));
        // Queued before any read: each read is made at once.
        for ([_][]const u8{ "four", "five", "six" }) |m| try b.send(io, &a.address, m);
        try io.sleep(.fromMilliseconds(2), .awake);
        for ([_]usize{ 4, 4, 3 }) |len| try testing.expectEqual(len, try readOne(io, a.handle, &buffer));
    }
}

fn writeLater(io: Io, file: Io.File, bytes: []const u8) !void {
    try io.sleep(.fromMilliseconds(3), .awake);
    var w = file.writerStreaming(io, &.{});
    try w.interface.writeAll(bytes);
}

test "a pipe in blocking mode is read when it is ready, and written in pieces it takes whole" {
    for (all) |backend| {
        var r: Runtime = undefined;
        try runtime(&r, backend, 1);
        defer r.deinit();
        const io = r.io();
        const fds = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
        const read_end: Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
        const write_end: Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
        defer read_end.close(io);
        var big: [100_000]u8 = undefined;
        for (&big, 0..) |*byte, i| byte.* = @truncate(i *% 7);
        var writer = try io.concurrent(writeLater, .{ io, write_end, @as([]const u8, &big) });
        var got: [100_000]u8 = undefined;
        var read_buffer: [512]u8 = undefined;
        var reader = read_end.readerStreaming(io, &read_buffer);
        try reader.interface.readSliceAll(&got);
        try writer.await(io);
        write_end.close(io);
        try testing.expectEqualSlices(u8, &big, &got);
        try testing.expectError(error.EndOfStream, reader.interface.takeByte());
    }
}

fn readBatch(io: Io, sockets: [2]net.Socket.Handle, buffers: *[2][8]u8) !usize {
    var storage: [2]Io.Operation.Storage = undefined;
    var batch: Io.Batch = .init(&storage);
    var data: [2][1][]u8 = .{ .{&buffers[0]}, .{&buffers[1]} };
    for (sockets, &data, 0..) |s, *d, i| batch.addAt(@intCast(i), .{ .net_read = .{ .socket_handle = s, .data = d } });
    var total: usize = 0;
    var seen: usize = 0;
    while (seen < 2) {
        try batch.awaitConcurrent(io, .none);
        while (batch.next()) |done| {
            total += (try done.result.net_read).data_len;
            seen += 1;
        }
    }
    return total;
}

test "a batch's reads wait for readiness and complete as their sockets are written" {
    for (readiness) |backend| {
        var r: Runtime = undefined;
        try runtime(&r, backend, 1);
        defer r.deinit();
        const io = r.io();
        const one = try tcpPair(io);
        defer for (one) |s| s.close(io);
        const two = try tcpPair(io);
        defer for (two) |s| s.close(io);
        var buffers: [2][8]u8 = undefined;
        var reading = try io.concurrent(readBatch, .{ io, .{ one[0].socket.handle, two[0].socket.handle }, &buffers });
        try io.sleep(.fromMilliseconds(2), .awake);
        for ([_]net.Socket.Handle{ two[1].socket.handle, one[1].socket.handle }) |s| {
            var send: [1][]const u8 = .{"abc"};
            _ = try (try io.operate(.{ .net_write = .{ .socket_handle = s, .data = &send } })).net_write;
        }
        try testing.expectEqual(@as(usize, 6), try reading.await(io));
    }
}

test "a connect to a port nobody listens on is refused" {
    for (readiness) |backend| {
        var r: Runtime = undefined;
        try runtime(&r, backend, 0);
        defer r.deinit();
        const io = r.io();
        // A port just freed: bound, then closed.
        const any: net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = try any.listen(io, .{ .reuse_address = true });
        const address = server.socket.address;
        server.deinit(io);
        try testing.expectError(error.ConnectionRefused, address.connect(io, .{ .mode = .stream }));
    }
}

// The loop alone.

fn loopOf(l: *Loop, backend: Loop.Backend) !void {
    l.init(testing.allocator, .{ .backend = backend }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => |e| return e,
    };
}

test "the loop alone on each readiness backend: a timer, a wake, a read made at once and one that waits" {
    for (readiness) |backend| {
        var l: Loop = undefined;
        try loopOf(&l, backend);
        defer l.deinit(testing.allocator);
        const sys = Io.Threaded.global_single_threaded.io();
        const now = Io.Clock.Timestamp.now(sys, .awake);
        var timer: Loop.Op = .{ .kind = .{ .timer = now.addDuration(.{ .raw = .fromMilliseconds(2), .clock = .awake }) }, .user_data = 7 };
        try l.submit(&timer);
        try testing.expectEqual(@as(u32, 0), try l.run(.nowait));
        try testing.expectEqual(@as(u32, 1), try l.run(.once));
        var out: [4]*Loop.Op = undefined;
        try testing.expectEqual(@as(usize, 7), l.reap(&out)[0].user_data);

        var fds: [2]posix.fd_t = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
        defer for (fds) |fd| {
            _ = posix.system.close(fd);
        };
        _ = &fds;
        var buffer: [8]u8 = undefined;
        var data: [1][]u8 = .{&buffer};
        const file: Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
        var read: Loop.Op = .{ .kind = .{ .io = .{ .file_read_streaming = .{ .file = file, .data = &data } } }, .user_data = 1 };
        try l.submit(&read);
        try testing.expectEqual(@as(u32, 0), try l.run(.nowait));
        // The host's own poller sees the loop's descriptor turn readable.
        const handle = try l.backendHandle();
        _ = posix.system.write(fds[1], "x", 1);
        var pfd = [1]posix.pollfd{.{ .fd = handle, .events = posix.POLL.IN, .revents = 0 }};
        try testing.expectEqual(@as(usize, 1), try posix.poll(&pfd, 1000));
        try testing.expectEqual(@as(u32, 1), try l.run(.nowait));
        try testing.expectEqual(@as(usize, 1), (try l.reap(&out)[0].result.io).file_read_streaming catch 0);

        // Data already there: made at once by `start`, nothing delivered.
        _ = posix.system.write(fds[1], "yz", 2);
        var again: Loop.Op = .{ .kind = .{ .io = .{ .file_read_streaming = .{ .file = file, .data = &data } } } };
        try testing.expect(try l.start(&again));
        try testing.expectEqual(@as(usize, 2), try (try again.result.io).file_read_streaming);

        const thread = try std.Thread.spawn(.{}, Loop.wake, .{&l});
        defer thread.join();
        try testing.expectEqual(@as(u32, 0), try l.run(.once));
    }
}

test "a descriptor closed outside the loop and announced with closing is waited on afresh when its number comes back" {
    for (readiness) |backend| {
        var l: Loop = undefined;
        try loopOf(&l, backend);
        defer l.deinit(testing.allocator);
        const sys = Io.Threaded.global_single_threaded.io();
        const first = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
        // A wait registers the read end, then is cancelled.
        var waiting: Loop.Op = .{ .kind = .{ .wait = .{ .readable = first[0] } } };
        try l.submit(&waiting);
        _ = try l.run(.nowait);
        l.cancel(&waiting);
        _ = try l.run(.nowait);
        var out: [4]*Loop.Op = undefined;
        try testing.expectError(error.Canceled, l.reap(&out)[0].result.wait);
        // Closed behind the loop's back, announced; the number comes back.
        Loop.closing(first[0]);
        _ = posix.system.close(first[0]);
        _ = posix.system.close(first[1]);
        const second = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
        defer for (second) |fd| {
            _ = posix.system.close(fd);
        };
        try testing.expectEqual(first[0], second[0]);
        var again: Loop.Op = .{ .kind = .{ .wait = .{ .readable = second[0] } } };
        try l.submit(&again);
        _ = try l.run(.nowait);
        _ = posix.system.write(second[1], "x", 1);
        const deadline = Io.Clock.Timestamp.now(sys, .awake).addDuration(.{ .raw = .fromSeconds(2), .clock = .awake });
        try testing.expectEqual(@as(u32, 1), try l.run(.{ .within = deadline }));
        try l.reap(&out)[0].result.wait;
    }
}

test "a recycled Wake descriptor remains registered on readiness backends" {
    for (readiness) |backend| {
        var r: Runtime = undefined;
        try runtime(&r, backend, 0);
        defer r.deinit();
        const io = r.io();
        for (0..32) |_| {
            var wake = try reactor.Wake.init(io);
            defer wake.deinit(io);
            // Register an unready descriptor before another task signals it.
            var sender = try io.concurrent(struct {
                fn send(i: Io, w: *reactor.Wake) !void {
                    try i.sleep(.fromMilliseconds(1), .awake);
                    w.signal();
                }
            }.send, .{ io, &wake });
            defer sender.cancel(io) catch {};
            try reactor.wait(io, .{ .wake = &wake }, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
            try sender.await(io);
        }
    }
}

test "r6: a short final stream read preserves EOF readiness" {
    for (readiness) |backend| {
        var l: Loop = undefined;
        try loopOf(&l, backend);
        defer l.deinit(testing.allocator);
        const io = testing.io;
        const pair = try tcpPair(io);
        defer {
            Loop.closing(pair[0].socket.handle);
            pair[0].close(io);
        }
        var sender_open = true;
        defer if (sender_open) pair[1].close(io);
        var buffer: [64]u8 = undefined;
        var data: [1][]u8 = .{&buffer};
        var read: Loop.Op = .{ .kind = .{ .io = .{ .net_read = .{ .socket_handle = pair[0].socket.handle, .data = &data } } } };
        var out: [4]*Loop.Op = undefined;
        // Register while empty. Both the final bytes and EOF are present
        // before the next poll: an edge must cover both reads.
        try l.submit(&read);
        defer if (l.in_flight != 0) {
            l.cancel(&read);
            _ = l.run(.nowait) catch unreachable; // unreachable: cancelling this registered read needs no allocation
            _ = l.reap(&out);
        };
        try testing.expectEqual(@as(u32, 0), try l.run(.nowait));
        var writer = pair[1].writer(io, &.{});
        try writer.interface.writeAll("final bytes");
        try writer.interface.flush();
        pair[1].close(io);
        sender_open = false;
        const deadline = Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = .fromSeconds(2), .clock = .awake });
        try testing.expectEqual(@as(u32, 1), try l.run(.{ .within = deadline }));
        const got = (try (try l.reap(&out)[0].result.io).net_read).data_len;
        try testing.expectEqualStrings("final bytes", buffer[0..got]);
        for (0..2) |_| {
            try l.submit(&read);
            const end = Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = .fromMilliseconds(100), .clock = .awake });
            try testing.expectEqual(@as(u32, 1), try l.run(.{ .within = end }));
            try testing.expectEqual(@as(usize, 0), (try (try l.reap(&out)[0].result.io).net_read).data_len);
        }
    }
}

test "r6: refused IPv6 connect followed by IPv4 reuses readiness" {
    const timed = @import("reactor.zig").net;
    for (readiness) |backend| {
        var r: Runtime = undefined;
        try runtime(&r, backend, 0);
        defer r.deinit();
        const io = r.io();
        const any: net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = try any.listen(io, .{ .reuse_address = true });
        defer server.deinit(io);
        const refused: net.IpAddress = .{ .ip6 = .loopback(server.socket.address.getPort()) };
        const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } };
        try testing.expectError(error.ConnectionRefused, timed.connect(io, &refused, .{ .timeout = timeout }));
        const connected = try timed.connect(io, &server.socket.address, .{ .timeout = timeout });
        defer connected.stream.close(io);
    }
}

/// A wait on `w` that ends ready, with nothing else to wait for.
fn expectReady(l: *Loop, w: Loop.Waitable) !void {
    var o: Loop.Op = .{ .kind = .{ .wait = w } };
    if (!try l.start(&o)) {
        _ = try l.run(.nowait);
        var out: [1]*Loop.Op = undefined;
        try testing.expectEqual(@as(usize, 1), l.reap(&out).len);
    }
    try o.result.wait;
}

test "a wait on a descriptor that is not open is ready, as a poll says, and does not panic" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    for (all) |backend| {
        var l: Loop = undefined;
        try loopOf(&l, backend);
        defer l.deinit(testing.allocator);
        // A number no descriptor has, and one that was closed.
        try expectReady(&l, .{ .readable = -1 });
        try expectReady(&l, .{ .writable = -1 });
        const pair = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
        _ = posix.system.close(pair[1]);
        _ = posix.system.close(pair[0]);
        try expectReady(&l, .{ .readable = pair[0] });
        try expectReady(&l, .{ .writable = pair[1] });
    }
}

test "a wait on a descriptor that is not open is ready on a runtime and on Threaded" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    try reactor.wait(testing.io, .{ .readable = -1 }, .none);
    try reactor.wait(testing.io, .{ .writable = -1 }, .none);
    for (all) |backend| {
        var r: Runtime = undefined;
        try runtime(&r, backend, 0);
        defer r.deinit();
        try reactor.wait(r.io(), .{ .readable = -1 }, .none);
        try reactor.wait(r.io(), .{ .writable = -1 }, .none);
        // Another member not ready: the one that is not open is the first.
        const pipe = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
        defer for (pipe) |fd| {
            _ = posix.system.close(fd);
        };
        try testing.expectEqual(@as(usize, 1), try reactor.waitAny(r.io(), &.{ .{ .readable = pipe[0] }, .{ .readable = -1 } }, .none));
    }
}

test "a readiness poller refuses a number no descriptor has instead of failing on it" {
    inline for (.{ kqueue_poller, epoll_poller }) |Poller| {
        if (!@hasDecl(Poller, "name")) continue;
        if (comptime !isThisSystems(Poller.name)) continue;
        var poller = Poller.init() catch return error.SkipZigTest;
        defer poller.deinit();
        try testing.expectError(error.Unpollable, poller.register(-1, 1, .{}, .read));
        try testing.expectError(error.Unpollable, poller.register(-1, 1, .{}, .write));
        // Nothing was queued or registered for it.
        poller.deregister(-1, .{}, .open);
    }
}

fn isThisSystems(comptime name: []const u8) bool {
    return for (readiness) |b| {
        if (std.mem.eql(u8, @tagName(b), name)) break true;
    } else false;
}

fn waitPriority(io: Io, handle: net.Socket.Handle, timeout: Io.Timeout) reactor.WaitError!void {
    return reactor.wait(io, .{ .priority = handle }, timeout);
}

fn sendOutOfBand(handle: net.Socket.Handle) !void {
    const byte = "!";
    const rc = posix.system.sendto(handle, byte, 1, posix.MSG.OOB, null, 0);
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(rc));
}

fn within(n: i64) Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(n), .clock = .awake } };
}

/// A connected pair that closes as `Loop` wants descriptors closed.
fn closePair(io: Io, pair: [2]net.Stream) void {
    for (pair) |stream| {
        Loop.closing(stream.socket.handle);
        stream.close(io);
    }
}

/// A priority wait on `io` ends for urgent data and for nothing else.
fn expectPriorityWait(io: Io) !void {
    const pair = try tcpPair(io);
    defer closePair(io, pair);
    const watched = pair[0].socket.handle;
    var nothing = try io.concurrent(waitPriority, .{ io, watched, within(30) });
    try testing.expectError(error.Timeout, nothing.await(io));
    // Plain data makes the descriptor readable, not urgent.
    var writer = pair[1].writer(io, &.{});
    try writer.interface.writeAll("plain");
    try writer.interface.flush();
    var plain = try io.concurrent(waitPriority, .{ io, watched, within(30) });
    try testing.expectError(error.Timeout, plain.await(io));
    // Urgent data arriving while a task waits ends the wait.
    var urgent = try io.concurrent(waitPriority, .{ io, watched, within(5000) });
    try io.sleep(.fromMilliseconds(5), .awake);
    try sendOutOfBand(pair[1].socket.handle);
    try urgent.await(io);
    // A cancel ends a wait that has nothing to report.
    const quiet = try tcpPair(io);
    defer closePair(io, quiet);
    var canceled = try io.concurrent(waitPriority, .{ io, quiet[0].socket.handle, .none });
    try io.sleep(.fromMilliseconds(5), .awake);
    try testing.expectError(error.Canceled, canceled.cancel(io));
}

test "a priority wait ends for urgent data only, on a runtime of each backend" {
    if (!wait_ext.has_priority) return error.SkipZigTest;
    for (all) |backend| {
        for ([_]u16{ 0, 2 }) |workers| {
            var r: Runtime = undefined;
            try runtime(&r, backend, workers);
            defer r.deinit();
            try expectPriorityWait(r.io());
        }
    }
}

test "a priority wait on Threaded ends for urgent data only" {
    if (!wait_ext.has_priority) return error.SkipZigTest;
    const io = testing.io;
    const pair = try tcpPair(io);
    defer pair[0].close(io);
    defer pair[1].close(io);
    const watched = pair[0].socket.handle;
    try testing.expectError(error.Timeout, reactor.wait(io, .{ .priority = watched }, within(30)));
    var writer = pair[1].writer(io, &.{});
    try writer.interface.writeAll("plain");
    try writer.interface.flush();
    try testing.expectError(error.Timeout, reactor.wait(io, .{ .priority = watched }, within(30)));
    try sendOutOfBand(pair[1].socket.handle);
    try reactor.wait(io, .{ .priority = watched }, within(5000));
}

test "a priority wait is unsupported where poll cannot report one" {
    if (wait_ext.has_priority) return error.SkipZigTest;
    const io = testing.io;
    const pair = try tcpPair(io);
    defer pair[0].close(io);
    defer pair[1].close(io);
    const watched: Io.File.Handle = pair[0].socket.handle;
    try testing.expectError(error.Unsupported, reactor.wait(io, .{ .priority = watched }, .none));
    // Among other members, and when it would have to look only.
    try testing.expectError(error.Unsupported, reactor.waitAny(io, &.{ .{ .readable = watched }, .{ .priority = watched } }, within(0)));
    for (all) |backend| {
        var r: Runtime = undefined;
        try runtime(&r, backend, 0);
        defer r.deinit();
        var task = try r.io().concurrent(waitPriority, .{ r.io(), pair[0].socket.handle, .none });
        try testing.expectError(error.Unsupported, task.await(r.io()));
    }
}

test "a priority wait on the loop alone is a readiness operation where the kernel has a filter for it" {
    for (all) |backend| {
        var l: Loop = undefined;
        try loopOf(&l, backend);
        defer l.deinit(testing.allocator);
        const io = testing.io;
        const pair = try tcpPair(io);
        defer closePair(io, pair);
        var o: Loop.Op = .{ .kind = .{ .wait = .{ .priority = pair[0].socket.handle } } };
        const done = try l.start(&o);
        if (!done) {
            // Nothing urgent yet; then the urgent byte arrives.
            try testing.expectEqual(@as(u32, 0), try l.run(.nowait));
            try sendOutOfBand(pair[1].socket.handle);
            const sys = Io.Threaded.global_single_threaded.io();
            const deadline = Io.Clock.Timestamp.now(sys, .awake).addDuration(.{ .raw = .fromSeconds(2), .clock = .awake });
            try testing.expectEqual(@as(u32, 1), try l.run(.{ .within = deadline }));
            var out: [1]*Loop.Op = undefined;
            _ = l.reap(&out);
        }
        if (backend == .kqueue or !wait_ext.has_priority) {
            try testing.expectError(error.Unsupported, o.result.wait);
        } else {
            try o.result.wait;
        }
    }
}
