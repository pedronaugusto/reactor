//! Socket options: the plain `setsockopt` and `getsockopt` calls, and AFD's
//! `SOCKOPT` control on Windows, with the refusals named. Which options to
//! set, and when, is the caller's (`ext/net/options.zig`).
const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const net = std.Io.net;
const windows = std.os.windows;
const ws2_32 = windows.ws2_32;
const afd = @import("afd.zig");

const os = builtin.os.tag;
const is_windows = os == .windows;

pub const Handle = net.Socket.Handle;

/// Why an option was not set: the system has no such option, or refuses
/// its value (`OptionUnsupported`), or refuses it to this process
/// (`AccessDenied`).
pub const Error = error{ OptionUnsupported, AccessDenied, SystemResources, Unexpected };

/// An option as the system names it: its level and its number. On
/// Windows the level `afd_own` names one of AFD's own settings, by its
/// information class: the transport has no such option.
pub const Option = struct { level: i32, name: u32 };

const afd_own: i32 = -1;

/// The options reactor sets, as this system names them; null where it has
/// none.
pub const nodelay: ?Option = if (is_windows) .{ .level = ws2_32.IPPROTO.TCP, .name = ws2_32.TCP.NODELAY } else if (posixHas("TCP", "NODELAY")) .{ .level = posix.IPPROTO.TCP, .name = posix.TCP.NODELAY } else null;
pub const keepalive: ?Option = if (is_windows) .{ .level = ws2_32.SOL.SOCKET, .name = ws2_32.SO.KEEPALIVE } else if (posixHas("SO", "KEEPALIVE")) .{ .level = posix.SOL.SOCKET, .name = posix.SO.KEEPALIVE } else null;
/// The idle time before the first probe, in seconds. Linux and the BSDs
/// name it `TCP_KEEPIDLE`; Apple's systems and Windows, `TCP_KEEPALIVE`.
pub const keep_idle: ?Option = if (is_windows) .{ .level = ws2_32.IPPROTO.TCP, .name = ws2_32.TCP.KEEPALIVE } else if (posixHas("TCP", "KEEPIDLE")) .{ .level = posix.IPPROTO.TCP, .name = posix.TCP.KEEPIDLE } else if (builtin.os.tag.isDarwin()) .{ .level = posix.IPPROTO.TCP, .name = posix.TCP.KEEPALIVE } else null;
pub const keep_interval: ?Option = if (is_windows) .{ .level = ws2_32.IPPROTO.TCP, .name = ws2_32.TCP.KEEPINTVL } else if (posixHas("TCP", "KEEPINTVL")) .{ .level = posix.IPPROTO.TCP, .name = posix.TCP.KEEPINTVL } else null;
pub const keep_count: ?Option = if (is_windows) .{ .level = ws2_32.IPPROTO.TCP, .name = ws2_32.TCP.KEEPCNT } else if (posixHas("TCP", "KEEPCNT")) .{ .level = posix.IPPROTO.TCP, .name = posix.TCP.KEEPCNT } else null;
/// Windows keeps the send buffer in AFD, not the transport: Winsock's
/// `SO_SNDBUF` is AFD's `SEND_WINDOW_SIZE`.
pub const send_buffer: ?Option = if (is_windows) .{ .level = afd_own, .name = @backingInt(windows.AFD.INFORMATION.TYPE.SEND_WINDOW_SIZE) } else if (posixHas("SO", "SNDBUF")) .{ .level = posix.SOL.SOCKET, .name = posix.SO.SNDBUF } else null;
pub const receive_buffer: ?Option = if (is_windows) .{ .level = ws2_32.SOL.SOCKET, .name = ws2_32.SO.RCVBUF } else if (posixHas("SO", "RCVBUF")) .{ .level = posix.SOL.SOCKET, .name = posix.SO.RCVBUF } else null;
/// IPv4's type of service. Windows accepts `IP_TOS` and ignores it (its QoS
/// is the qWAVE API), so it has none here.
pub const tos: ?Option = if (is_windows) null else if (posixHas("IP", "TOS")) .{ .level = posix.IPPROTO.IP, .name = posix.IP.TOS } else null;
/// IPv6's traffic class; Windows has none, as for `tos`.
pub const tclass: ?Option = if (is_windows) null else if (posixHas("IPV6", "TCLASS")) .{ .level = posix.IPPROTO.IPV6, .name = posix.IPV6.TCLASS } else null;
pub const reuse_address: ?Option = if (is_windows) .{ .level = ws2_32.SOL.SOCKET, .name = ws2_32.SO.REUSEADDR } else if (posixHas("SO", "REUSEADDR")) .{ .level = posix.SOL.SOCKET, .name = posix.SO.REUSEADDR } else null;
/// POSIX's port sharing, set beside `reuse_address` as std's listen sets
/// it; Windows has none (its `SO_REUSEADDR` shares the port).
pub const reuse_port: ?Option = if (is_windows) null else if (posixHas("SO", "REUSEPORT")) .{ .level = posix.SOL.SOCKET, .name = posix.SO.REUSEPORT } else null;

/// Apple's systems: a write to a closed peer returns `EPIPE` and raises no
/// `SIGPIPE`, which a library cannot count on its program ignoring (their
/// sends have no `MSG_NOSIGNAL`).
pub const no_sigpipe: ?Option = if (posixHas("SO", "NOSIGPIPE")) .{ .level = posix.SOL.SOCKET, .name = posix.SO.NOSIGPIPE } else null;

fn posixHas(comptime space: []const u8, comptime name: []const u8) bool {
    if (is_windows or os == .wasi) return false;
    if (!@hasDecl(posix, space)) return false;
    const T = @field(posix, space);
    return @TypeOf(T) == type and @hasDecl(T, name);
}

/// Sets `option` to the integer `value`, as `setsockopt` would.
pub fn set(handle: Handle, option: ?Option, value: c_int) Error!void {
    const o = option orelse return error.OptionUnsupported;
    if (is_windows) {
        var v: u32 = @bitCast(value);
        if (o.level == afd_own) return refusal(afd.setInformation(handle, @fromBackingInt(@intCast(o.name)), v));
        return refusal(afd.option(handle, .set, o.level, o.name, std.mem.asBytes(&v)).status);
    }
    const bytes = std.mem.asBytes(&value);
    while (true) switch (posix.errno(posix.system.setsockopt(handle, o.level, o.name, bytes.ptr, @intCast(bytes.len)))) {
        .SUCCESS => return,
        .INTR => continue,
        .NOPROTOOPT, .INVAL, .OPNOTSUPP => return error.OptionUnsupported,
        .ACCES, .PERM => return error.AccessDenied,
        .NOBUFS, .NOMEM => return error.SystemResources,
        else => |err| return posix.unexpectedErrno(err),
    };
}

/// The integer value of `option`, as `getsockopt` reads it.
pub fn get(handle: Handle, option: ?Option) Error!c_int {
    const o = option orelse return error.OptionUnsupported;
    if (is_windows) {
        // Zeroed: a boolean is answered in its first byte alone.
        var v: u32 = 0;
        if (o.level == afd_own) {
            try refusal(afd.getInformation(handle, @fromBackingInt(@intCast(o.name)), &v));
        } else {
            const answer = afd.option(handle, .get, o.level, o.name, std.mem.asBytes(&v));
            try refusal(answer.status);
            if (answer.len == 0 or answer.len > @sizeOf(u32)) return error.Unexpected;
        }
        return @bitCast(v);
    }
    var value: c_int = 0;
    var len: posix.socklen_t = @sizeOf(c_int);
    while (true) switch (posix.errno(posix.system.getsockopt(handle, o.level, o.name, @ptrCast(&value), &len))) { // aegis: boundary: the option is a c_int, its length given
        .SUCCESS => return value,
        .INTR => continue,
        .NOPROTOOPT, .INVAL, .OPNOTSUPP => return error.OptionUnsupported,
        .NOBUFS, .NOMEM => return error.SystemResources,
        else => |err| return posix.unexpectedErrno(err),
    };
}

fn refusal(status: windows.NTSTATUS) Error!void {
    if (comptime !is_windows) unreachable; // unreachable: AFD is Windows only
    return switch (status) {
        .SUCCESS => {},
        // WSAENOPROTOOPT and WSAEINVAL: an option this system lacks, or a
        // value it refuses.
        .NOT_SUPPORTED, .INVALID_PARAMETER, .INVALID_DEVICE_REQUEST => error.OptionUnsupported,
        .ACCESS_DENIED => error.AccessDenied,
        .INSUFFICIENT_RESOURCES, .NO_MEMORY => error.SystemResources,
        else => |other| windows.unexpectedStatus(other),
    };
}
