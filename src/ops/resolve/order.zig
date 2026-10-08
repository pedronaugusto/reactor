//! Stable RFC 6724 destination selection: usable route, matching scope,
//! destination precedence, then the resolver's original order.
const std = @import("std");
const Io = std.Io;
const net = Io.net;

pub const Rank = struct { usable: bool, matching_scope: bool, precedence: u8 };

pub fn rank(destination: net.IpAddress, source: ?net.IpAddress) Rank {
    return .{ .usable = source != null, .matching_scope = if (source) |s| scope(destination) == scope(s) else false, .precedence = precedence(destination) };
}

pub fn before(a: Rank, b: Rank) bool {
    if (a.usable != b.usable) return a.usable;
    if (a.matching_scope != b.matching_scope) return a.matching_scope;
    return a.precedence > b.precedence;
}

pub fn sort(io: Io, addresses: []net.IpAddress) Io.Cancelable!void {
    std.debug.assert(addresses.len <= 64);
    var ranks: [64]Rank = undefined;
    for (addresses, ranks[0..addresses.len]) |address, *r| {
        // A UDP connect selects a source without sending a packet.
        const stream = address.connect(io, .{ .mode = .dgram }) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            r.* = rank(address, null);
            continue;
        };
        r.* = rank(address, stream.socket.address);
        stream.close(io);
    }
    for (1..addresses.len) |i| {
        var j = i;
        while (j > 0 and before(ranks[j], ranks[j - 1])) : (j -= 1) {
            std.mem.swap(net.IpAddress, &addresses[j], &addresses[j - 1]);
            std.mem.swap(Rank, &ranks[j], &ranks[j - 1]);
        }
    }
}

fn scope(address: net.IpAddress) u8 {
    return switch (address) {
        .ip4 => |a| if (a.bytes[0] == 127 or (a.bytes[0] == 169 and a.bytes[1] == 254) or std.mem.eql(u8, a.bytes[0..3], &.{ 224, 0, 0 })) 2 else 14,
        .ip6 => |a| if (a.bytes[0] == 0xff) a.bytes[1] & 15 else if (std.mem.eql(u8, &a.bytes, &net.Ip6Address.loopback(0).bytes) or (a.bytes[0] == 0xfe and a.bytes[1] & 0xc0 == 0x80)) 2 else if (a.bytes[0] == 0xfe and a.bytes[1] & 0xc0 == 0xc0) 5 else 14,
    };
}

fn precedence(address: net.IpAddress) u8 {
    return switch (address) {
        .ip4 => 35,
        .ip6 => |a| p: {
            if (std.mem.eql(u8, &a.bytes, &net.Ip6Address.loopback(0).bytes)) break :p 50;
            if (std.mem.eql(u8, a.bytes[0..10], &@as([10]u8, @splat(0))) and a.bytes[10] == 0xff and a.bytes[11] == 0xff) break :p 35;
            if (a.bytes[0] == 0x20 and a.bytes[1] == 0x02) break :p 30;
            if (std.mem.eql(u8, a.bytes[0..4], &.{ 0x20, 1, 0, 0 })) break :p 5;
            if (a.bytes[0] & 0xfe == 0xfc) break :p 3;
            if (std.mem.eql(u8, a.bytes[0..12], &@as([12]u8, @splat(0))) or (a.bytes[0] == 0xfe and a.bytes[1] & 0xc0 == 0xc0) or (a.bytes[0] == 0x3f and a.bytes[1] == 0xfe)) break :p 1;
            break :p 40;
        },
    };
}
