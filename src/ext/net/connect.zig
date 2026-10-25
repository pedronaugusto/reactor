//! A connection with a timeout on any `Io`. A runtime keeps the timeout
//! itself: the connect is the kernel's, ended there at the deadline. Any
//! other `Io` races the connect, as a task of its own, against a sleep,
//! and cancels the loser; with no task to spare the connect runs on the
//! caller unbounded, and the result says so. (`Io.Threaded` cannot be
//! given the timeout itself: Zig 0.17's panics on one.)
const std = @import("std");
const builtin = @import("builtin");
const dial = @import("../../sys/dial.zig");
const sys_socket = @import("../../sys/socket.zig");
const afd = @import("../../sys/afd.zig");
const options_file = @import("options.zig");
const unix_windows = @import("../../sys/unix_windows.zig");
const Loop = @import("../../Loop.zig");
const Scheduler = @import("../../Scheduler.zig");
const perform = @import("../../ops/perform.zig");
const wait = @import("../wait.zig");
const Io = std.Io;
const net = Io.net;

const native = @import("../native.zig");
const Core = @import("../../runtime/Core.zig");

pub const Options = struct {
    mode: net.Socket.Mode = .stream,
    protocol: ?net.Protocol = null,
    timeout: Io.Timeout = .none,
    /// Bind the local endpoint before connecting.
    local_address: ?net.IpAddress = null,
    /// With `local_address`: let its port be shared (`SO_REUSEADDR`, and
    /// `SO_REUSEPORT` on POSIX, as std's `ListenOptions.reuse_address`),
    /// set before the bind, so a fixed port held in `TIME_WAIT` binds.
    reuse_address: bool = false,
    /// Restrict outgoing traffic to this interface.
    interface: net.Interface = .none,
    /// Socket options. The buffers and the traffic class are set before the
    /// connect, on a socket reactor makes, so the window scale and the
    /// class its first segment carries are the ones asked; `nodelay` and
    /// keepalive, which take effect from the first write, are set just
    /// after `io`'s own connect, so a wrapping `Io` keeps its connect. A
    /// refused one fails the connect, named, the socket closed.
    socket: options_file.Options = .{},
};

pub const Connected = struct {
    stream: net.Stream,
    /// False when a timeout was asked for and this `Io` could not keep it.
    timeout_enforced: bool = true,
};

/// `error.Timeout` when the timeout passed first.
pub const Error = net.IpAddress.ConnectError;

/// Whether the caller is one of `core`'s tasks, read as a call in.
fn onTask(core: *Core) bool {
    const entered = native.enter();
    defer native.leave(entered);
    return native.taskRuntime(core);
}

pub fn connect(io: Io, address: *const net.IpAddress, options: Options) Error!Connected {
    if (options.local_address != null or !options.interface.isNone() or options.reuse_address or options.socket.beforeConnect()) return made(io, address, options);
    const connected = try throughIo(io, address, options);
    if (options.socket.any()) options_file.setOptions(connected.stream.socket, options.socket) catch |err| {
        connected.stream.close(io);
        return err;
    };
    return connected;
}

/// A connection made by `io`'s own connect, with `options.timeout` kept as
/// this `Io` best can.
fn throughIo(io: Io, address: *const net.IpAddress, options: Options) Error!Connected {
    const plain: net.IpAddress.ConnectOptions = .{ .mode = options.mode, .protocol = options.protocol };
    if (options.timeout == .none) return .{ .stream = try address.connect(io, plain) };
    if (native.runtimeOf(io)) |core| if (onTask(core)) {
        var timed = plain;
        timed.timeout = options.timeout;
        return .{ .stream = try address.connect(io, timed) };
    };
    const deadline = options.timeout.toDeadline(io);
    const Race = union(enum) {
        connected: Error!net.Stream,
        expired: Io.Cancelable!void,
    };
    var buffer: [2]Race = undefined;
    var race: Io.Select(Race) = .init(io, &buffer);
    defer while (race.cancel()) |late| switch (late) {
        .connected => |result| if (result) |stream| stream.close(io) else |_| {},
        .expired => {},
    };
    race.concurrent(.connected, net.IpAddress.connect, .{ address, io, plain }) catch
        return .{ .stream = try address.connect(io, plain), .timeout_enforced = false };
    race.concurrent(.expired, Io.Timeout.sleep, .{ deadline, io }) catch {
        // The connect runs already: wait for it, unbounded.
        return switch (try race.await()) {
            .connected => |result| .{ .stream = try result, .timeout_enforced = false },
            .expired => unreachable, // unreachable: no timer task was started
        };
    };
    return switch (try race.await()) {
        .connected => |result| .{ .stream = try result },
        .expired => |result| expired: {
            try result;
            // A connection already made remains the caller's, even if the
            // timer's result reached the select first.
            while (race.cancel()) |late| switch (late) {
                .connected => |connected| if (connected) |stream| break :expired .{ .stream = stream } else |_| {},
                .expired => {},
            };
            break :expired error.Timeout;
        },
    };
}

/// A Unix stream socket connected to `address` on any `Io`, its errors
/// std's names for them everywhere: `ConnectionRefused` where nothing
/// listens at the path, `FileNotFound` where there is none. A runtime, and
/// every system but Windows, connects by `UnixAddress.connect`; on Windows
/// any other `Io` connects through Winsock (`sys/unix_windows.zig`), where
/// std 0.17's `Io.Threaded` drives AFD itself and the system refuses it.
/// The connect does not wait: a Unix socket is answered at once.
pub fn connectUnix(io: Io, address: *const net.UnixAddress) net.UnixAddress.ConnectError!net.Stream {
    if (builtin.os.tag != .windows or native.runtimeOf(io) != null) return address.connect(io);
    try io.checkCancel();
    const handle = try unix_windows.connectUnix(address);
    return .{ .socket = .{ .handle = handle, .address = .{ .ip4 = .loopback(0) } } };
}

/// The runtime `io` is, when the caller is one of its tasks and it has a
/// backend: its connect is the backend's.
fn runtimeTask(io: Io) ?*Core {
    const core = native.runtimeOf(io) orelse return null;
    const entered = native.enter();
    defer native.leave(entered);
    return if (native.taskRuntime(core) and core.backendKind() != null) core else null;
}

/// A connection on a socket reactor makes itself, for what has to come
/// before the connect: the options, the bind and the interface.
fn made(io: Io, address: *const net.IpAddress, options: Options) Error!Connected {
    if (options.local_address) |local| if (@as(net.IpAddress.Family, local) != @as(net.IpAddress.Family, address.*)) return error.AddressFamilyUnsupported;
    const core = runtimeTask(io);
    // A readiness backend connects in non-blocking mode, as any other `Io`
    // does here: a socket made in it is spared the switch there and back,
    // as the runtime's own connect makes it (`netConnectIp`).
    const start: sys_socket.Start = if (core) |c| (if (c.backendKind() == .epoll or c.backendKind() == .kqueue) .nonblocking else .blocking) else .nonblocking;
    const socket: net.Socket = .{ .handle = try open(address, options, start), .address = address.* };
    errdefer socket.close(io);
    try dial.interface(io, socket.handle, address.*, options.interface);
    if (core) |c| {
        const entered = native.enter();
        defer native.leave(entered);
        const p = Scheduler.processor().?;
        var op: Loop.Op = .{ .backend = .{ .kind = .{ .connect = .{ .socket = socket.handle, .address = .{ .ip = address.* }, .nonblocking = start == .nonblocking } } } };
        perform.run(&c.scheduler, &op, .{ .deadline = perform.deadline(p, options.timeout) }) catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            error.Timeout => error.Timeout,
            error.SystemResources => error.SystemResources,
        };
        op.backend.result.connect catch |err| return switch (err) {
            inline else => |e| narrow: {
                inline for (@typeInfo(Error).error_set.error_names.?) |name| if (comptime std.mem.eql(u8, name, @errorName(e))) break :narrow @field(Error, name);
                break :narrow error.Unexpected;
            },
        };
        // Where a send ignores `MSG_DONTWAIT` (Darwin) a readiness loop
        // writes only to sockets in non-blocking mode: it stays so.
        if (start == .nonblocking and sys_socket.send_honors_dontwait) try sys_socket.setBlocking(socket.handle);
        return .{ .stream = .{ .socket = .{ .handle = socket.handle, .address = try dial.local(io, socket.handle) } } };
    }
    if (builtin.os.tag == .windows) {
        const Race = union(enum) { connected: Error!void, expired: Io.Cancelable!void };
        var buffer: [2]Race = undefined;
        var race: Io.Select(Race) = .init(io, &buffer);
        defer while (race.cancel()) |_| {};
        race.concurrent(.connected, dial.windowsConnect, .{ io, socket.handle, address }) catch {
            try dial.windowsConnect(io, socket.handle, address);
            return .{ .stream = .{ .socket = .{ .handle = socket.handle, .address = try dial.local(io, socket.handle) } }, .timeout_enforced = options.timeout == .none };
        };
        if (options.timeout != .none) race.concurrent(.expired, Io.Timeout.sleep, .{ options.timeout.toDeadline(io), io }) catch {
            const outcome = try race.await();
            try outcome.connected;
            return .{ .stream = .{ .socket = .{ .handle = socket.handle, .address = try dial.local(io, socket.handle) } }, .timeout_enforced = false };
        };
        switch (try race.await()) {
            .connected => |result| try result,
            .expired => |result| {
                try result;
                while (race.cancel()) |late| switch (late) {
                    .connected => |connected| if (connected) |_| return .{ .stream = .{ .socket = .{ .handle = socket.handle, .address = try dial.local(io, socket.handle) } } } else |_| {},
                    .expired => {},
                };
                return error.Timeout;
            },
        }
    } else {
        if (!try dial.start(socket.handle, address)) {
            wait.wait(io, .{ .writable = socket.handle }, options.timeout) catch |err| return switch (err) {
                error.Canceled => error.Canceled,
                error.Timeout => error.Timeout,
                else => error.Unexpected,
            };
            try dial.finish(socket.handle);
        }
        try sys_socket.setBlocking(socket.handle);
    }
    return .{ .stream = .{ .socket = .{ .handle = socket.handle, .address = try dial.local(io, socket.handle) } } };
}

/// A socket for a connection to `peer`, its options set and its local end
/// bound as `options` ask, not yet connected. On POSIX a socket with no
/// local end asked for is not bound: a bind to port 0 takes a port unique
/// across every destination, and many connections run the ephemeral range
/// out, where a connect picks its port per destination. AFD binds a socket
/// before it connects, as std binds it.
fn open(peer: *const net.IpAddress, options: Options, start: sys_socket.Start) Error!net.Socket.Handle {
    const family = Io.Threaded.posixAddressFamily(peer);
    if (builtin.os.tag == .windows) if (options.local_address) |*local| {
        const handle = try afd.open(family, options.mode, options.protocol);
        errdefer sys_socket.close(handle);
        try prepare(handle, peer.*, options);
        _ = afd.bind(handle, local, .Active) catch |err| return switch (err) {
            error.AddressInUse => error.AddressUnavailable,
            else => |e| e,
        };
        return handle;
    };
    const handle = try sys_socket.open(family, options.mode, options.protocol, start);
    errdefer sys_socket.close(handle);
    try prepare(handle, peer.*, options);
    if (builtin.os.tag != .windows) if (options.local_address) |*local| try dial.bind(handle, local);
    return handle;
}

/// What is set before the bind: the port's sharing and the options.
fn prepare(handle: net.Socket.Handle, peer: net.IpAddress, options: Options) Error!void {
    if (options.reuse_address) try options_file.reuse(handle);
    try options_file.apply(handle, peer, options.socket);
}

test "a socket made for its options alone is not bound before its connect" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // AFD binds every socket before it connects
    const peer: net.IpAddress = .{ .ip4 = .loopback(9) };
    const handle = try open(&peer, .{ .socket = .{ .nodelay = true } }, .blocking);
    defer sys_socket.close(handle);
    try std.testing.expectEqual(@as(u16, 0), (try sys_socket.localAddress(handle)).getPort());
    const bound = try open(&peer, .{ .socket = .{ .nodelay = true }, .local_address = .{ .ip4 = .loopback(0) } }, .blocking);
    defer sys_socket.close(bound);
    try std.testing.expect((try sys_socket.localAddress(bound)).getPort() != 0);
}
