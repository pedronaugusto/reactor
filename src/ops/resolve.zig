//! The bounded DNS stub for targets without libc. Its sockets and files
//! use the caller's Io, so DNS never needs a second resolver thread.
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const HostName = net.HostName;
const order = @import("resolve/order.zig");

pub const Error = error{ NameNotResolved, InvalidPacket } || Io.Cancelable;

pub const Name = struct {
    bytes: [254]u8 = undefined,
    len: usize = 0,

    fn init(name: []const u8) Error!Name {
        if (name.len > 254) return error.InvalidPacket;
        var result: Name = .{ .len = name.len };
        @memcpy(result.bytes[0..name.len], name);
        return result;
    }
};

const Answer = struct { count: usize, canonical: Name, hops: u8 };

/// Resolver configuration, read once per lookup; no process-wide cache.
pub const Config = struct {
    servers: [3]net.IpAddress = undefined,
    server_count: usize = 0,
    search: [254]u8 = undefined,
    search_len: usize = 0,
    ndots: u8 = 1,
    attempts: u8 = 2,
    timeout: u8 = 5,
    rotate: bool = false,

    pub fn read(io: Io) Error!Config {
        var c: Config = .{};
        const f = Io.Dir.openFileAbsolute(io, "/etc/resolv.conf", .{}) catch {
            c.servers[0] = .{ .ip4 = .loopback(53) };
            c.server_count = 1;
            return c;
        };
        defer f.close(io);
        var buffer: [4096]u8 = undefined;
        var reader = f.reader(io, &buffer);
        while (reader.interface.takeDelimiterExclusive('\n')) |text| {
            c.line(text);
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => return error.NameNotResolved,
        }
        if (c.server_count == 0) {
            c.servers[0] = .{ .ip4 = .loopback(53) };
            c.server_count = 1;
        }
        return c;
    }

    pub fn line(c: *Config, text: []const u8) void {
        var words = std.mem.tokenizeAny(u8, text[0 .. std.mem.findScalar(u8, text, '#') orelse text.len], " \t\r");
        const directive = words.next() orelse return;
        if (std.mem.eql(u8, directive, "nameserver")) {
            const address = net.IpAddress.parse(words.next() orelse return, 53) catch return;
            if (c.server_count < c.servers.len) {
                c.servers[c.server_count] = address;
                c.server_count += 1;
            }
        } else if (std.mem.eql(u8, directive, "search") or std.mem.eql(u8, directive, "domain")) {
            const rest = words.rest();
            if (rest.len > c.search.len) return;
            @memcpy(c.search[0..rest.len], rest);
            c.search_len = rest.len;
        } else if (std.mem.eql(u8, directive, "options")) {
            while (words.next()) |word| {
                if (std.mem.eql(u8, word, "rotate")) {
                    c.rotate = true;
                    continue;
                }
                const colon = std.mem.findScalar(u8, word, ':') orelse continue;
                const value = std.fmt.parseInt(u8, word[colon + 1 ..], 10) catch continue;
                const name = word[0..colon];
                if (std.mem.eql(u8, name, "ndots")) c.ndots = @min(15, value) else if (std.mem.eql(u8, name, "attempts")) c.attempts = std.math.clamp(value, 1, 10) else if (std.mem.eql(u8, name, "timeout")) c.timeout = std.math.clamp(value, 1, 60);
            }
        }
    }
};

pub fn lookup(io: Io, name: HostName, port: u16, family: ?net.IpAddress.Family, out: []net.IpAddress) Error!usize {
    var canonical: Name = .{};
    return lookupNamed(io, name, port, family, out, &canonical);
}

pub fn lookupNamed(io: Io, name: HostName, port: u16, family: ?net.IpAddress.Family, out: []net.IpAddress, canonical: *Name) Error!usize {
    if (try hosts(io, name.bytes, port, family, out)) |n| {
        canonical.* = try Name.init(name.bytes);
        return n;
    }
    const config = try Config.read(io);
    const bare = std.mem.trimEnd(u8, name.bytes, ".");
    const absolute = name.bytes.len != bare.len;
    const first = absolute or std.mem.countScalar(u8, bare, '.') >= config.ndots;
    if (first) if (queryNamed(io, bare, port, family, out, &config, canonical)) |n| return n else |err| if (err == error.Canceled) return error.Canceled;
    if (!absolute) {
        var domains = std.mem.tokenizeAny(u8, config.search[0..config.search_len], " \t");
        var candidate: [HostName.max_len]u8 = undefined;
        while (domains.next()) |domain| {
            const full = std.mem.print(&candidate, "{s}.{s}", .{ bare, domain }) catch continue;
            _ = HostName.init(full) catch continue;
            if (queryNamed(io, full, port, family, out, &config, canonical)) |n| return n else |err| if (err == error.Canceled) return error.Canceled;
        }
    }
    if (!first) return queryNamed(io, bare, port, family, out, &config, canonical);
    return error.NameNotResolved;
}

fn hosts(io: Io, name: []const u8, port: u16, family: ?net.IpAddress.Family, out: []net.IpAddress) Error!?usize {
    const file = Io.Dir.openFileAbsolute(io, "/etc/hosts", .{}) catch return null;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var n: usize = 0;
    while (reader.interface.takeDelimiterExclusive('\n')) |line| {
        var words = std.mem.tokenizeAny(u8, line[0 .. std.mem.findScalar(u8, line, '#') orelse line.len], " \t\r");
        const text = words.next() orelse continue;
        while (words.next()) |alias| if (std.ascii.eqlIgnoreCase(alias, name)) break else {} else continue;
        const address = net.IpAddress.parse(text, port) catch continue;
        if (family) |f| if (address != f) continue;
        if (n == out.len) break;
        out[n] = address;
        n += 1;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return error.NameNotResolved,
    }
    return if (n == 0) null else n;
}

const Request = struct {
    io: Io,
    name: []const u8,
    port: u16,
    rr: u16,
    config: *const Config,
    out: []net.IpAddress,
    canonical: *Name,
    result: Error!usize = error.NameNotResolved,

    fn run(r: *Request) void {
        r.result = exchange(r.*);
    }
};

/// A and AAAA run together when the Io can start a second task.
pub fn query(io: Io, name: []const u8, port: u16, family: ?net.IpAddress.Family, out: []net.IpAddress, config: *const Config) Error!usize {
    var canonical: Name = .{};
    return queryNamed(io, name, port, family, out, config, &canonical);
}

pub fn queryNamed(io: Io, name: []const u8, port: u16, family: ?net.IpAddress.Family, out: []net.IpAddress, config: *const Config, canonical: *Name) Error!usize {
    var v4: [64]net.IpAddress = undefined;
    var v6: [64]net.IpAddress = undefined;
    var cname4: Name = .{};
    var cname6: Name = .{};
    var a: Request = .{ .io = io, .name = name, .port = port, .rr = 1, .config = config, .out = &v4, .canonical = &cname4 };
    var aaaa: Request = .{ .io = io, .name = name, .port = port, .rr = 28, .config = config, .out = &v6, .canonical = &cname6 };
    if (family != .ip4) {
        var f = io.concurrent(Request.run, .{&aaaa}) catch null;
        if (family != .ip6) a.run();
        if (a.result) |_| {} else |err| {
            if (err == error.Canceled) {
                if (f) |*task| task.cancel(io);
                return error.Canceled;
            }
        }
        if (f) |*task| task.await(io) else aaaa.run();
    } else a.run();
    const n4 = if (family == .ip6) 0 else a.result catch |err| if (err == error.Canceled) return err else 0;
    const n6 = if (family == .ip4) 0 else aaaa.result catch |err| if (err == error.Canceled) return err else 0;
    var n: usize = 0;
    // Preserve DNS order within each family's answer before route selection.
    for (v6[0..n6]) |address| {
        if (n == @min(64, out.len)) break;
        out[n] = address;
        n += 1;
    }
    for (v4[0..n4]) |address| {
        if (n == @min(64, out.len)) break;
        out[n] = address;
        n += 1;
    }
    if (n == 0) return error.NameNotResolved;
    canonical.* = if (n6 != 0) cname6 else cname4;
    try order.sort(io, out[0..n]);
    return n;
}

fn exchange(r: Request) Error!usize {
    var name = try Name.init(r.name);
    var hops: u8 = 0;
    while (true) {
        var request = r;
        request.name = name.bytes[0..name.len];
        const answer = try exchangeOne(request);
        if (hops + answer.hops > 8) return error.InvalidPacket;
        if (answer.count != 0) {
            r.canonical.* = answer.canonical;
            return answer.count;
        }
        if (answer.hops == 0) return error.NameNotResolved;
        hops += answer.hops;
        name = answer.canonical;
    }
}

fn exchangeOne(r: Request) Error!Answer {
    var entropy: [4]u8 = undefined;
    r.io.random(&entropy);
    const start: usize = if (r.config.rotate) entropy[2] % r.config.server_count else 0;
    var question: [288]u8 = undefined;
    const q = try makeQuery(&question, r.name, r.rr, std.mem.readInt(u16, entropy[0..2], .big));
    for (0..r.config.attempts) |_| for (0..r.config.server_count) |step| {
        const server = r.config.servers[(start + step) % r.config.server_count];
        const local: net.IpAddress = switch (server) {
            .ip4 => .{ .ip4 = .unspecified(0) },
            .ip6 => .{ .ip6 = .unspecified(0) },
        };
        const socket = local.bind(r.io, .{ .mode = .dgram }) catch continue;
        defer socket.close(r.io);
        const timeout: Io.Timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(r.config.timeout) } };
        const deadline = timeout.toDeadline(r.io);
        socket.sendTimeout(r.io, &server, q, deadline) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            continue;
        };
        var reply: [1232]u8 = undefined;
        while (true) {
            const message = socket.receiveTimeout(r.io, &reply, deadline) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                break;
            };
            if (!message.from.eql(&server) or !matches(message.data, q)) continue;
            if (message.data[2] & 2 != 0) return tcp(r, server, q, deadline);
            return decode(message.data, r.name, r.rr, r.port, r.out);
        }
    };
    return error.NameNotResolved;
}

fn tcp(r: Request, server: net.IpAddress, q: []const u8, deadline: Io.Timeout) Error!Answer {
    const Race = union(enum) { reply: Error!Answer, expired: Io.Cancelable!void };
    var results: [2]Race = undefined;
    var race: Io.Select(Race) = .init(r.io, &results);
    defer while (race.cancel()) |_| {};
    race.concurrent(.reply, tcpRequest, .{ r, server, q }) catch return error.NameNotResolved;
    race.concurrent(.expired, Io.Timeout.sleep, .{ deadline, r.io }) catch return error.NameNotResolved;
    return switch (try race.await()) {
        .reply => |reply| reply,
        .expired => |expired| done: {
            try expired;
            while (race.cancel()) |late| switch (late) {
                .reply => |reply| if (reply) |n| break :done n else |_| {},
                .expired => {},
            };
            break :done error.NameNotResolved;
        },
    };
}

fn tcpRequest(r: Request, server: net.IpAddress, q: []const u8) Error!Answer {
    const stream = server.connect(r.io, .{ .mode = .stream }) catch |err| return if (err == error.Canceled) error.Canceled else error.NameNotResolved;
    defer stream.close(r.io);
    var storage: [512]u8 = undefined;
    var writer = stream.writer(r.io, &storage);
    var prefix: [2]u8 = undefined;
    std.mem.writeInt(u16, &prefix, @intCast(q.len), .big);
    writer.interface.writeAll(&prefix) catch return error.NameNotResolved;
    writer.interface.writeAll(q) catch return error.NameNotResolved;
    writer.interface.flush() catch return error.NameNotResolved;
    try readAll(r.io, stream.socket.handle, &prefix, .none);
    const len = std.mem.readInt(u16, &prefix, .big);
    var buffer: [65535]u8 = undefined;
    const reply = buffer[0..len];
    try readAll(r.io, stream.socket.handle, reply, .none);
    if (!matches(reply, q) or reply[2] & 2 != 0) return error.InvalidPacket;
    return decode(reply, r.name, r.rr, r.port, r.out);
}

fn readAll(io: Io, socket: net.Socket.Handle, bytes: []u8, deadline: Io.Timeout) Error!void {
    var n: usize = 0;
    while (n < bytes.len) {
        var data = [_][]u8{bytes[n..]};
        const result = io.operateTimeout(.{ .net_read = .{ .socket_handle = socket, .data = &data } }, deadline) catch |err| return if (err == error.Canceled) error.Canceled else error.NameNotResolved;
        const got = result.net_read catch return error.NameNotResolved;
        if (got.data_len == 0) return error.NameNotResolved;
        n += got.data_len;
    }
}

pub fn makeQuery(out: *[288]u8, name: []const u8, rr: u16, id: u16) Error![]const u8 {
    @memset(out, 0);
    std.mem.writeInt(u16, out[0..2], id, .big);
    out[2] = 1;
    out[5] = 1;
    out[11] = 1; // One EDNS0 OPT record, receive size 1232.
    var i: usize = 12;
    var labels = std.mem.splitScalar(u8, std.mem.trimEnd(u8, name, "."), '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or i + label.len + 1 > 267) return error.InvalidPacket;
        out[i] = @intCast(label.len);
        @memcpy(out[i + 1 ..][0..label.len], label);
        i += label.len + 1;
    }
    out[i] = 0;
    std.mem.writeInt(u16, out[i + 1 ..][0..2], rr, .big);
    out[i + 4] = 1;
    i += 5;
    out[i + 2] = 41;
    std.mem.writeInt(u16, out[i + 3 ..][0..2], 1232, .big);
    return out[0 .. i + 11];
}

/// DNS name expansion validates both reserved encodings and pointer cycles.
fn expand(packet: []const u8, start: usize, out: *[254]u8) Error!struct { usize, HostName } {
    var i = start;
    var consumed: usize = 0;
    var jumped = false;
    var n: usize = 0;
    var steps: usize = 0;
    while (true) {
        if (i >= packet.len or steps >= packet.len) return error.InvalidPacket;
        steps += 1;
        const label = packet[i];
        if (label == 0) {
            if (!jumped) consumed += 1;
            return .{ consumed, HostName.init(out[0..n]) catch return error.InvalidPacket };
        }
        if (label & 0xc0 == 0xc0) {
            if (i + 1 >= packet.len) return error.InvalidPacket;
            if (!jumped) consumed += 2;
            jumped = true;
            i = (@as(usize, label & 0x3f) << 8) | packet[i + 1];
            continue;
        }
        if (label & 0xc0 != 0 or i + 1 + label > packet.len) return error.InvalidPacket;
        if (n != 0) {
            if (n == out.len) return error.InvalidPacket;
            out[n] = '.';
            n += 1;
        }
        if (n + label > out.len) return error.InvalidPacket;
        @memcpy(out[n..][0..label], packet[i + 1 ..][0..label]);
        n += label;
        i += 1 + label;
        if (!jumped) consumed += 1 + label;
    }
}

pub fn matches(reply: []const u8, query_bytes: []const u8) bool {
    if (reply.len < 12 or reply[2] & 0x80 == 0 or reply[2] & 0x78 != 0 or !std.mem.eql(u8, reply[0..2], query_bytes[0..2])) return false;
    if (std.mem.readInt(u16, reply[4..6], .big) != 1) return false;
    var name: [254]u8 = undefined;
    const end, const expanded = expand(reply, 12, &name) catch return false;
    var expected: [254]u8 = undefined;
    const qend, const requested = expand(query_bytes, 12, &expected) catch return false;
    if (12 + end + 4 > reply.len) return false;
    return std.ascii.eqlIgnoreCase(expanded.bytes, requested.bytes) and std.mem.eql(u8, reply[12 + end ..][0..4], query_bytes[12 + qend ..][0..4]);
}

/// Only the requested owner's chain contributes addresses. Compression
/// loops and CNAME chains beyond eight links are rejected.
pub fn answers(reply: []const u8, name: []const u8, rr: u16, port: u16, out: []net.IpAddress) Error!usize {
    const answer = try decode(reply, name, rr, port, out);
    return if (answer.count == 0) error.NameNotResolved else answer.count;
}

fn decode(reply: []const u8, name: []const u8, rr: u16, port: u16, out: []net.IpAddress) Error!Answer {
    if (reply.len < 12 or reply[3] & 15 != 0) return error.NameNotResolved;
    if (name.len > 254) return error.InvalidPacket;
    var current: [254]u8 = undefined;
    @memcpy(current[0..name.len], name);
    var current_len = name.len;
    for (0..9) |hop| {
        var qname: [254]u8 = undefined;
        const start, _ = expand(reply, 12, &qname) catch return error.InvalidPacket;
        var i = 12 + start + 4;
        var n: usize = 0;
        var cname: [254]u8 = undefined;
        var cname_len: usize = 0;
        const count = std.mem.readInt(u16, reply[6..8], .big);
        for (0..count) |_| {
            var owner: [254]u8 = undefined;
            const end, const host = expand(reply, i, &owner) catch return error.InvalidPacket;
            i += end;
            if (i + 10 > reply.len) return error.InvalidPacket;
            const kind = std.mem.readInt(u16, reply[i..][0..2], .big);
            const class = std.mem.readInt(u16, reply[i + 2 ..][0..2], .big);
            const len = std.mem.readInt(u16, reply[i + 8 ..][0..2], .big);
            i += 10;
            if (i + len > reply.len) return error.InvalidPacket;
            defer i += len;
            if (class != 1 or !std.ascii.eqlIgnoreCase(host.bytes, current[0..current_len])) continue;
            if (kind == 5) {
                const used, const target = expand(reply, i, &cname) catch return error.InvalidPacket;
                if (used != len) return error.InvalidPacket;
                cname_len = target.bytes.len;
            } else if (kind == rr and n < out.len) {
                out[n] = switch (kind) {
                    1 => if (len == 4) .{ .ip4 = .{ .bytes = reply[i..][0..4].*, .port = port } } else return error.InvalidPacket,
                    28 => if (len == 16) .{ .ip6 = .{ .bytes = reply[i..][0..16].*, .port = port } } else return error.InvalidPacket,
                    else => return error.InvalidPacket,
                };
                n += 1;
            }
        }
        if (n != 0) return .{ .count = n, .canonical = try Name.init(current[0..current_len]), .hops = @intCast(hop) };
        if (cname_len == 0) return if (hop == 0) error.NameNotResolved else .{ .count = 0, .canonical = try Name.init(current[0..current_len]), .hops = @intCast(hop) };
        if (hop == 8 or std.ascii.eqlIgnoreCase(current[0..current_len], cname[0..cname_len])) return error.InvalidPacket;
        @memcpy(current[0..cname_len], cname[0..cname_len]);
        current_len = cname_len;
    }
    return error.InvalidPacket;
}
