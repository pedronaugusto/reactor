//! Making a socket and naming its end: the two plain calls reactor's
//! evented connect needs around the kernel's asynchronous one. Errors are
//! std's, as `Io.Threaded` reports them.
const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const Io = std.Io;
const net = Io.net;
const Threaded = Io.Threaded;

/// Windows has no runtime yet (see sys/memory.zig): nothing here runs there.
const no_runtime = builtin.os.tag == .windows;

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

/// A socket of `family`, close-on-exec.
pub fn open(family: posix.sa_family_t, mode: net.Socket.Mode, protocol: ?net.Protocol) OpenError!posix.socket_t {
    if (comptime no_runtime) unreachable; // unreachable: no runtime is built where tasks cannot run
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

/// The address the socket's own end is bound to.
pub fn localAddress(fd: posix.socket_t) error{ SystemResources, Unexpected }!net.IpAddress {
    if (comptime no_runtime) unreachable; // unreachable: no runtime is built where tasks cannot run
    var storage: Threaded.PosixAddress = undefined;
    var len: posix.socklen_t = @sizeOf(Threaded.PosixAddress);
    while (true) switch (posix.errno(posix.system.getsockname(fd, &storage.any, &len))) {
        .SUCCESS => return Threaded.addressFromPosix(&storage),
        .INTR => continue,
        .NOBUFS => return error.SystemResources,
        else => |err| return posix.unexpectedErrno(err),
    };
}

pub fn close(fd: posix.fd_t) void {
    if (comptime no_runtime) unreachable; // unreachable: no runtime is built where tasks cannot run
    _ = posix.system.close(fd);
}
