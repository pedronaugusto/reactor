//! The raw calls around a bound connection. Network policy stays in the
//! caller; these only bind an interface and finish a nonblocking connect.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const net = Io.net;

pub const Error = net.IpAddress.ConnectError;

pub fn interface(io: Io, socket: net.Socket.Handle, family: net.IpAddress.Family, selected: net.Interface) Error!void {
    if (selected.isNone()) return;
    if (builtin.os.tag == .linux) {
        const name = selected.name(io) catch return error.AddressUnavailable;
        return option(io, socket, posix.SOL.SOCKET, posix.SO.BINDTODEVICE, name.toSlice());
    }
    const index: u32 = if (builtin.os.tag == .windows and family == .ip4) std.mem.nativeToBig(u32, selected.index) else selected.index;
    const code: u32 = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => if (family == .ip4) 25 else 125,
        .windows => 31, // IP_UNICAST_IF / IPV6_UNICAST_IF
        else => return error.OptionUnsupported,
    };
    return option(io, socket, if (family == .ip4) 0 else 41, code, std.mem.asBytes(&index));
}

fn option(io: Io, socket: net.Socket.Handle, level: i32, code: u32, bytes: []const u8) Error!void {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const info: windows.AFD.SOCKOPT_INFO = .{ .mode = .set, .level = level, .optname = code, .optval = bytes.ptr, .optlen = bytes.len };
        const result = try io.operate(.{ .device_io_control = .{ .file = .{ .handle = socket, .flags = .{ .nonblocking = true } }, .code = windows.IOCTL.AFD.SOCKOPT, .in = std.mem.asBytes(&info), .out = &.{} } });
        return if (result.device_io_control.u.Status == .SUCCESS) {} else error.OptionUnsupported;
    }
    while (true) switch (posix.errno(posix.system.setsockopt(socket, level, code, bytes.ptr, @intCast(bytes.len)))) {
        .SUCCESS => return,
        .INTR => continue,
        .ACCES, .PERM => return error.AccessDenied,
        .NODEV => return error.AddressUnavailable,
        else => return error.OptionUnsupported,
    };
}

/// Changes only O_NONBLOCK, preserving all other status flags.
pub fn nonblocking(socket: net.Socket.Handle, enabled: bool) Error!void {
    if (builtin.os.tag == .windows) return;
    const old = while (true) {
        const result = posix.system.fcntl(socket, posix.F.GETFL, @as(usize, 0));
        switch (posix.errno(result)) {
            .SUCCESS => break result,
            .INTR => continue,
            else => return error.Unexpected,
        }
    };
    const bit: usize = 1 << @bitOffsetOf(posix.O, "NONBLOCK");
    const flags = if (enabled) @as(usize, @intCast(old)) | bit else @as(usize, @intCast(old)) & ~bit;
    while (true) switch (posix.errno(posix.system.fcntl(socket, posix.F.SETFL, flags))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.Unexpected,
    };
}

/// True if connected now; false if the writable wait must finish it.
pub fn start(socket: net.Socket.Handle, address: *const net.IpAddress) Error!bool {
    var storage: Io.Threaded.PosixAddress = undefined;
    const len = Io.Threaded.addressToPosix(address, &storage);
    return switch (posix.errno(posix.system.connect(socket, &storage.any, len))) {
        .SUCCESS => true,
        .INPROGRESS, .INTR, .AGAIN => false,
        else => |err| map(err),
    };
}

pub fn finish(socket: net.Socket.Handle) Error!void {
    var value: i32 = 0;
    var len: posix.socklen_t = @sizeOf(i32);
    while (true) switch (posix.errno(posix.system.getsockopt(socket, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&value), &len))) { // safe: SO_ERROR writes one int
        .SUCCESS => break,
        .INTR => continue,
        else => return error.Unexpected,
    };
    if (value != 0) return map(@fromBackingInt(@as(u16, @intCast(value))));
}

fn map(err: posix.E) Error {
    return switch (err) {
        .ADDRNOTAVAIL => error.AddressUnavailable,
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        .ALREADY => error.ConnectionPending,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .HOSTUNREACH => error.HostUnreachable,
        .NETUNREACH => error.NetworkUnreachable,
        .TIMEDOUT => error.Timeout,
        .ACCES, .PERM => error.AccessDenied,
        .NETDOWN => error.NetworkDown,
        else => error.Unexpected,
    };
}

/// AFD's bound connect; std's device-control cancellation ends it.
pub fn windowsConnect(io: Io, socket: net.Socket.Handle, address: *const net.IpAddress) Error!void {
    const windows = std.os.windows;
    var request: extern struct { reserved: [3]usize = @splat(0), address: Io.Threaded.PosixAddress } = .{ .address = undefined };
    const len = Io.Threaded.addressToPosix(address, &request.address);
    const bytes = std.mem.asBytes(&request)[0 .. @offsetOf(@TypeOf(request), "address") + len];
    const result = try io.operate(.{ .device_io_control = .{ .file = .{ .handle = socket, .flags = .{ .nonblocking = true } }, .code = windows.IOCTL.AFD.CONNECT, .in = bytes, .out = &.{} } });
    return switch (result.device_io_control.u.Status) {
        .SUCCESS => {},
        .CONNECTION_REFUSED => error.ConnectionRefused,
        .CANCELLED => error.Canceled,
        .INSUFFICIENT_RESOURCES, .NO_MEMORY => error.SystemResources,
        else => error.Unexpected,
    };
}

pub fn local(io: Io, socket: net.Socket.Handle) Error!net.IpAddress {
    var address: Io.Threaded.PosixAddress = undefined;
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const result = try io.operate(.{ .device_io_control = .{ .file = .{ .handle = socket, .flags = .{ .nonblocking = true } }, .code = windows.IOCTL.AFD.GET_ADDRESS, .in = &.{}, .out = std.mem.asBytes(&address) } });
        if (result.device_io_control.u.Status != .SUCCESS) return error.Unexpected;
    } else {
        var len: posix.socklen_t = @sizeOf(Io.Threaded.PosixAddress);
        if (posix.errno(posix.system.getsockname(socket, &address.any, &len)) != .SUCCESS) return error.Unexpected;
    }
    return Io.Threaded.addressFromPosix(&address);
}
