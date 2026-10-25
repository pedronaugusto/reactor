//! Socket options std's `Io` has no word for: Nagle's algorithm, keepalive
//! and its timings, the buffer sizes, the traffic class. `connect` and
//! `listen` set them on the socket they make before it connects or listens,
//! which is when the buffers count: the window scale a connection uses is
//! fixed by its first segment (tcp(7): "must be set prior to the listen(2)
//! or connect(2) calls"). `setOptions` sets them on a socket already made.
//!
//! A refused option is returned, named, never passed over. The kernel's own
//! adjustments stand: Linux doubles a buffer size and caps it at
//! `net.core.wmem_max` or `rmem_max`.
const std = @import("std");
const aegis = @import("aegis");
const sys = @import("../../sys/options.zig");
const net = std.Io.net;

/// Why an option was not set: the system has no such option or refuses its
/// value (`OptionUnsupported`), or refuses it to this process
/// (`AccessDenied`).
pub const Error = sys.Error;

/// Seconds as TCP's keepalive timings take them, within Linux's bound.
pub const KeepaliveSeconds = aegis.int.Ranged(u16, 1, 32767);
/// How many unanswered probes end a connection, within Linux's bound.
pub const KeepaliveCount = aegis.int.Ranged(u8, 1, 127);

/// TCP keepalive: off, or on with its timings. A null timing leaves the
/// system's.
pub const Keepalive = union(enum) {
    off,
    on: Probes,

    pub const Probes = struct {
        /// How long a connection is idle before the first probe.
        idle: ?KeepaliveSeconds = null,
        /// How long between unanswered probes.
        interval: ?KeepaliveSeconds = null,
        /// How many unanswered probes end the connection.
        count: ?KeepaliveCount = null,
    };
};

/// The options to set; a null field leaves the system's setting.
pub const Options = struct {
    /// Turn Nagle's algorithm off (true) or on (false).
    nodelay: ?bool = null,
    keepalive: ?Keepalive = null,
    /// `SO_SNDBUF`. Sizes past `maxInt(c_int)` are asked as that.
    send_buffer: ?aegis.units.Bytes(u32) = null,
    /// `SO_RCVBUF`. Sizes past `maxInt(c_int)` are asked as that.
    receive_buffer: ?aegis.units.Bytes(u32) = null,
    /// The IP header's traffic class byte: `IP_TOS` on IPv4, `IPV6_TCLASS`
    /// on IPv6. `OptionUnsupported` on Windows, which accepts `IP_TOS` and
    /// ignores it.
    traffic_class: ?u8 = null,

    /// Whether any option is asked for.
    pub fn any(o: Options) bool {
        return o.nodelay != null or o.keepalive != null or o.send_buffer != null or o.receive_buffer != null or o.traffic_class != null;
    }
};

/// Sets `options` on `socket`, a socket of `socket.address`'s family. On
/// a connected or accepted socket the buffer sizes no longer change the
/// window scale, which its first segment fixed. On Apple's systems the
/// socket is also made never to raise `SIGPIPE`, as every socket reactor
/// makes is.
pub fn setOptions(socket: net.Socket, options: Options) Error!void {
    if (sys.no_sigpipe != null) try sys.set(socket.handle, sys.no_sigpipe, 1);
    return apply(socket.handle, socket.address, options);
}

/// Sets `options` on the socket `handle` of `family`'s address family.
pub fn apply(handle: net.Socket.Handle, family: net.IpAddress.Family, options: Options) Error!void {
    if (options.nodelay) |on| try sys.set(handle, sys.nodelay, @intFromBool(on));
    if (options.keepalive) |k| switch (k) {
        .off => try sys.set(handle, sys.keepalive, 0),
        .on => |probes| {
            try sys.set(handle, sys.keepalive, 1);
            if (probes.idle) |s| try sys.set(handle, sys.keep_idle, s.raw());
            if (probes.interval) |s| try sys.set(handle, sys.keep_interval, s.raw());
            if (probes.count) |n| try sys.set(handle, sys.keep_count, n.raw());
        },
    };
    if (options.send_buffer) |size| try sys.set(handle, sys.send_buffer, asked(size));
    if (options.receive_buffer) |size| try sys.set(handle, sys.receive_buffer, asked(size));
    if (options.traffic_class) |class| try sys.set(handle, switch (family) {
        .ip4 => sys.tos,
        .ip6 => sys.tclass,
    }, class);
}

/// Sets the options that let a bind share its local port: `SO_REUSEADDR`,
/// and `SO_REUSEPORT` on POSIX, as std's `ListenOptions.reuse_address`.
pub fn reuse(handle: net.Socket.Handle) Error!void {
    try sys.set(handle, sys.reuse_address, 1);
    if (sys.reuse_port != null) try sys.set(handle, sys.reuse_port, 1);
}

fn asked(size: aegis.units.Bytes(u32)) c_int {
    return @intCast(@min(size.raw(), std.math.maxInt(c_int)));
}
