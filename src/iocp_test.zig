//! The runtime and the loop on IOCP itself: shakedown's conformance suite,
//! sockets, pipes, processes, cancels, timeouts and a host's own port,
//! against the real kernel. Windows only. Also tasks on Windows stacks:
//! large frames, deep recursion and stack walks inside a task.
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const net = Io.net;
const shakedown = @import("shakedown");

const Runtime = @import("Runtime.zig");
const Loop = @import("Loop.zig");
const fiber = @import("fiber.zig");
const backend = @import("backend.zig");

fn skipOffWindows() !void {
    if (builtin.os.tag != .windows or !fiber.supported) return error.SkipZigTest;
}

fn runtime(r: *Runtime, workers: u16) !void {
    try skipOffWindows();
    // std's spawn finds programs on the PATH of the environment it is given.
    try r.init(testing.allocator, .{ .workers = workers, .max_tasks = 512, .stack_size = 256 << 10, .environ = testing.environ });
    errdefer r.deinit();
    try testing.expectEqual(@as(?backend.Kind, .iocp), r.backendKind());
    try r.start();
}

fn conformance(io: Io) !void {
    var failure: shakedown.conformance.Failure = undefined;
    shakedown.conformance.run(testing.allocator, io, .{ .failure = &failure }) catch {
        std.debug.print("{s}: {t}\n", .{ failure.check, failure.err });
        return error.Nonconforming;
    };
}

test "shakedown's conformance suite passes on IOCP with workers" {
    var r: Runtime = undefined;
    try runtime(&r, 3);
    defer r.deinit();
    try conformance(r.io());
}

test "shakedown's conformance suite passes on IOCP with no thread of reactor's own" {
    var r: Runtime = undefined;
    try runtime(&r, 0);
    defer r.deinit();
    try conformance(r.io());
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

test "a loopback echo over AFD: listen, accept, connect, read and write" {
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
    // The connected socket's own end is the loopback's, with a port.
    try testing.expect(stream.socket.address.ip4.bytes[0] == 127);
    try testing.expect(stream.socket.address.getPort() != 0);
    var out: [64]u8 = undefined;
    var writer = stream.writer(io, &out);
    try writer.interface.writeAll("hello, port\n");
    try writer.interface.flush();
    var buffer: [64]u8 = undefined;
    var reader = stream.reader(io, &buffer);
    try testing.expectEqualStrings("hello, port\n", try reader.interface.takeDelimiterInclusive('\n'));
    try echo.await(io);
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
    const r = try result.net_read;
    return r.data_len;
}

fn writeAll(io: Io, socket: net.Socket.Handle, bytes: []const u8) !void {
    var data: [1][]const u8 = .{bytes};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = socket, .data = &data } })).net_write;
}

test "a cancel ends a receive the kernel holds" {
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
    // The socket still works after the cancel.
    try writeAll(io, pair[1].socket.handle, "ok");
    try testing.expectEqual(@as(usize, 2), try readOne(io, pair[0].socket.handle, &buffer));
}

test "a receive with data waiting finishes at once, and one at end of stream reads nothing" {
    var r: Runtime = undefined;
    try runtime(&r, 0);
    defer r.deinit();
    const io = r.io();
    const pair = try tcpPair(io);
    defer pair[0].close(io);
    try writeAll(io, pair[1].socket.handle, "abc");
    try io.sleep(.fromMilliseconds(2), .awake);
    var buffer: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), try readOne(io, pair[0].socket.handle, &buffer));
    try testing.expectEqualStrings("abc", buffer[0..3]);
    pair[1].close(io);
    try testing.expectEqual(@as(usize, 0), try readOne(io, pair[0].socket.handle, &buffer));
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
    try writeAll(io, pair[1].socket.handle, "late");
    try io.sleep(.fromMilliseconds(5), .awake);
    for (buffer) |b| try testing.expectEqual(@as(u8, 0xdd), b);
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

fn acceptOne(io: Io, server: *net.Server) !net.Stream {
    return server.accept(io);
}

test "a cancelled accept loses no connection: the next accept takes it" {
    var r: Runtime = undefined;
    try runtime(&r, 1);
    defer r.deinit();
    const io = r.io();
    const address: net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var waiting = try io.concurrent(acceptOne, .{ io, &server });
    try io.sleep(.fromMilliseconds(5), .awake);
    if (waiting.cancel(io)) |stream| stream.close(io) else |err| try testing.expectEqual(error.Canceled, err);
    var client = try server.socket.address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var accepted = try server.accept(io);
    defer accepted.close(io);
    try writeAll(io, client.socket.handle, "x");
    var buffer: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), try readOne(io, accepted.socket.handle, &buffer));
}

test "datagrams: a send and a receive with the sender's address" {
    var r: Runtime = undefined;
    try runtime(&r, 1);
    defer r.deinit();
    const io = r.io();
    const address: net.IpAddress = .{ .ip4 = .loopback(0) };
    const a = try address.bind(io, .{ .mode = .dgram });
    defer a.close(io);
    const b = try address.bind(io, .{ .mode = .dgram });
    defer b.close(io);
    try b.send(io, &a.address, "datagram");
    var buffer: [64]u8 = undefined;
    const message = try a.receive(io, &buffer);
    try testing.expectEqualStrings("datagram", message.data);
    try testing.expectEqual(b.address.getPort(), message.from.getPort());
}

fn fromOutside(io: Io, socket: net.Socket.Handle, out: *[16]u8, n: *usize) void {
    writeAll(io, socket, "outside") catch return;
    // A read in a batch: std's batch code cannot run on the bound
    // socket here, the runtime runs it.
    var data: [1][]u8 = .{out};
    var storage: [1]Io.Operation.Storage = undefined;
    var batch: Io.Batch = .init(&storage);
    batch.addAt(0, .{ .net_read = .{ .socket_handle = socket, .data = &data } });
    batch.awaitAsync(io) catch return;
    const completion = batch.next() orelse return;
    const result = completion.result.net_read catch return;
    n.* = result.data_len;
}

test "a thread outside the runtime reads and writes a socket the runtime's tasks bound" {
    var r: Runtime = undefined;
    try runtime(&r, 2);
    defer r.deinit();
    const io = r.io();
    const pair = try tcpPair(io);
    defer for (pair) |s| s.close(io);
    var buffer: [16]u8 = undefined;
    var n: usize = 0;
    // The socket is bound to the home processor's port; the outside
    // thread's operations run on a worker, whose entries come back to it.
    const thread = try std.Thread.spawn(.{}, fromOutside, .{ io, pair[1].socket.handle, &buffer, &n });
    var got: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 7), try readOne(io, pair[0].socket.handle, &got));
    try writeAll(io, pair[0].socket.handle, "reply");
    thread.join();
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqualStrings("reply", buffer[0..5]);
}

test "a child's output through its pipes, and its exit through a wait packet" {
    var r: Runtime = undefined;
    try runtime(&r, 2);
    defer r.deinit();
    const io = r.io();
    const result = try std.process.run(testing.allocator, io, .{ .argv = &.{ "cmd.exe", "/c", "echo hello& exit 3" } });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqualStrings("hello", std.mem.trimEnd(u8, result.stdout, "\r\n"));
    try testing.expectEqual(std.process.Child.Term{ .exited = 3 }, result.term);
}

fn waitChild(io: Io, child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
    return child.wait(io);
}

test "a cancel ends a wait on a child that runs on" {
    var r: Runtime = undefined;
    try runtime(&r, 1);
    defer r.deinit();
    const io = r.io();
    var child = try std.process.spawn(io, .{ .argv = &.{ "cmd.exe", "/c", "ping -n 30 127.0.0.1 > nul" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    defer child.kill(io);
    var waiting = try io.concurrent(waitChild, .{ io, &child });
    try io.sleep(.fromMilliseconds(20), .awake);
    try testing.expectError(error.Canceled, waiting.cancel(io));
}

test "a 1 ms sleep on the precise timer" {
    var r: Runtime = undefined;
    try runtime(&r, 0);
    defer r.deinit();
    const io = r.io();
    var overshoot: [40]u64 = undefined;
    for (&overshoot) |*o| {
        const start = Io.Clock.awake.now(io);
        try io.sleep(.fromMilliseconds(1), .awake);
        const slept: u64 = @intCast(start.durationTo(Io.Clock.awake.now(io)).nanoseconds);
        try testing.expect(slept >= std.time.ns_per_ms);
        o.* = slept - std.time.ns_per_ms;
    }
    std.mem.sort(u64, &overshoot, {}, std.sort.asc(u64));
    std.debug.print("1 ms sleep overshoot on IOCP: p50 {d} us, p90 {d} us, max {d} us\n", .{ overshoot[20] / 1000, overshoot[36] / 1000, overshoot[39] / 1000 });
    // The port's own timeout would be a system tick, 15.6 ms.
    try testing.expect(overshoot[20] < 5 * std.time.ns_per_ms);
}

test "the loop alone on IOCP: a timer, a real-clock timer, a wake" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var l: Loop = undefined;
    try l.init(testing.allocator, .{});
    defer l.deinit(testing.allocator);
    const system = Io.Threaded.global_single_threaded.io();
    const now = Io.Clock.Timestamp.now(system, .awake);
    var timer: Loop.Op = .{ .kind = .{ .timer = now.addDuration(.{ .raw = .fromMilliseconds(2), .clock = .awake }) }, .user_data = 7 };
    try l.submit(&timer);
    const wall = Io.Clock.Timestamp.now(system, .real);
    var real: Loop.Op = .{ .kind = .{ .timer = wall.addDuration(.{ .raw = .fromMilliseconds(3), .clock = .real }) }, .user_data = 8 };
    try l.submit(&real);
    var out: [4]*Loop.Op = undefined;
    var seen: usize = 0;
    while (seen < 2) {
        _ = try l.run(.once);
        for (l.reap(&out)) |o| {
            try testing.expect(o.user_data == 7 or o.user_data == 8);
            seen += 1;
        }
    }
    const thread = try std.Thread.spawn(.{}, Loop.wake, .{&l});
    defer thread.join();
    try testing.expectEqual(@as(u32, 0), try l.run(.once));
}

test "a host's own port: the loop's entries handed back through complete" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const sys = @import("sys/windows.zig");
    const port = try sys.createPort();
    defer sys.close(port);
    var l: Loop = undefined;
    try l.init(testing.allocator, .{ .port = port });
    defer l.deinit(testing.allocator);
    // A socket pair made with std's own Io, then read through the loop.
    const system = Io.Threaded.global_single_threaded.io();
    const address: net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(system, .{ .reuse_address = true });
    defer server.deinit(system);
    var client = try server.socket.address.connect(system, .{ .mode = .stream });
    defer client.close(system);
    const accepted = try server.accept(system);
    var buffer: [8]u8 = undefined;
    var data: [1][]u8 = .{&buffer};
    var read: Loop.Op = .{ .kind = .{ .io = .{ .net_read = .{ .socket_handle = accepted.socket.handle, .data = &data } } } };
    try l.submit(&read);
    try testing.expectEqual(@as(u32, 0), try l.run(.nowait));
    try writeAll(system, client.socket.handle, "host");
    // The host's own wait: an entry of reactor's key, handed back.
    var entries: [4]Loop.PortEntry = undefined;
    const taken = try sys.remove(port, &entries, null);
    try testing.expectEqual(@as(usize, 1), taken.len);
    try testing.expectEqual(Loop.completionKey(), taken[0].key);
    try testing.expectEqual(@as(u32, 1), l.complete(taken));
    var out: [1]*Loop.Op = undefined;
    const done = l.reap(&out);
    try testing.expectEqual(@as(usize, 1), done.len);
    try testing.expectEqual(@as(usize, 4), (try (try done[0].result.io).net_read).data_len);
    // The socket was bound by the loop: closed through it.
    var close: Loop.Op = .{ .kind = .{ .close = accepted.socket.handle } };
    try l.submit(&close);
    try testing.expectEqual(@as(u32, 1), try l.run(.nowait));
}

/// A frame larger than a page: Windows probes it page by page
/// (`__chkstk`), each probe growing the stack by its guard page.
noinline fn largeFrame(seed: u8) u8 {
    var big: [64 << 10]u8 = undefined;
    @memset(&big, seed);
    std.mem.doNotOptimizeAway(&big);
    return big[big.len - 1] +% big[0];
}

noinline fn recurse(depth: u32) u32 {
    var pad: [512]u8 = undefined;
    @memset(&pad, @truncate(depth));
    std.mem.doNotOptimizeAway(&pad);
    if (depth == 0) return pad[0];
    return recurse(depth - 1) +% pad[511];
}

noinline fn walk(depth: u32) usize {
    if (depth > 0) return walk(depth - 1);
    var addresses: [32]usize = undefined;
    const trace = std.debug.captureCurrentStackTrace(.{}, &addresses);
    return trace.return_addresses.len;
}

fn onTaskStack(out: *[3]usize) void {
    out[0] = largeFrame(3);
    out[1] = recurse(200);
    out[2] = walk(4);
}

test "a task's stack on Windows: large frames, deep recursion, a stack walk" {
    var r: Runtime = undefined;
    try runtime(&r, 1);
    defer r.deinit();
    const io = r.io();
    var out: [3]usize = undefined;
    var f = try io.concurrent(onTaskStack, .{&out});
    f.await(io);
    try testing.expectEqual(@as(usize, 6), out[0]);
    // The walk sees the frames above it on the task's stack, and stops.
    try testing.expect(out[2] >= 5);
}
