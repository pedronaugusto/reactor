//! The networking extensions on std's `Io.Threaded` (their fallbacks) and
//! on shakedown's layers, which stand in for an `Io` with no task to spare
//! and a lookup with too many answers.
const builtin = @import("builtin");
const std = @import("std");
const timeline = @import("clock.zig");
const testing = std.testing;
const Io = std.Io;
const IpAddress = Io.net.IpAddress;
const shakedown = @import("shakedown");

const reactor = @import("reactor.zig");
const net = reactor.net;

fn ms(n: i64) Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(n), .clock = .awake } };
}

/// An `Io` with no task to spare.
const Serial = shakedown.Layer(u8, .{
    .concurrent = struct {
        fn concurrent(_: ?*anyopaque, _: usize, _: std.mem.Alignment, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque, *anyopaque) void) Io.ConcurrentError!*Io.AnyFuture {
            return error.ConcurrencyUnavailable;
        }
    }.concurrent,
    .groupConcurrent = struct {
        fn groupConcurrent(_: ?*anyopaque, _: *Io.Group, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque) void) Io.ConcurrentError!void {
            return error.ConcurrencyUnavailable;
        }
    }.groupConcurrent,
});

// connect

test "connect with a timeout on Threaded connects, the timeout kept by a racing task" {
    const io = testing.io;
    var listener = try (try IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var connected = try net.connect(io, &listener.socket.address, .{ .timeout = ms(5000) });
    defer connected.stream.deinit(io);
    try testing.expect(connected.timeout_enforced);
    var plain = try net.connect(io, &listener.socket.address, .{});
    plain.stream.deinit(io);
}

test "connect with no task to spare runs unbounded and says so" {
    const io = testing.io;
    var listener = try (try IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var serial: Serial = .init(io, 0);
    var connected = try net.connect(serial.io(), &listener.socket.address, .{ .timeout = ms(5000) });
    defer connected.stream.deinit(io);
    try testing.expect(!connected.timeout_enforced);
}

test "a connect that hangs ends at its deadline, and the attempt is cancelled" {
    const Hang = struct {
        var connecting: Io.Event = .unset;
        var canceled: std.atomic.Value(bool) = .init(false);
        fn connect(_: ?*anyopaque, _: *const IpAddress, _: IpAddress.ConnectOptions) IpAddress.ConnectError!Io.net.Socket {
            connecting.set(testing.io);
            var never: Io.Event = .unset;
            never.wait(testing.io) catch |err| {
                canceled.store(true, .release);
                return err;
            };
            unreachable; // unreachable: nothing sets `never`
        }
    };
    const Hanging = shakedown.Layer(u8, .{ .netConnectIp = Hang.connect });
    var clock: shakedown.Clock = .init(testing.io, .{});
    var hanging: Hanging = .init(clock.io(), 0);
    const Run = struct {
        fn run(io: Io, out: *net.ConnectError!net.Connected) void {
            const address: IpAddress = .{ .ip4 = .loopback(1) };
            out.* = net.connect(io, &address, .{ .timeout = .{ .duration = .{ .raw = .fromMilliseconds(200), .clock = .awake } } });
        }
    };
    var result: net.ConnectError!net.Connected = undefined;
    var task = testing.io.concurrent(Run.run, .{ hanging.io(), &result }) catch return error.SkipZigTest;
    defer task.cancel(testing.io);
    try Hang.connecting.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    try clock.awaitArmed(1, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    clock.advance(.fromMilliseconds(199));
    try testing.expect(!Hang.canceled.load(.acquire));
    clock.advance(.fromMilliseconds(1));
    task.await(testing.io);
    try testing.expectError(error.Timeout, result);
    try testing.expect(Hang.canceled.load(.acquire));
}

// resolve

/// Puts a hundred addresses one at a time, as std's libc lookup puts what
/// `getaddrinfo` answered.
fn answerMany(results: *Io.Queue(Io.net.HostName.LookupResult), options: Io.net.HostName.LookupOptions) Io.net.HostName.LookupError!void {
    const io = testing.io;
    defer results.close(io);
    for (0..100) |i| {
        results.putOne(io, .{ .address = .{ .ip4 = .{ .bytes = .{ 10, 0, 0, @intCast(i) }, .port = options.port } } }) catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            error.Closed => unreachable, // unreachable: the queue is closed only by this function
        };
    }
}

const ManyAnswers = shakedown.Layer(u8, .{ .netLookup = struct {
    fn lookup(_: ?*anyopaque, _: Io.net.HostName, results: *Io.Queue(Io.net.HostName.LookupResult), options: Io.net.HostName.LookupOptions) Io.net.HostName.LookupError!void {
        return answerMany(results, options);
    }
}.lookup });

const SerialMany = shakedown.Layer(u8, .{
    .concurrent = struct {
        fn concurrent(_: ?*anyopaque, _: usize, _: std.mem.Alignment, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque, *anyopaque) void) Io.ConcurrentError!*Io.AnyFuture {
            return error.ConcurrencyUnavailable;
        }
    }.concurrent,
    .netLookup = struct {
        fn lookup(_: ?*anyopaque, _: Io.net.HostName, results: *Io.Queue(Io.net.HostName.LookupResult), options: Io.net.HostName.LookupOptions) Io.net.HostName.LookupError!void {
            return answerMany(results, options);
        }
    }.lookup,
});

test "a name with more addresses than a lookup queue holds resolves without waiting on itself" {
    var many: ManyAnswers = .init(testing.io, 0);
    var storage: [32]IpAddress = undefined;
    const kept = net.resolve(many.io(), "many.example", 80, .{}, &storage) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
        else => |e| return e,
    };
    try testing.expectEqual(storage.len, kept.len);
    try testing.expectEqualSlices(u8, &.{ 10, 0, 0, 0 }, &kept[0].ip4.bytes);

    // Without a task, libc's lookup on this one, or none at all: std's run
    // inline would fill its queue and wait forever.
    var serial: SerialMany = .init(testing.io, 0);
    if (builtin.link_libc and builtin.os.tag != .windows) {
        const local = try net.resolve(serial.io(), "localhost", 80, .{}, &storage);
        try testing.expectEqual(@as(u16, 80), local[0].getPort());
    } else {
        try testing.expectError(error.ConcurrencyUnavailable, net.resolve(serial.io(), "localhost", 80, .{}, &storage));
    }
    // An address needs no lookup and no task.
    const address = try net.resolve(serial.io(), "[::1]", 443, .{}, &storage);
    try testing.expectEqual(@as(u16, 443), address[0].getPort());
    try testing.expectError(error.NameNotResolved, net.resolve(serial.io(), "127.0.0.1", 1, .{ .family = .ip6 }, &storage));
    try testing.expectError(error.InvalidHostName, net.resolve(many.io(), "bad name", 1, .{}, &storage));
}

test "a family asked for is kept even where the resolver answers both" {
    const Mixed = shakedown.Layer(u8, .{ .netLookup = struct {
        fn lookup(_: ?*anyopaque, _: Io.net.HostName, results: *Io.Queue(Io.net.HostName.LookupResult), options: Io.net.HostName.LookupOptions) Io.net.HostName.LookupError!void {
            const io = testing.io;
            defer results.close(io);
            const answers: []const Io.net.HostName.LookupResult = &.{
                .{ .address = .{ .ip6 = .{ .bytes = @as([15]u8, @splat(0)) ++ .{1}, .port = options.port } } },
                .{ .address = .{ .ip4 = .loopback(options.port) } },
            };
            results.putAll(io, answers) catch return error.Canceled;
        }
    }.lookup });
    var mixed: Mixed = .init(testing.io, 0);
    var storage: [4]IpAddress = undefined;
    const four = net.resolve(mixed.io(), "dual.example", 80, .{ .family = .ip4 }, &storage) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
        else => |e| return e,
    };
    try testing.expectEqual(@as(usize, 1), four.len);
    try testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &four[0].ip4.bytes);
}

test "a host that is an address is one, IPv6 brackets allowed, and a name is not" {
    try testing.expectEqual(@as(u16, 443), net.literal("[::1]", 443).?.getPort());
    try testing.expectEqualSlices(u8, &.{ 10, 0, 0, 7 }, &net.literal("10.0.0.7", 80).?.ip4.bytes);
    try testing.expectEqual(@as(?IpAddress, null), net.literal("example.test", 80));
    try testing.expectEqual(@as(?IpAddress, null), net.literal("[example.test]", 80));
}

// Deadlines

test "a timed read over an Io without concurrent batches drains its fallback" {
    const BatchesUnavailable = shakedown.Layer(u8, .{
        .batchAwaitConcurrent = struct {
            fn awaitBatch(_: ?*anyopaque, _: *Io.Batch, _: Io.Timeout) Io.Batch.AwaitConcurrentError!void {
                return error.ConcurrencyUnavailable;
            }
        }.awaitBatch,
    });
    const base = testing.io;
    var layer: BatchesUnavailable = .init(base, 0);
    const io = layer.io();
    var listener = try (IpAddress{ .ip4 = .loopback(0) }).listen(base, .{});
    defer listener.deinit(base);
    const client = try listener.socket.address.connect(base, .{ .mode = .stream });
    defer client.close(base);
    const server = try listener.accept(base);
    defer server.close(base);
    var out = [_][]const u8{"bounded"};
    _ = try (try base.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &out } })).net_write;
    var buffer: [32]u8 = @splat(0xa5);
    var data = [_][]u8{&buffer};
    const read: Io.Operation = .{ .net_read = .{ .socket_handle = server.socket.handle, .data = &data } };
    const timed = @import("ops/timeout.zig");
    const received = try (try timed.operate(io, read, ms(5000))).net_read;
    try testing.expectEqualStrings("bounded", buffer[0..received.data_len]);
    try testing.expectError(error.Timeout, timed.operate(io, read, ms(10)));
    // Every read ended before the borrowed buffer can be overwritten.
    @memset(&buffer, 0xa5);
    try base.sleep(.fromMilliseconds(20), .awake);
    for (buffer) |byte| try testing.expectEqual(@as(u8, 0xa5), byte);
}

test "a deadline passed aborts the operation's socket, and one disarmed in time does not" {
    const io = testing.io;
    var listener = try (try IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const stream = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var deadlines: net.Deadlines = .init(.fromMilliseconds(20));
    defer deadlines.deinit(io);
    var watch: net.Deadlines.Watch = .init(stream.socket.handle);
    if (!deadlines.add(io, &watch)) return error.SkipZigTest;
    defer deadlines.remove(io, &watch);

    var buffer: [16]u8 = undefined;
    var data: [1][]u8 = .{&buffer};
    const read: Io.Operation = .{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &data } };
    // A read that never gets an answer ends at its deadline.
    const start = Io.Clock.awake.now(io);
    try testing.expectError(error.Timeout, deadlines.operate(io, &watch, read, .{ .clock = .awake, .raw = start.addDuration(.fromMilliseconds(40)) }));
    try testing.expect(watch.fired.raised(.acquire));
    // The socket is poisoned: the next operation reports the deadline.
    try testing.expectError(error.Timeout, deadlines.operate(io, &watch, read, .{ .clock = .awake, .raw = start.addDuration(.fromSeconds(60)) }));
}

test "the watching task ticks at a tenth of the shortest timeout, between a millisecond and a second" {
    try testing.expectEqual(timeline.Span.literal("1ms"), net.Deadlines.init(.fromMilliseconds(2)).tick.load(.monotonic));
    try testing.expectEqual(timeline.Span.literal("300ms"), net.Deadlines.init(.fromSeconds(3)).tick.load(.monotonic));
    try testing.expectEqual(timeline.Span.literal("1s"), net.Deadlines.init(.fromSeconds(300)).tick.load(.monotonic));
}

test "tighten only shortens the tick, and wakes the task that waits out a longer one" {
    const io = testing.io;
    var deadlines: net.Deadlines = .init(.fromSeconds(300));
    defer deadlines.deinit(io);
    deadlines.tighten(io, .fromMilliseconds(50));
    try testing.expectEqual(timeline.Span.literal("5ms"), deadlines.tick.load(.monotonic));
    deadlines.tighten(io, .fromSeconds(5));
    try testing.expectEqual(timeline.Span.literal("5ms"), deadlines.tick.load(.monotonic));

    // A task that has waited out one second between looks ends an operation
    // within a few ticks of the shorter deadline asked for afterwards.
    var listener = try (try IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const stream = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var slow: net.Deadlines = .init(.fromSeconds(300));
    defer slow.deinit(io);
    var watch: net.Deadlines.Watch = .init(stream.socket.handle);
    if (!slow.add(io, &watch)) return error.SkipZigTest;
    defer slow.remove(io, &watch);
    var buffer: [16]u8 = undefined;
    var data: [1][]u8 = .{&buffer};
    const read: Io.Operation = .{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &data } };
    const start = Io.Clock.awake.now(io);
    slow.tighten(io, .fromMilliseconds(50));
    try testing.expectError(error.Timeout, slow.operate(io, &watch, read, .{ .clock = .awake, .raw = start.addDuration(.fromMilliseconds(60)) }));
    try testing.expect(start.durationTo(Io.Clock.awake.now(io)).nanoseconds < 500 * std.time.ns_per_ms);
}

// abort

fn readOne(io: Io, socket: Io.net.Socket.Handle) !usize {
    var buffer: [16]u8 = undefined;
    var data: [1][]u8 = .{&buffer};
    const result = try io.operate(.{ .net_read = .{ .socket_handle = socket, .data = &data } });
    return (try result.net_read).data_len;
}

test "abort ends a read another task waits in" {
    const io = testing.io;
    var listener = try (try IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const stream = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var reading = io.concurrent(readOne, .{ io, stream.socket.handle }) catch return error.SkipZigTest;
    try io.sleep(.fromMilliseconds(10), .awake);
    net.abort(io, stream.socket.handle);
    // End of stream, or an error: either way, not waiting.
    if (reading.await(io)) |n| try testing.expectEqual(@as(usize, 0), n) else |_| {}
}

// Receiver

test "a receiver holds no buffer while idle and lends one per read" {
    const io = testing.io;
    var listener = try (try IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const client = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    const server = try listener.accept(io);
    defer server.close(io);

    var pool: net.Receiver.Pool = try .init(testing.allocator, io, .{ .buffer_len = .fromRaw(64), .buffers = 1 });
    defer pool.deinit(testing.allocator, io);
    var receiver: net.Receiver = .init(io, &pool, server.socket.handle);
    defer receiver.deinit(io);

    try testing.expectError(error.Timeout, receiver.next(io, ms(10)));
    var out: [16]u8 = undefined;
    var writer = client.writer(io, &out);
    try writer.interface.writeAll("pooled");
    try writer.interface.flush();
    const got = try receiver.next(io, ms(5000));
    try testing.expectEqualStrings("pooled", got);
    // The pool's one buffer is lent: another receiver with data waiting
    // finds none.
    var other: net.Receiver = .init(io, &pool, client.socket.handle);
    defer other.deinit(io);
    var back: [16]u8 = undefined;
    var server_writer = server.writer(io, &back);
    try server_writer.interface.writeAll("x");
    try server_writer.interface.flush();
    try testing.expectError(error.SystemResources, other.next(io, ms(5000)));
    receiver.release(got);
    const x = try other.next(io, ms(5000));
    try testing.expectEqualStrings("x", x);
    other.release(x);
    try writer.interface.writeAll("again");
    try writer.interface.flush();
    try testing.expectEqualStrings("again", try receiver.next(io, ms(5000)));
    // End of stream once the peer shuts its side.
    try client.shutdown(io, .send);
    try testing.expectError(error.EndOfStream, receiver.next(io, ms(5000)));
}

test "connect keeps a successful attempt when no task can run its timer" {
    const OneTask = struct {
        var attempts: std.atomic.Value(u32) = .init(0);
        fn concurrent(_: ?*anyopaque, group: *Io.Group, context: []const u8, alignment: std.mem.Alignment, start: *const fn (*const anyopaque) void) Io.ConcurrentError!void {
            if (attempts.fetchAdd(1, .monotonic) != 0) return error.ConcurrencyUnavailable;
            const base = testing.io;
            return base.vtable.groupConcurrent(base.userdata, group, context, alignment, start);
        }
    };
    const OnlyConnect = shakedown.Layer(u8, .{ .groupConcurrent = OneTask.concurrent });
    var layer: OnlyConnect = .init(testing.io, 0);
    var listener = try (try IpAddress.parse("127.0.0.1", 0)).listen(testing.io, .{ .reuse_address = true });
    defer listener.deinit(testing.io);
    var result = try net.connect(layer.io(), &listener.socket.address, .{ .timeout = ms(5000) });
    defer result.stream.deinit(testing.io);
    try testing.expect(!result.timeout_enforced);
}

test "connect binds its requested local endpoint" {
    const io = testing.io;
    var listener = try (try IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var result = try net.connect(io, &listener.socket.address, .{ .local_address = .{ .ip4 = .loopback(0) }, .timeout = ms(5000) });
    defer result.stream.deinit(io);
    try testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &result.stream.borrow().socket.address.ip4.bytes);
    try testing.expect(result.stream.borrow().socket.address.getPort() != 0);
}

/// A Unix listener: std's on POSIX; on Windows Winsock's, as Git for
/// Windows' daemons listen (std 0.17's Windows listen drives AFD itself,
/// which the system refuses in a process that has not used AF_UNIX through
/// Winsock).
const UnixListener = if (builtin.os.tag == .windows) struct {
    handle: Socket,

    const Socket = std.os.windows.HANDLE;
    const ws2_32 = std.os.windows.ws2_32;
    extern "ws2_32" fn WSAStartup(version: u16, data: *anyopaque) callconv(.winapi) c_int;
    extern "ws2_32" fn socket(family: c_int, kind: c_int, protocol: c_int) callconv(.winapi) Socket;
    extern "ws2_32" fn bind(s: Socket, name: *const anyopaque, len: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn listen(s: Socket, backlog: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn accept(s: Socket, name: ?*anyopaque, len: ?*c_int) callconv(.winapi) Socket;
    extern "ws2_32" fn recv(s: Socket, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn closesocket(s: Socket) callconv(.winapi) c_int;

    fn open(_: Io, address: *const Io.net.UnixAddress) !@This() {
        var data: [512]u8 align(8) = undefined;
        if (WSAStartup(0x202, &data) != 0) return error.SystemResources;
        const handle = socket(ws2_32.AF.UNIX, ws2_32.SOCK.STREAM, 0);
        if (@intFromPtr(handle) == std.math.maxInt(usize)) return error.Unexpected;
        errdefer _ = closesocket(handle);
        var name: ws2_32.sockaddr.un = .{ .path = @splat(0) };
        @memcpy(name.path[0..address.path.len], address.path);
        const len: c_int = @intCast(@offsetOf(ws2_32.sockaddr.un, "path") + address.path.len + 1);
        if (bind(handle, &name, len) != 0 or listen(handle, 4) != 0) return error.Unexpected;
        return .{ .handle = handle };
    }

    /// The first connection's first `out.len` bytes.
    fn read(l: *@This(), _: Io, out: []u8) !void {
        const peer = accept(l.handle, null, null);
        if (@intFromPtr(peer) == std.math.maxInt(usize)) return error.Unexpected;
        defer _ = closesocket(peer);
        var n: usize = 0;
        while (n < out.len) {
            const got = recv(peer, out[n..].ptr, @intCast(out.len - n), 0);
            if (got <= 0) return error.EndOfStream;
            n += @intCast(got);
        }
    }

    fn close(l: *@This(), _: Io) void {
        _ = closesocket(l.handle);
    }
} else struct {
    server: Io.net.Server,

    fn open(io: Io, address: *const Io.net.UnixAddress) !@This() {
        return .{ .server = try address.listen(io, .{}) };
    }

    /// The first connection's first `out.len` bytes.
    fn read(l: *@This(), io: Io, out: []u8) !void {
        const stream = try l.server.accept(io);
        defer stream.close(io);
        var buffer: [16]u8 = undefined;
        var reader = stream.reader(io, &buffer);
        try reader.interface.readSliceAll(out);
    }

    fn close(l: *@This(), io: Io) void {
        l.server.deinit(io);
    }
};

test "connectUnix reaches a listener, and names a refused connect and a missing path as std does, on Threaded too" {
    if (!Io.net.has_unix_sockets) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    // Written with /, as git writes a socket path; Windows takes either.
    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, root, '\\', '/');
    const path = try gpa.print("{s}/socket", .{root});
    defer gpa.free(path);
    const address = try Io.net.UnixAddress.init(path);
    // No path: a missing file on POSIX; Windows answers it as refused.
    var refused = net.connectUnix(io, &address);
    if (refused) |*stream| {
        stream.deinit(io);
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.FileNotFound => {},
        error.ConnectionRefused => if (builtin.os.tag != .windows) return err,
        else => return err,
    }
    // A directory not there on the way.
    const nowhere_path = try gpa.print("{s}/nowhere/socket", .{root});
    defer gpa.free(nowhere_path);
    const nowhere = try Io.net.UnixAddress.init(nowhere_path);
    try testing.expectError(error.FileNotFound, net.connectUnix(io, &nowhere));
    {
        var listener: UnixListener = try .open(io, &address);
        defer listener.close(io);
        var stream = try net.connectUnix(io, &address);
        defer stream.deinit(io);
        var buffer: [16]u8 = undefined;
        var writer = stream.borrow().writer(io, &buffer);
        try writer.interface.writeAll("hello");
        try writer.interface.flush();
        var got: [5]u8 = undefined;
        try listener.read(io, &got);
        try testing.expectEqualStrings("hello", &got);
    }
    // The path a listener left behind, with nothing listening at it.
    try testing.expectError(error.ConnectionRefused, net.connectUnix(io, &address));
}
