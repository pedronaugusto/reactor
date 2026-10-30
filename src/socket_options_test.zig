//! Socket options through `net.connect`, `net.listen` and `net.setOptions`,
//! read back from the kernel, on std's `Io.Threaded` and on a runtime of
//! each backend the system has; a refusal named; a fixed local port shared
//! by `reuse_address`.
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const IpAddress = Io.net.IpAddress;

const reactor = @import("reactor.zig");
const net = reactor.net;
const sys = @import("sys/options.zig");

const small: reactor.Runtime.Options = .{ .max_tasks = 64, .stack_size = .fromRaw(256 << 10), .offload = .none };

const backends: []const reactor.Runtime.Backend = switch (builtin.os.tag) {
    .linux => &.{ .io_uring, .epoll },
    .windows => &.{.iocp},
    else => &.{.kqueue},
};

fn ms(n: i64) Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(n), .clock = .awake } };
}

const asked: net.SocketOptions = .{
    .nodelay = true,
    .keepalive = .{ .on = .{ .idle = .literal(30), .interval = .literal(5), .count = .literal(4) } },
    .send_buffer = .fromRaw(96 << 10),
    .receive_buffer = .fromRaw(96 << 10),
    // Windows has no traffic class to set (see `SocketOptions`).
    .traffic_class = if (builtin.os.tag == .windows) null else 0x20,
};

/// What `asked` reads back as on `handle`, all but the send buffer on a
/// Windows listener, which has none of its own (`net.send_buffer_when_connected`).
/// A buffer reads back at least its size: Linux doubles it.
fn expectAsked(handle: Io.net.Socket.Handle, role: enum { listener, connection }) !void {
    try testing.expect(try sys.get(handle, sys.nodelay) != 0);
    try testing.expect(try sys.get(handle, sys.keepalive) != 0);
    try testing.expectEqual(@as(c_int, 30), try sys.get(handle, sys.keep_idle));
    try testing.expectEqual(@as(c_int, 5), try sys.get(handle, sys.keep_interval));
    try testing.expectEqual(@as(c_int, 4), try sys.get(handle, sys.keep_count));
    if (role == .connection or !net.send_buffer_when_connected) try testing.expect(try sys.get(handle, sys.send_buffer) >= 96 << 10);
    try testing.expect(try sys.get(handle, sys.receive_buffer) >= 96 << 10);
    if (builtin.os.tag != .windows) try testing.expectEqual(@as(c_int, 0x20), try sys.get(handle, sys.tos));
}

/// A connect and a listen with every option, each read back; an accepted
/// connection given its own by `setOptions`.
fn everyOption(io: Io) !void {
    // Windows drops a listener's send buffer, so asking for one is refused.
    var listener_asks = asked;
    if (net.send_buffer_when_connected) {
        try testing.expectError(error.OptionUnsupported, net.listen(io, &.{ .ip4 = .loopback(0) }, .{ .socket = asked }));
        listener_asks.send_buffer = null;
    }
    var server = try net.listen(io, &.{ .ip4 = .loopback(0) }, .{ .reuse_address = true, .socket = listener_asks });
    defer server.deinit(io);
    try expectAsked(server.borrow().socket.handle, .listener);
    var connected = try net.connect(io, &server.borrow().socket.address, .{ .socket = asked, .timeout = ms(5000) });
    defer connected.stream.deinit(io);
    try expectAsked(connected.stream.borrow().socket.handle, .connection);
    try testing.expect(connected.stream.borrow().socket.address.getPort() != 0);
    const accepted = try server.borrowMut().accept(io);
    defer accepted.close(io);
    try net.setOptions(accepted.socket, .{ .nodelay = false, .keepalive = .off, .send_buffer = .fromRaw(96 << 10) });
    try testing.expectEqual(@as(c_int, 0), try sys.get(accepted.socket.handle, sys.nodelay));
    try testing.expectEqual(@as(c_int, 0), try sys.get(accepted.socket.handle, sys.keepalive));
    try testing.expect(try sys.get(accepted.socket.handle, sys.send_buffer) >= 96 << 10);
}

test "a connect and a listen set every option before they connect and listen, on Threaded" {
    try everyOption(testing.io);
}

test "a connect and a listen set every option before they connect and listen, on every backend" {
    for (backends) |backend| {
        var options = small;
        options.backend = backend;
        var r: reactor.Runtime = undefined;
        r.init(testing.allocator, options) catch |err| switch (err) {
            error.BackendUnavailable => continue,
            else => return err,
        };
        defer r.deinit();
        try r.start();
        var task = try r.io().concurrent(everyOption, .{r.io()});
        try task.await(r.io());
    }
}

test "IPv6 takes its traffic class as IPV6_TCLASS" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    var server = (IpAddress{ .ip6 = .loopback(0) }).listen(io, .{}) catch |err| switch (err) {
        error.AddressUnavailable, error.AddressFamilyUnsupported => return error.SkipZigTest,
        else => return err,
    };
    defer server.deinit(io);
    var connected = try net.connect(io, &server.socket.address, .{ .socket = .{ .traffic_class = 0x48 } });
    defer connected.stream.deinit(io);
    try testing.expectEqual(@as(c_int, 0x48), try sys.get(connected.stream.borrow().socket.handle, sys.tclass));
}

test "an option the system has none of is OptionUnsupported, and fails the connect" {
    const io = testing.io;
    var server = try (IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    defer server.deinit(io);
    const stream = try server.socket.address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    try testing.expectError(error.OptionUnsupported, sys.set(stream.socket.handle, .{ .level = sys.keepalive.?.level, .name = 0x7ff0 }, 1));
    if (builtin.os.tag == .windows) {
        try testing.expectError(error.OptionUnsupported, net.setOptions(stream.socket, .{ .traffic_class = 0x20 }));
        try testing.expectError(error.OptionUnsupported, net.connect(io, &server.socket.address, .{ .socket = .{ .traffic_class = 0x20 } }));
    }
}

test "a fixed local port binds twice with reuse_address, and is AddressUnavailable without it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // Windows shares a port only with SO_REUSEADDR set by each, and refuses a second active bind to one port and peer
    const io = testing.io;
    var first_server = try (IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    defer first_server.deinit(io);
    var second_server = try (IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    defer second_server.deinit(io);
    var first = try net.connect(io, &first_server.socket.address, .{ .local_address = .{ .ip4 = .loopback(0) }, .reuse_address = true });
    defer first.stream.deinit(io);
    const port = first.stream.borrow().socket.address.getPort();
    var local: IpAddress = .{ .ip4 = .loopback(port) };
    var second = try net.connect(io, &second_server.socket.address, .{ .local_address = local, .reuse_address = true });
    defer second.stream.deinit(io);
    try testing.expectEqual(port, second.stream.borrow().socket.address.getPort());
    local = .{ .ip4 = .loopback(port) };
    try testing.expectError(error.AddressUnavailable, net.connect(io, &second_server.socket.address, .{ .local_address = local }));
}

test "on Apple's systems a socket given its options never raises SIGPIPE, which an accepted one does not inherit" {
    if (sys.no_sigpipe == null) return error.SkipZigTest;
    const io = testing.io;
    var server = try (IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    defer server.deinit(io);
    var connected = try net.connect(io, &server.socket.address, .{ .socket = .{ .nodelay = true } });
    defer connected.stream.deinit(io);
    try testing.expect(try sys.get(connected.stream.borrow().socket.handle, sys.no_sigpipe) != 0);
    const accepted = try server.accept(io);
    defer accepted.close(io);
    try testing.expectEqual(@as(c_int, 0), try sys.get(accepted.socket.handle, sys.no_sigpipe));
    try net.setOptions(accepted.socket, .{});
    try testing.expect(try sys.get(accepted.socket.handle, sys.no_sigpipe) != 0);
}

test "a connect asking only for nodelay and keepalive goes through the Io's own connect, and one asking for a buffer does not" {
    const Counting = struct {
        var connects: std.atomic.Value(u32) = .init(0);
        fn connect(userdata: ?*anyopaque, address: *const IpAddress, options: IpAddress.ConnectOptions) IpAddress.ConnectError!Io.net.Socket {
            _ = userdata;
            _ = connects.fetchAdd(1, .monotonic);
            return testing.io.vtable.netConnectIp(testing.io.userdata, address, options);
        }
    };
    const Layer = @import("shakedown").Layer(u8, .{ .netConnectIp = Counting.connect });
    var layer: Layer = .init(testing.io, 0);
    const io = layer.io();
    var server = try (IpAddress{ .ip4 = .loopback(0) }).listen(testing.io, .{});
    defer server.deinit(testing.io);
    var light = try net.connect(io, &server.socket.address, .{ .socket = .{ .nodelay = true, .keepalive = .{ .on = .{ .idle = .literal(30) } } } });
    defer light.stream.deinit(testing.io);
    try testing.expectEqual(@as(u32, 1), Counting.connects.load(.monotonic));
    try testing.expect(try sys.get(light.stream.borrow().socket.handle, sys.nodelay) != 0);
    try testing.expectEqual(@as(c_int, 30), try sys.get(light.stream.borrow().socket.handle, sys.keep_idle));
    var buffered = try net.connect(io, &server.socket.address, .{ .socket = .{ .nodelay = true, .receive_buffer = .fromRaw(96 << 10) } });
    defer buffered.stream.deinit(testing.io);
    try testing.expectEqual(@as(u32, 1), Counting.connects.load(.monotonic));
}
