//! Bounded DNS parsing and a local resolver: no external DNS or config changes.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const stub = @import("ops/resolve.zig");

fn response(buffer: []u8, query: []const u8, count: u16) []u8 {
    const header_len = query.len - 11;
    @memcpy(buffer[0..header_len], query[0..header_len]);
    buffer[2] = 0x81;
    buffer[3] = 0x80;
    std.mem.writeInt(u16, buffer[6..8], count, .big);
    buffer[11] = 0;
    var i = header_len;
    for (0..count) |n| {
        @memcpy(buffer[i..][0..12], &[_]u8{ 0xc0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4 });
        @memcpy(buffer[i + 12 ..][0..4], &[_]u8{ 127, 0, 0, @as(u8, @intCast(n % 255)) });
        i += 16;
    }
    return buffer[0..i];
}

test "DNS keeps a bounded answer and validates its id and question" {
    var query_buffer: [288]u8 = undefined;
    const query = try stub.makeQuery(&query_buffer, "bounded.example", 1, 123);
    var packet: [4096]u8 = undefined;
    const reply = response(&packet, query, 100);
    try testing.expect(stub.matches(reply, query));
    var addresses: [16]Io.net.IpAddress = undefined;
    try testing.expectEqual(@as(usize, 16), try stub.answers(reply, "bounded.example", 1, 80, &addresses));
    try testing.expectEqual(@as(u16, 80), addresses[0].getPort());
    reply[0] ^= 1;
    try testing.expect(!stub.matches(reply, query));
    reply[0] ^= 1;
    reply[13] ^= 1;
    try testing.expect(!stub.matches(reply, query));
}

test "DNS rejects compression loops and unrelated answer owners" {
    var qbuf: [288]u8 = undefined;
    const q = try stub.makeQuery(&qbuf, "wanted.example", 1, 10);
    var packet: [512]u8 = undefined;
    const reply = response(&packet, q, 1);
    const answer = q.len - 11;
    reply[answer + 1] = @intCast(answer); // self-referential compression pointer
    var addresses: [1]Io.net.IpAddress = undefined;
    try testing.expectError(error.InvalidPacket, stub.answers(reply, "wanted.example", 1, 80, &addresses));
    reply[answer + 1] = 12;
    try testing.expectError(error.NameNotResolved, stub.answers(reply, "other.example", 1, 80, &addresses));
}

test "DNS configuration honors bounds search and rotation" {
    var config: stub.Config = .{};
    config.line("nameserver 127.0.0.1");
    config.line("nameserver ::1");
    config.line("nameserver 127.0.0.2");
    config.line("nameserver 127.0.0.3");
    config.line("search example.test local.test");
    config.line("options ndots:3 timeout:0 attempts:0 rotate");
    try testing.expectEqual(@as(usize, 3), config.server_count);
    try testing.expectEqualStrings("example.test local.test", config.search[0..config.search_len]);
    try testing.expectEqual(@as(u8, 1), config.attempts);
    try testing.expectEqual(@as(u8, 1), config.timeout);
    try testing.expect(config.rotate);
}

fn serve(io: Io, socket: Io.net.Socket) !void {
    var query: [512]u8 = undefined;
    const message = try socket.receive(io, &query);
    var packet: [512]u8 = undefined;
    const reply = response(&packet, message.data, 3);
    // A mismatched id must be ignored while the valid answer remains pending.
    reply[0] ^= 1;
    try socket.send(io, &message.from, reply);
    reply[0] ^= 1;
    try socket.send(io, &message.from, reply);
}

test "DNS queries a local server and ignores a mismatched reply" {
    const io = testing.io;
    const socket = try (Io.net.IpAddress{ .ip4 = .loopback(0) }).bind(io, .{ .mode = .dgram });
    defer socket.close(io);
    var config: stub.Config = .{};
    config.servers[0] = socket.address;
    config.server_count = 1;
    var server = try io.concurrent(serve, .{ io, socket });
    defer server.cancel(io) catch {};
    var addresses: [2]Io.net.IpAddress = undefined;
    try testing.expectEqual(@as(usize, 2), try stub.query(io, "local.example", 80, .ip4, &addresses, &config));
    try server.await(io);
}

test "DNS rejects reserved label encodings" {
    var qbuf: [288]u8 = undefined;
    const q = try stub.makeQuery(&qbuf, "wanted.example", 1, 10);
    var packet: [512]u8 = undefined;
    const reply = response(&packet, q, 1);
    reply[q.len - 11] = 0x40;
    var addresses: [1]Io.net.IpAddress = undefined;
    try testing.expectError(error.InvalidPacket, stub.answers(reply, "wanted.example", 1, 80, &addresses));
}

fn cnameResponse(buffer: []u8, query: []const u8, target: []const u8) ![]u8 {
    const header_len = query.len - 11;
    @memcpy(buffer[0..header_len], query[0..header_len]);
    buffer[2] = 0x81;
    buffer[3] = 0x80;
    std.mem.writeInt(u16, buffer[6..8], 1, .big);
    buffer[11] = 0;
    var encoded: [288]u8 = undefined;
    const target_query = try stub.makeQuery(&encoded, target, 1, 0);
    const name_len = target_query.len - 27;
    @memcpy(buffer[header_len..][0..12], &[_]u8{ 0xc0, 12, 0, 5, 0, 1, 0, 0, 0, 60, 0, 0 });
    std.mem.writeInt(u16, buffer[header_len + 10 ..][0..2], @intCast(name_len), .big);
    @memcpy(buffer[header_len + 12 ..][0..name_len], target_query[12..][0..name_len]);
    return buffer[0 .. header_len + 12 + name_len];
}

fn serveCname(io: Io, socket: Io.net.Socket) !void {
    var query: [512]u8 = undefined;
    var packet: [512]u8 = undefined;
    const first = try socket.receive(io, &query);
    try socket.send(io, &first.from, try cnameResponse(&packet, first.data, "canonical.example"));
    const second = try socket.receive(io, &query);
    var expected: [288]u8 = undefined;
    const q = try stub.makeQuery(&expected, "canonical.example", 1, std.mem.readInt(u16, second.data[0..2], .big));
    try testing.expectEqualSlices(u8, q, second.data);
    try socket.send(io, &second.from, response(&packet, second.data, 2));
}

test "DNS follows a CNAME-only reply and retains the canonical name" {
    const io = testing.io;
    const socket = try (Io.net.IpAddress{ .ip4 = .loopback(0) }).bind(io, .{ .mode = .dgram });
    defer socket.close(io);
    var config: stub.Config = .{};
    config.servers[0] = socket.address;
    config.server_count = 1;
    var server = try io.concurrent(serveCname, .{ io, socket });
    defer server.cancel(io) catch {};
    var addresses: [2]Io.net.IpAddress = undefined;
    var canonical: stub.Name = .{};
    try testing.expectEqual(@as(usize, 2), try stub.queryNamed(io, "alias.example", 80, .ip4, &addresses, &config, &canonical));
    try testing.expectEqualStrings("canonical.example", canonical.bytes[0..canonical.len]);
    try server.await(io);
}

fn serveTruncated(io: Io, socket: Io.net.Socket) !void {
    var query: [512]u8 = undefined;
    const message = try socket.receive(io, &query);
    var packet: [512]u8 = undefined;
    const reply = response(&packet, message.data, 0);
    reply[2] |= 2;
    try socket.send(io, &message.from, reply);
}

fn serveTcp(io: Io, server: *Io.net.Server) !void {
    const stream = try server.accept(io);
    defer stream.close(io);
    var storage: [512]u8 = undefined;
    var reader = stream.reader(io, &storage);
    var prefix: [2]u8 = undefined;
    try reader.interface.readSliceAll(&prefix);
    const len = std.mem.readInt(u16, &prefix, .big);
    if (len > 512) return error.TestUnexpectedResult;
    var query: [512]u8 = undefined;
    try reader.interface.readSliceAll(query[0..len]);
    var packet: [512]u8 = undefined;
    const reply = response(&packet, query[0..len], 2);
    std.mem.writeInt(u16, &prefix, @intCast(reply.len), .big);
    var output: [512]u8 = undefined;
    var writer = stream.writer(io, &output);
    try writer.interface.writeAll(&prefix);
    try writer.interface.writeAll(reply);
    try writer.interface.flush();
}

test "DNS retries a truncated UDP answer over TCP" {
    const io = testing.io;
    var server = try (Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const udp = try server.socket.address.bind(io, .{ .mode = .dgram });
    defer udp.close(io);
    var config: stub.Config = .{};
    config.servers[0] = udp.address;
    config.server_count = 1;
    var datagram = try io.concurrent(serveTruncated, .{ io, udp });
    defer datagram.cancel(io) catch {};
    var stream = try io.concurrent(serveTcp, .{ io, &server });
    defer stream.cancel(io) catch {};
    var addresses: [2]Io.net.IpAddress = undefined;
    try testing.expectEqual(@as(usize, 2), try stub.query(io, "truncated.example", 80, .ip4, &addresses, &config));
    try datagram.await(io);
    try stream.await(io);
}

test "DNS address selection honors usable routes matching scopes and precedence" {
    const order = @import("ops/resolve/order.zig");
    const v4: Io.net.IpAddress = .{ .ip4 = .loopback(80) };
    const v6: Io.net.IpAddress = .{ .ip6 = .loopback(80) };
    try testing.expect(order.before(order.rank(v4, v4), order.rank(v6, null)));
    try testing.expect(order.before(order.rank(v6, v6), order.rank(v4, v4)));
    const ula = try Io.net.IpAddress.parse("fd00::1", 80);
    const global = try Io.net.IpAddress.parse("2001:db8::1", 80);
    try testing.expect(order.before(order.rank(v4, v4), order.rank(ula, ula)));
    try testing.expect(order.before(order.rank(global, global), order.rank(v4, v4)));
    try testing.expect(order.before(order.rank(v4, v4), order.rank(v6, global)));
    try testing.expect(!order.before(order.rank(v4, v4), order.rank(v4, v4)));
}
