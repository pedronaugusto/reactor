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
    const connected = try net.connect(io, &listener.socket.address, .{ .timeout = ms(5000) });
    defer connected.stream.close(io);
    try testing.expect(connected.timeout_enforced);
    const plain = try net.connect(io, &listener.socket.address, .{});
    plain.stream.close(io);
}

test "connect with no task to spare runs unbounded and says so" {
    const io = testing.io;
    var listener = try (try IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var serial: Serial = .init(io, 0);
    const connected = try net.connect(serial.io(), &listener.socket.address, .{ .timeout = ms(5000) });
    defer connected.stream.close(io);
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
    try testing.expect(watch.fired.load(.acquire));
    // The socket is poisoned: the next operation reports the deadline.
    try testing.expectError(error.Timeout, deadlines.operate(io, &watch, read, .{ .clock = .awake, .raw = start.addDuration(.fromSeconds(60)) }));
}

test "the watching task ticks at a tenth of the shortest timeout, between a millisecond and a second" {
    try testing.expectEqual(@as(i96, std.time.ns_per_ms), net.Deadlines.init(.fromMilliseconds(2)).tick.nanoseconds);
    try testing.expectEqual(@as(i96, 3 * std.time.ns_per_s / 10), net.Deadlines.init(.fromSeconds(3)).tick.nanoseconds);
    try testing.expectEqual(@as(i96, std.time.ns_per_s), net.Deadlines.init(.fromSeconds(300)).tick.nanoseconds);
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
    const result = try net.connect(layer.io(), &listener.socket.address, .{ .timeout = ms(5000) });
    defer result.stream.close(testing.io);
    try testing.expect(!result.timeout_enforced);
}

test "connect binds its requested local endpoint" {
    const io = testing.io;
    var listener = try (try IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const result = try net.connect(io, &listener.socket.address, .{ .local_address = .{ .ip4 = .loopback(0) }, .timeout = ms(5000) });
    defer result.stream.close(io);
    try testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &result.stream.socket.address.ip4.bytes);
    try testing.expect(result.stream.socket.address.getPort() != 0);
}
