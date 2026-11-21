//! The networking extensions on std's `Io.Threaded` (their fallbacks) and
//! on shakedown's layers, which stand in for an `Io` with no task to spare
//! and a lookup with too many answers.
const builtin = @import("builtin");
const std = @import("std");
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
    var plain = try net.connect(io, &listener.socket.address, .{});
    plain.stream.deinit(io);
}

/// That `connect` refused with `ConcurrencyUnavailable`; a connection it
/// made is a failure, closed.
fn expectRefused(io: Io, result: anytype) !void {
    if (result) |made| {
        var connected = made;
        connected.stream.deinit(io);
        return error.TestUnexpectedResult;
    } else |err| try testing.expectEqual(@as(anyerror, error.ConcurrencyUnavailable), @as(anyerror, err));
}

test "connect with a timeout and no task to spare is refused before it starts, never run unbounded" {
    const io = testing.io;
    var listener = try (try IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var serial: Serial = .init(io, 0);
    try expectRefused(io, net.connect(serial.io(), &listener.socket.address, .{ .timeout = ms(5000) }));
    // With no timeout asked, nothing needs a task: it connects.
    var plain = try net.connect(serial.io(), &listener.socket.address, .{});
    plain.stream.deinit(io);
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
    try testing.expectError(error.NoAddressReturned, net.resolve(serial.io(), "127.0.0.1", 1, .{ .family = .ip6 }, &storage));
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

test "a deadline passed ends the operation and poisons its socket" {
    const io = testing.io;
    var listener = try (try IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const stream = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var watch: net.Deadlines.Watch = .init(stream.socket.handle);

    var buffer: [16]u8 = undefined;
    var data: [1][]u8 = .{&buffer};
    const read: Io.Operation = .{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &data } };
    // A read that never gets an answer ends at its deadline.
    const start = Io.Clock.awake.now(io);
    try testing.expectError(error.Timeout, net.Deadlines.operate(io, &watch, read, .{ .clock = .awake, .raw = start.addDuration(.fromMilliseconds(40)) }));
    try testing.expect(watch.fired.raised(.acquire));
    // The socket is poisoned: the next operation reports the deadline.
    try testing.expectError(error.Timeout, net.Deadlines.operate(io, &watch, read, .{ .clock = .awake, .raw = start.addDuration(.fromSeconds(60)) }));
}

test "a deadline with no task to run the operation in refuses it, and the operation never starts" {
    const base = testing.io;
    var layer: Serial = .init(base, 0);
    const io = layer.io();
    const sender = try (IpAddress{ .ip4 = .loopback(0) }).bind(base, .{ .mode = .dgram });
    defer sender.close(base);
    const receiver = try (IpAddress{ .ip4 = .loopback(0) }).bind(base, .{ .mode = .dgram });
    defer receiver.close(base);
    var watch: net.Deadlines.Watch = .init(sender.handle);
    var outgoing: [1]Io.net.OutgoingMessage = .{.{ .address = &receiver.address, .data_ptr = "never".ptr, .data_len = 5 }};
    const send: Io.Operation = .{ .net_send = .{ .socket_handle = sender.handle, .messages = &outgoing, .flags = .{} } };
    const later = Io.Clock.awake.now(base).addDuration(.fromSeconds(5));
    try testing.expectError(error.ConcurrencyUnavailable, net.Deadlines.operate(io, &watch, send, .{ .clock = .awake, .raw = later }));
    try testing.expect(!watch.fired.raised(.acquire));
    // Nothing was sent: the receiver's deadline ends its wait empty.
    var into: net.Deadlines.Watch = .init(receiver.handle);
    var message: Io.net.IncomingMessage = .init;
    var buffer: [16]u8 = undefined;
    const receive: Io.Operation = .{ .net_receive = .{ .socket_handle = receiver.handle, .message_buffer = (&message)[0..1], .data_buffer = &buffer, .flags = .{} } };
    try testing.expectError(error.Timeout, net.Deadlines.operate(base, &into, receive, .{ .clock = .awake, .raw = Io.Clock.awake.now(base).addDuration(.fromMilliseconds(50)) }));
}

test "a deadline ends a receive on a datagram socket no one sends to" {
    // A datagram socket has no connection a shutdown could end, so the
    // deadline ends the receive itself.
    const io = testing.io;
    const socket = try (IpAddress{ .ip4 = .loopback(0) }).bind(io, .{ .mode = .dgram });
    defer socket.close(io);
    var watch: net.Deadlines.Watch = .init(socket.handle);
    var message: Io.net.IncomingMessage = .init;
    var buffer: [64]u8 = undefined;
    const receive: Io.Operation = .{ .net_receive = .{ .socket_handle = socket.handle, .message_buffer = (&message)[0..1], .data_buffer = &buffer, .flags = .{} } };
    const start = Io.Clock.awake.now(io);
    try testing.expectError(error.Timeout, net.Deadlines.operate(io, &watch, receive, .{ .clock = .awake, .raw = start.addDuration(.fromMilliseconds(40)) }));
    try testing.expect(watch.fired.raised(.acquire));
    try testing.expect(start.durationTo(Io.Clock.awake.now(io)).nanoseconds < 5 * std.time.ns_per_s);
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

test "connect with a task for its timer and none for its attempt is refused" {
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
    try expectRefused(testing.io, net.connect(layer.io(), &listener.socket.address, .{ .timeout = ms(5000) }));
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
    // On POSIX from the working directory, where tmpDir made it, so the path
    // fits a socket address wherever the tree is. AFD takes an absolute
    // path, written with /, as git writes a socket path; Windows takes either.
    const root = if (builtin.os.tag == .windows) root: {
        const real = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        std.mem.replaceScalar(u8, real, '\\', '/');
        break :root real;
    } else try gpa.print(".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer gpa.free(root);
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

test "a Unix socket connect on the runtime reaches its listener and carries bytes, on Windows' IOCP over AFD too" {
    if (!Io.net.has_unix_sockets or !@import("Scheduler.zig").supported) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = if (builtin.os.tag == .windows) root: {
        const real = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
        std.mem.replaceScalar(u8, real, '\\', '/');
        break :root real;
    } else try gpa.print(".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer gpa.free(root);
    const path = try gpa.print("{s}/socket", .{root});
    defer gpa.free(path);
    const address = try Io.net.UnixAddress.init(path);
    var listener: UnixListener = try .open(testing.io, &address);
    defer listener.close(testing.io);
    // The system's own backend: IOCP over AFD on Windows, where the
    // connect binds its unnamed end through AFD before it connects.
    var r: reactor.Runtime = undefined;
    r.init(gpa, .{ .max_tasks = 64, .stack_size = .fromRaw(256 << 10) }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => |e| return e,
    };
    defer r.deinit();
    try r.start();
    const io = r.io();
    var stream = try net.connectUnix(io, &address);
    defer stream.deinit(io);
    var buffer: [16]u8 = undefined;
    var writer = stream.borrow().writer(io, &buffer);
    try writer.interface.writeAll("hello");
    try writer.interface.flush();
    var got: [5]u8 = undefined;
    try listener.read(testing.io, &got);
    try testing.expectEqualStrings("hello", &got);
}

test "connectUnix names a path past the system's socket address NameTooLong before std copies it, on Threaded too" {
    if (!Io.net.has_unix_sockets or builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    const room = @typeInfo(@FieldType(std.posix.sockaddr.un, "path")).array.len;
    // std's limit is Linux's 108 everywhere; macOS and the BSDs hold 104.
    const long: [room]u8 = @splat('a');
    try testing.expectError(error.NameTooLong, net.connectUnix(io, &try Io.net.UnixAddress.init(&long)));
    const over: [Io.net.UnixAddress.max_len]u8 = @splat('a');
    try testing.expectError(error.NameTooLong, net.connectUnix(io, &try Io.net.UnixAddress.init(&over)));
}
