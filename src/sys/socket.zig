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

/// The mode a socket starts in: a readiness backend connects a socket in
/// non-blocking mode, then puts it back (`setBlocking`).
pub const Start = enum { blocking, nonblocking };

const nonblock_flag: usize = 1 << @bitOffsetOf(posix.O, "NONBLOCK");

/// Whether a send with `MSG_DONTWAIT` returns instead of waiting for room on
/// a socket in blocking mode. Darwin's `send`, `sendto` and `sendmsg` wait
/// anyway (its receives do not): a stream write larger than the free room in
/// the send buffer then holds the calling thread until the peer has read,
/// which on a loop whose reader is another task of that thread is forever.
/// Where this is false a readiness loop writes only to sockets in
/// non-blocking mode, and a socket it connects stays in it.
pub const send_honors_dontwait = !builtin.os.tag.isDarwin();

/// A socket of `family`, close-on-exec; on Darwin, where a send has no
/// `MSG_NOSIGNAL` on every path, one that never raises `SIGPIPE`.
pub fn open(family: posix.sa_family_t, mode: net.Socket.Mode, protocol: ?net.Protocol, start: Start) OpenError!Handle {
    if (is_windows) return openWindows(family, mode, protocol);
    const kind, const proto = Threaded.posixSocketModeProtocol(family, mode, protocol) catch |err| return switch (err) {
        error.SocketModeUnsupported => error.SocketModeUnsupported,
        error.ProtocolUnsupportedByAddressFamily => error.ProtocolUnsupportedByAddressFamily,
        else => error.Unexpected,
    };
    // Darwin takes no flags with the type: they are set after.
    const nonblock: u32 = if (start == .nonblocking) posix.SOCK.NONBLOCK else 0;
    const flags: u32 = if (Threaded.socket_flags_unsupported) 0 else posix.SOCK.CLOEXEC | nonblock;
    while (true) {
        const rc = posix.system.socket(family, kind | flags, proto);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const fd: posix.socket_t = @intCast(rc);
                if (Threaded.socket_flags_unsupported) {
                    errdefer close(fd);
                    try setCloexec(fd);
                    if (@hasDecl(posix.SO, "NOSIGPIPE")) {
                        const on: c_int = 1;
                        if (posix.errno(posix.system.setsockopt(fd, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, @ptrCast(&on), @sizeOf(c_int))) != .SUCCESS) return error.Unexpected; // safe: the option is an int, its length given
                    }
                    if (start == .nonblocking) try setStatusFlags(fd, nonblock_flag);
                }
                return fd;
            },
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

/// A fresh socket opened `.nonblocking` back in blocking mode: its status
/// flags held nothing else.
pub fn setBlocking(fd: posix.socket_t) error{Unexpected}!void {
    if (comptime is_windows) unreachable; // unreachable: status flags are POSIX only
    return setStatusFlags(fd, 0);
}

fn setStatusFlags(fd: posix.fd_t, flags: usize) error{Unexpected}!void {
    while (true) switch (posix.errno(posix.system.fcntl(fd, posix.F.SETFL, flags))) {
        .SUCCESS => return,
        .INTR => continue,
        else => |err| return posix.unexpectedErrno(err),
    };
}

fn setCloexec(fd: posix.fd_t) error{Unexpected}!void {
    while (true) switch (posix.errno(posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC)))) {
        .SUCCESS => return,
        .INTR => continue,
        else => |err| return posix.unexpectedErrno(err),
    };
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
pub fn openUnix(address: *const net.UnixAddress, start: Start) OpenUnixError!Handle {
    if (!is_windows) return open(posix.AF.UNIX, .stream, null, start);
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
        var target: windows.AFD.SOCKOPT_INFO.UNIX_PATH = .{ .Path = path.data };
        const bytes = std.mem.asBytes(&target)[0 .. @offsetOf(windows.AFD.SOCKOPT_INFO.UNIX_PATH, "Path") + @sizeOf(windows.WCHAR) * path.len];
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
    if (is_windows) return switch (afd.control(fd, windows.IOCTL.AFD.GET_ADDRESS, &.{}, std.mem.asBytes(&storage))) {
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
