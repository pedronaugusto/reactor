//! libc's `getaddrinfo`, called on the calling thread: the name lookup a
//! libc target has without a second task. It blocks until it answers and
//! cannot be cancelled, as std's own libc lookup cannot.
const builtin = @import("builtin");
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const IpAddress = Io.net.IpAddress;

/// Whether this target has it.
pub const available = builtin.link_libc and builtin.os.tag != .windows;

/// getaddrinfo's failures, by std's lookup names: no such name, or none of
/// the family (`EAI_NONAME`, `EAI_NODATA`); no usable answer from the
/// resolver (`EAI_AGAIN`, `EAI_FAIL`, and the codes left: the system's own
/// failure); an answer with no address; memory (`EAI_MEMORY`).
pub const Error = error{ UnknownHostName, NameServerFailure, NoAddressReturned, SystemResources };

pub const Result = struct { addresses: []IpAddress, canonical: ?Io.net.HostName = null };

/// `name`'s addresses on `port`: the first `out.len`, in libc's order.
pub fn lookup(name: []const u8, port: u16, family: ?IpAddress.Family, out: []IpAddress, canonical_buffer: ?*[Io.net.HostName.max_len]u8) Error!Result {
    if (!available) @compileError("getaddrinfo needs libc");
    var name_buffer: [Io.net.HostName.max_len:0]u8 = undefined;
    if (name.len > Io.net.HostName.max_len) return error.UnknownHostName;
    @memcpy(name_buffer[0..name.len], name);
    name_buffer[name.len] = 0;
    var port_buffer: [8]u8 = undefined;
    const port_text = std.mem.printSentinel(&port_buffer, "{d}", .{port}, 0) catch aegis.assert.never("a u16 is at most five digits");
    const hints: std.c.addrinfo = .{
        .flags = .{ .NUMERICSERV = true, .CANONNAME = canonical_buffer != null },
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
    const code = std.c.getaddrinfo(name_buffer[0..name.len :0].ptr, port_text.ptr, &hints, &list);
    if (@backingInt(code) != 0) return failure(code);
    defer if (list) |first| std.c.freeaddrinfo(first);
    var count: usize = 0;
    var canonical: ?Io.net.HostName = null;
    var entry = list;
    while (entry) |info| : (entry = info.next) {
        if (canonical_buffer) |buffer| if (info.canonname) |text| if (canonical == null) {
            const bytes = std.mem.sliceTo(text, 0);
            if (bytes.len <= buffer.len) {
                @memcpy(buffer[0..bytes.len], bytes);
                canonical = Io.net.HostName.init(buffer[0..bytes.len]) catch null;
            }
        };
        const addr = info.addr orelse continue;
        if (addr.family != std.c.AF.INET and addr.family != std.c.AF.INET6) continue;
        if (count == out.len) break;
        out[count] = Io.Threaded.addressFromPosix(@alignCast(@fieldParentPtr("any", addr))); // safe: getaddrinfo's INET and INET6 entries point at a whole sockaddr of their family
        count += 1;
    }
    if (count == 0) return error.NoAddressReturned;
    return .{ .addresses = out[0..count], .canonical = canonical };
}

/// A getaddrinfo code, as std names a lookup's failure.
pub fn failure(code: std.c.EAI) Error {
    if (code == .NONAME) return error.UnknownHostName;
    if (@hasField(std.c.EAI, "NODATA") and code == @field(std.c.EAI, "NODATA")) return error.UnknownHostName;
    if (code == .MEMORY) return error.SystemResources;
    // EAI_AGAIN and EAI_FAIL, and the rest: the resolver gave no usable answer.
    return error.NameServerFailure;
}
