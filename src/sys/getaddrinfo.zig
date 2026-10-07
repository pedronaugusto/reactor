//! libc's `getaddrinfo`, called on the calling thread: the name lookup a
//! libc target has without a second task. It blocks until it answers and
//! cannot be cancelled, as std's own libc lookup cannot.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const IpAddress = Io.net.IpAddress;

/// Whether this target has it.
pub const available = builtin.link_libc and builtin.os.tag != .windows;

pub const Error = error{
    /// The name has no address, or the resolver failed.
    LookupFailed,
};

/// `name`'s addresses on `port`: the first `out.len`, in libc's order.
pub fn lookup(name: []const u8, port: u16, family: ?IpAddress.Family, out: []IpAddress) Error![]IpAddress {
    if (!available) @compileError("getaddrinfo needs libc");
    var name_buffer: [Io.net.HostName.max_len:0]u8 = undefined;
    if (name.len > Io.net.HostName.max_len) return error.LookupFailed;
    @memcpy(name_buffer[0..name.len], name);
    name_buffer[name.len] = 0;
    var port_buffer: [8]u8 = undefined;
    const port_text = std.mem.printSentinel(&port_buffer, "{d}", .{port}, 0) catch unreachable; // unreachable: a u16 is at most five digits
    const hints: std.c.addrinfo = .{
        .flags = .{ .NUMERICSERV = true },
        .family = if (family) |f| switch (f) {
            .ip4 => std.c.AF.INET,
            .ip6 => std.c.AF.INET6,
        } else std.c.AF.UNSPEC,
        .socktype = std.c.SOCK.STREAM,
        .protocol = std.c.IPPROTO.TCP,
        .canonname = null,
        .addr = null,
        .addrlen = 0,
        .next = null,
    };
    var list: ?*std.c.addrinfo = null;
    if (@backingInt(std.c.getaddrinfo(name_buffer[0..name.len :0].ptr, port_text.ptr, &hints, &list)) != 0) return error.LookupFailed;
    defer if (list) |first| std.c.freeaddrinfo(first);
    var count: usize = 0;
    var entry = list;
    while (entry) |info| : (entry = info.next) {
        const addr = info.addr orelse continue;
        if (addr.family != std.c.AF.INET and addr.family != std.c.AF.INET6) continue;
        if (count == out.len) break;
        out[count] = Io.Threaded.addressFromPosix(@alignCast(@fieldParentPtr("any", addr))); // safe: getaddrinfo's INET and INET6 entries point at a whole sockaddr of their family
        count += 1;
    }
    if (count == 0) return error.LookupFailed;
    return out[0..count];
}
