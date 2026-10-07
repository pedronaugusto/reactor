//! Making a socket and naming its end: the plain calls reactor's evented
//! connect needs around the kernel's asynchronous one. On Windows a socket
//! is an AFD endpoint, bound before it connects, as std binds it. Errors
//! are std's, as `Io.Threaded` reports them.
const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const Io = std.Io;
const net = Io.net;
const Threaded = Io.Threaded;
const windows = std.os.windows;
const ws2_32 = windows.ws2_32;
const afd = @import("afd.zig");
const sys_windows = @import("windows.zig");

const is_windows = builtin.os.tag == .windows;

pub const Handle = net.Socket.Handle;

pub const OpenError = error{
    AddressFamilyUnsupported,
    ProtocolUnsupportedBySystem,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    ProtocolUnsupportedByAddressFamily,
    SocketModeUnsupported,
    Unexpected,
};

/// A socket of `family`, close-on-exec; on Windows bound to a free port of
/// the family's unspecified address, ready to connect.
pub fn open(family: posix.sa_family_t, mode: net.Socket.Mode, protocol: ?net.Protocol) OpenError!Handle {
    if (is_windows) return openWindows(family, mode, protocol);
    const kind, const proto = Threaded.posixSocketModeProtocol(family, mode, protocol) catch |err| return switch (err) {
        error.SocketModeUnsupported => error.SocketModeUnsupported,
        error.ProtocolUnsupportedByAddressFamily => error.ProtocolUnsupportedByAddressFamily,
        else => error.Unexpected,
    };
    while (true) {
        const rc = posix.system.socket(family, kind | posix.SOCK.CLOEXEC, proto);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .INVAL => return error.ProtocolUnsupportedBySystem,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .PROTONOSUPPORT => return error.ProtocolUnsupportedByAddressFamily,
            .PROTOTYPE => return error.SocketModeUnsupported,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn openWindows(family: posix.sa_family_t, mode: net.Socket.Mode, protocol: ?net.Protocol) OpenError!Handle {
    const handle = afd.open(family, mode, protocol) catch |err| return switch (err) {
        error.OptionUnsupported => error.SocketModeUnsupported,
        else => |e| e,
    };
    errdefer close(handle);
    afd.setOption(handle, ws2_32.SOL.SOCKET, ws2_32.SO.REUSE_UNICASTPORT, @as(u32, 1)) catch |err| return switch (err) {
        error.SystemResources => error.SystemResources,
        error.Unexpected => error.Unexpected,
    };
    const unspecified: net.IpAddress = if (family == ws2_32.AF.INET6) .{ .ip6 = .unspecified(0) } else .{ .ip4 = .unspecified(0) };
    _ = afd.bind(handle, &unspecified, .Active) catch |err| return switch (err) {
        error.AddressInUse => error.Unexpected,
        error.SystemResources => error.SystemResources,
        error.Unexpected => error.Unexpected,
    };
    return handle;
}

pub const OpenUnixError = OpenError || error{FileNotFound};

/// A Unix stream socket to connect to `address`. On Windows AFD takes the
/// target from a socket option, the address a connect names being only
/// informational, and the socket is bound to no path first, as std does.
pub fn openUnix(address: *const net.UnixAddress) OpenUnixError!Handle {
    if (!is_windows) return open(posix.AF.UNIX, .stream, null);
    const path = if (!address.isAbstract()) Threaded.sliceToPrefixedFileW(null, address.path, .{ .allow_relative = false }) catch |err| return switch (err) {
        error.NameTooLong, error.BadPathName => error.FileNotFound,
        else => error.Unexpected,
    } else undefined;
    const handle = afd.open(ws2_32.AF.UNIX, .stream, null) catch |err| return switch (err) {
        error.ProtocolUnsupportedByAddressFamily, error.OptionUnsupported => error.AddressFamilyUnsupported,
        else => |e| e,
    };
    errdefer close(handle);
    if (!address.isAbstract()) {
        var target: afd.AFD.SOCKOPT_INFO.UNIX_PATH = .{ .Path = path.data };
        const bytes = std.mem.asBytes(&target)[0 .. @offsetOf(afd.AFD.SOCKOPT_INFO.UNIX_PATH, "Path") + @sizeOf(windows.WCHAR) * path.len];
        afd.option(handle, .special, 0, ws2_32.SO.UNIX_PATH, bytes) catch |err| return switch (err) {
            error.SystemResources => error.SystemResources,
            error.Unexpected => error.Unexpected,
        };
    }
    afd.bindUnixUnnamed(handle) catch |err| return switch (err) {
        error.SystemResources => error.SystemResources,
        error.Unexpected => error.Unexpected,
    };
    return handle;
}

/// The address the socket's own end is bound to.
pub fn localAddress(fd: Handle) error{ SystemResources, Unexpected }!net.IpAddress {
    var storage: Threaded.PosixAddress = undefined;
    if (is_windows) return switch (afd.control(fd, afd.IOCTL.GET_ADDRESS, &.{}, std.mem.asBytes(&storage))) {
        .SUCCESS => Threaded.addressFromPosix(&storage),
        .INSUFFICIENT_RESOURCES, .NO_MEMORY => error.SystemResources,
        else => |status| windows.unexpectedStatus(status),
    };
    var len: posix.socklen_t = @sizeOf(Threaded.PosixAddress);
    while (true) switch (posix.errno(posix.system.getsockname(fd, &storage.any, &len))) {
        .SUCCESS => return Threaded.addressFromPosix(&storage),
        .INTR => continue,
        .NOBUFS => return error.SystemResources,
        else => |err| return posix.unexpectedErrno(err),
    };
}

/// Closes the socket; on Windows forgetting its port binding first.
pub fn close(fd: Handle) void {
    if (is_windows) return sys_windows.close(fd);
    _ = posix.system.close(fd);
}
