//! Linux's kernel record layer (kTLS) under reactor's calls: TLS 1.3 with
//! AES-128-GCM, the peer's half played here (RFC 8446 5.2). A file a
//! runtime's `netWriteFile` sends to a socket whose write direction is the
//! kernel's goes out as records the peer opens. The receive path stopping
//! for new keys: after a KeyUpdate the kernel answers `KeyExpired` until the
//! next keys are installed, and `net.message.receive` given a `Wake` waits
//! for the record layer's owner to signal it (Linux 6.14 or later; before it
//! the kernel does not stop). Skipped where the kernel has no record layer.
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const Io = std.Io;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const net = Io.net;

const reactor = @import("reactor.zig");
const message = reactor.net.message;
const supported = @import("Scheduler.zig").supported;

const is_linux = builtin.os.tag == .linux;

const sol_tls = 282;
const tls_tx = 1;
const tls_rx = 2;
const tls_get_record_type = 2;
const tcp_ulp = 31;
const cipher_aes_gcm_128 = 51;
const tls_1_3 = 0x0304;

const application_data = 23;
const handshake = 22;

/// The kernel's `tls12_crypto_info_aes_gcm_128`.
const CryptoInfo = extern struct {
    version: u16 = tls_1_3,
    cipher_type: u16 = cipher_aes_gcm_128,
    iv: [8]u8,
    key: [16]u8,
    salt: [4]u8,
    rec_seq: [8]u8 = @splat(0),
};

/// One epoch's keys, as both ends hold them.
const Keys = struct {
    key: [16]u8,
    iv: [12]u8,
    sequence: u64 = 0,

    fn of(seed: u8) Keys {
        var k: Keys = .{ .key = undefined, .iv = undefined };
        for (&k.key, 0..) |*b, i| b.* = seed +% @as(u8, @intCast(i));
        for (&k.iv, 0..) |*b, i| b.* = seed ^ @as(u8, @intCast(i * 7));
        return k;
    }

    fn info(k: Keys) CryptoInfo {
        return .{ .salt = k.iv[0..4].*, .iv = k.iv[4..12].*, .key = k.key };
    }

    /// One record of `content` of `kind`, sealed under the next sequence number.
    fn seal(k: *Keys, out: []u8, kind: u8, content: []const u8) []const u8 {
        const inner = content.len + 1;
        const length = inner + Aes128Gcm.tag_length;
        const header = [5]u8{ application_data, 0x03, 0x03, @intCast(length >> 8), @truncate(length) };
        @memcpy(out[0..5], &header);
        var plain: [256]u8 = undefined;
        @memcpy(plain[0..content.len], content);
        plain[content.len] = kind;
        var tag: [Aes128Gcm.tag_length]u8 = undefined;
        Aes128Gcm.encrypt(out[5..][0..inner], &tag, plain[0..inner], &header, k.nonce(), k.key);
        @memcpy(out[5 + inner ..][0..tag.len], &tag);
        return out[0 .. 5 + length];
    }

    /// One record's content opened into `out`, its inner type returned.
    fn open(k: *Keys, header: [5]u8, body: []const u8, out: []u8) !struct { u8, []const u8 } {
        if (header[0] != application_data or body.len <= Aes128Gcm.tag_length) return error.NotARecord;
        const inner = body.len - Aes128Gcm.tag_length;
        try Aes128Gcm.decrypt(out[0..inner], body[0..inner], body[inner..][0..Aes128Gcm.tag_length].*, &header, k.nonce(), k.key);
        var end = inner;
        while (end > 0 and out[end - 1] == 0) end -= 1;
        if (end == 0) return error.NotARecord;
        return .{ out[end - 1], out[0 .. end - 1] };
    }

    /// The next record's nonce, the sequence number counted past it.
    fn nonce(k: *Keys) [12]u8 {
        var n = k.iv;
        const sequence: [8]u8 = @bitCast(std.mem.nativeToBig(u64, k.sequence));
        for (n[4..], sequence) |*b, s| b.* ^= s;
        k.sequence += 1;
        return n;
    }
};

fn install(fd: posix.fd_t, keys: Keys) !void {
    return installDirection(fd, tls_rx, keys);
}

fn installDirection(fd: posix.fd_t, direction: u32, keys: Keys) !void {
    const info = keys.info();
    if (posix.errno(posix.system.setsockopt(fd, sol_tls, direction, std.mem.asBytes(&info), @sizeOf(CryptoInfo))) != .SUCCESS) return error.InstallRefused;
}

fn upperLayer(fd: posix.fd_t) bool {
    const ulp = "tls";
    return posix.errno(posix.system.setsockopt(fd, posix.IPPROTO.TCP, tcp_ulp, ulp, ulp.len)) == .SUCCESS;
}

/// A connected loopback TCP pair, the second end's receive path the kernel's.
fn connected() ![2]posix.fd_t {
    const listener: posix.fd_t = @intCast(posix.system.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0));
    defer _ = posix.system.close(listener);
    var address: posix.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    if (posix.errno(posix.system.bind(listener, @ptrCast(&address), len)) != .SUCCESS) return error.Bind;
    if (posix.errno(posix.system.listen(listener, 1)) != .SUCCESS) return error.Listen;
    if (posix.errno(posix.system.getsockname(listener, @ptrCast(&address), &len)) != .SUCCESS) return error.Name;
    const client: posix.fd_t = @intCast(posix.system.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0));
    errdefer _ = posix.system.close(client);
    if (posix.errno(posix.system.connect(client, @ptrCast(&address), len)) != .SUCCESS) return error.Connect;
    const server: posix.fd_t = @intCast(posix.system.accept(listener, null, null));
    if (server < 0) return error.Accept;
    return .{ client, server };
}

fn sendAll(fd: posix.fd_t, bytes: []const u8) !void {
    if (posix.system.write(fd, bytes.ptr, bytes.len) != bytes.len) return error.ShortWrite;
}

/// Room for one `TLS_GET_RECORD_TYPE` control message.
const RecordType = extern struct {
    header: posix.system.cmsghdr align(@alignOf(usize)),
    kind: u8,
    pad: [@sizeOf(usize) - 1]u8,
};

fn ms(n: i64) Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(n), .clock = .awake } };
}

const small: reactor.Runtime.Options = .{ .max_tasks = 64, .stack_size = .fromRaw(256 << 10), .offload = .none };

/// A connection whose receive path the kernel has stopped for new keys: a
/// record of data, a KeyUpdate and a record under the next keys sent, the
/// first two read. Skips where the kernel has no record layer, or one that
/// does not stop (before Linux 6.14 the next record fails to open).
const Stopped = struct {
    ends: [2]posix.fd_t,
    next: Keys,

    fn open(io: Io) !Stopped {
        const ends = connected() catch return error.SkipZigTest;
        errdefer for (ends) |fd| {
            _ = posix.system.close(fd);
        };
        if (!upperLayer(ends[1])) return error.SkipZigTest;
        var first = Keys.of(1);
        var next = Keys.of(2);
        install(ends[1], first) catch return error.SkipZigTest;

        var record: [512]u8 = undefined;
        try sendAll(ends[0], first.seal(&record, application_data, "before"));
        try sendAll(ends[0], first.seal(&record, handshake, &.{ 24, 0, 0, 1, 0 })); // KeyUpdate, update_not_requested
        try sendAll(ends[0], next.seal(&record, application_data, "after"));

        var data: [64]u8 = undefined;
        var room: RecordType = undefined;
        const before = try message.receive(io, ends[1], &.{&data}, std.mem.asBytes(&room), .{ .timeout = ms(5_000) });
        try testing.expectEqualStrings("before", data[0..before.data_len]);
        try testing.expectEqual(@as(u8, application_data), room.kind);
        const update = try message.receive(io, ends[1], &.{&data}, std.mem.asBytes(&room), .{ .timeout = ms(5_000) });
        try testing.expectEqual(@as(usize, 5), update.data_len);
        try testing.expectEqual(@as(u8, handshake), room.kind);
        // With no wake the stop is answered at once.
        _ = message.receive(io, ends[1], &.{&data}, std.mem.asBytes(&room), .{ .timeout = ms(5_000) }) catch |err| switch (err) {
            error.KeyExpired => return .{ .ends = ends, .next = next },
            error.BadMessage => return error.SkipZigTest,
            else => return err,
        };
        return error.NoStop;
    }

    fn close(s: *Stopped) void {
        for (s.ends) |fd| _ = posix.system.close(fd);
    }
};

/// The owner's half: the next keys installed a while after the receive
/// stopped, then the wake signaled.
fn installLater(io: Io, fd: posix.fd_t, next: Keys, keys: *reactor.Wake, installed: *std.atomic.Value(bool)) !void {
    try io.sleep(.fromMilliseconds(30), .awake);
    try install(fd, next);
    installed.store(true, .release);
    keys.signal();
}

fn waitsForKeys(io: Io) !void {
    var stopped = try Stopped.open(io);
    defer stopped.close();
    var keys = try reactor.Wake.init(io);
    defer keys.deinit(io);
    var installed: std.atomic.Value(bool) = .init(false);
    var owner = try io.concurrent(installLater, .{ io, stopped.ends[1], stopped.next, &keys, &installed });
    // glint-ignore: Z026 -- cleanup should the receive fail first; the owner's own result is judged by `await` below
    defer owner.cancel(io) catch {};

    var data: [64]u8 = undefined;
    var room: RecordType = undefined;
    const after = try message.receive(io, stopped.ends[1], &.{&data}, std.mem.asBytes(&room), .{ .timeout = ms(5_000), .rekey = &keys });
    try testing.expect(installed.load(.acquire));
    try testing.expectEqualStrings("after", data[0..after.data_len]);
    try testing.expectEqual(@as(u8, application_data), room.kind);
    try owner.await(io);
}

fn endsWhileStopped(io: Io) !void {
    var stopped = try Stopped.open(io);
    defer stopped.close();
    var keys = try reactor.Wake.init(io);
    defer keys.deinit(io);
    var data: [64]u8 = undefined;
    var room: RecordType = undefined;

    // Nothing signals: the receive ends at its timeout.
    try testing.expectError(error.Timeout, message.receive(io, stopped.ends[1], &.{&data}, std.mem.asBytes(&room), .{ .timeout = ms(30), .rekey = &keys }));

    // A signal with the keys still not in is tried once and waited past.
    keys.signal();
    try testing.expectError(error.Timeout, message.receive(io, stopped.ends[1], &.{&data}, std.mem.asBytes(&room), .{ .timeout = ms(30), .rekey = &keys }));

    // The peer ends the stream: the stopped socket polls readable, and the
    // receive answers the stop for its owner instead of waiting on.
    _ = posix.system.shutdown(stopped.ends[0], posix.SHUT.WR);
    try testing.expectError(error.KeyExpired, message.receive(io, stopped.ends[1], &.{&data}, std.mem.asBytes(&room), .{ .timeout = ms(5_000), .rekey = &keys }));
}

fn all(io: Io) !void {
    try waitsForKeys(io);
    try endsWhileStopped(io);
}

test "a receive stopped for new keys waits for its wake, on Threaded and on a runtime" {
    if (!is_linux) return error.SkipZigTest;
    try all(testing.io);
    if (!supported) return;
    var r: reactor.Runtime = undefined;
    try r.init(testing.allocator, small);
    defer r.deinit();
    try r.start();
    var task = try r.io().concurrent(all, .{r.io()});
    try task.await(r.io());
}

const file_size = 300 << 10;

fn byteAt(i: usize) u8 {
    return @truncate((i *% 2654435761) >> 11);
}

/// Reads the raw records off `fd` to the end of the stream, opens each,
/// and checks that together they hold the file.
fn openAll(io: Io, fd: posix.fd_t, keys: Keys) !void {
    var opener = keys;
    var stream: net.Stream = .{ .socket = .{ .handle = fd, .address = .{ .ip4 = .loopback(0) } } };
    var buffer: [1 << 15]u8 = undefined;
    var reader = stream.reader(io, &buffer);
    var plain: [1 << 15]u8 = undefined;
    var at: usize = 0;
    while (true) {
        const header = (reader.interface.takeArray(5) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        }).*;
        const length = std.mem.readInt(u16, header[3..5], .big);
        const body = try reader.interface.take(length);
        const kind, const content = try opener.open(header, body, &plain);
        try testing.expectEqual(@as(u8, application_data), kind);
        for (content, 0..) |b, i| if (b != byteAt(at + i)) return error.Corrupt;
        at += content.len;
    }
    try testing.expectEqual(@as(usize, file_size), at);
}

fn sendsSealed(io: Io) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "sealed", .{ .read = true });
    defer file.close(io);
    var chunk: [4096]u8 = undefined;
    var at: usize = 0;
    while (at < file_size) : (at += chunk.len) {
        for (&chunk, 0..) |*b, i| b.* = byteAt(at + i);
        try file.writePositionalAll(io, &chunk, at);
    }

    const ends = connected() catch return error.SkipZigTest;
    defer for (ends) |fd| {
        _ = posix.system.close(fd);
    };
    if (!upperLayer(ends[0])) return error.SkipZigTest;
    const keys = Keys.of(3);
    installDirection(ends[0], tls_tx, keys) catch return error.SkipZigTest;

    var opening = try io.concurrent(openAll, .{ io, ends[1], keys });
    // glint-ignore: Z026 -- cleanup should the send fail first; the peer's own result is judged by `await` below
    defer opening.cancel(io) catch {};
    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    while (true) {
        _ = io.vtable.netWriteFile(io.userdata, ends[0], "", &file_reader, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
    }
    _ = posix.system.shutdown(ends[0], posix.SHUT.WR);
    try opening.await(io);
}

test "a file sent by the kernel to a socket whose writes the kernel seals goes out as records" {
    if (!is_linux or !supported) return error.SkipZigTest;
    var r: reactor.Runtime = undefined;
    try r.init(testing.allocator, small);
    defer r.deinit();
    try r.start();
    var task = try r.io().concurrent(sendsSealed, .{r.io()});
    try task.await(r.io());
}
