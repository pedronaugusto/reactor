//! A stream socket's messages with their control data, on `Io.Threaded` and
//! on a runtime: data and a descriptor passed as a control message
//! (`SCM_RIGHTS`) over a pair of Unix stream sockets, a receive that waits
//! for the sender, and one that ends at its timeout.
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const Io = std.Io;

const reactor = @import("reactor.zig");
const message = reactor.net.message;
const supported = @import("Scheduler.zig").supported;

const is_windows = builtin.os.tag == .windows;

fn ms(n: i64) Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(n), .clock = .awake } };
}

const small: reactor.Runtime.Options = .{ .max_tasks = 256, .stack_size = .fromRaw(256 << 10), .offload = .none };

/// A control message holding one descriptor.
const Rights = extern struct {
    header: posix.system.cmsghdr align(@alignOf(usize)),
    fd: posix.fd_t,
    pad: [@sizeOf(usize) - @sizeOf(posix.fd_t) % @sizeOf(usize)]u8 = @splat(0),
};

fn pair() ![2]posix.fd_t {
    var ends: [2]posix.fd_t = undefined;
    if (posix.errno(posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &ends)) != .SUCCESS) return error.SocketPair;
    return ends;
}

fn closeAll(fds: []const posix.fd_t) void {
    for (fds) |fd| _ = posix.system.close(fd);
}

/// Sends "hello" with a pipe's write end as a control message, and reads
/// both back: the data, and a descriptor that writes into the same pipe.
fn passesData(io: Io) !void {
    const ends = try pair();
    defer closeAll(&ends);
    var pipe_ends: [2]posix.fd_t = undefined;
    if (posix.errno(posix.system.pipe(&pipe_ends)) != .SUCCESS) return error.Pipe;
    defer closeAll(&pipe_ends);

    var rights: Rights = .{
        .header = .{ .len = @offsetOf(Rights, "fd") + @sizeOf(posix.fd_t), .level = posix.SOL.SOCKET, .type = 1 }, // SCM_RIGHTS
        .fd = pipe_ends[1],
    };
    const sent = try message.send(io, ends[0], &.{"hello"}, std.mem.asBytes(&rights)[0..rights.header.len], ms(5_000));
    try testing.expectEqual(@as(usize, 5), sent);

    var data: [16]u8 = undefined;
    var room: Rights align(@alignOf(usize)) = undefined;
    const got = try message.receive(io, ends[1], &.{&data}, std.mem.asBytes(&room), ms(5_000));
    try testing.expectEqualStrings("hello", data[0..got.data_len]);
    try testing.expect(!got.control_truncated);
    try testing.expect(got.control_len >= @offsetOf(Rights, "fd") + @sizeOf(posix.fd_t));
    try testing.expectEqual(@as(c_int, posix.SOL.SOCKET), @as(c_int, @intCast(room.header.level)));
    defer _ = posix.system.close(room.fd);

    // The descriptor that came is the pipe's write end.
    try testing.expectEqual(@as(isize, 1), @as(isize, @bitCast(posix.system.write(room.fd, "x", 1))));
    var byte: [1]u8 = undefined;
    try testing.expectEqual(@as(isize, 1), @as(isize, @bitCast(posix.system.read(pipe_ends[0], &byte, 1))));
}

/// A receive with nothing there ends at its timeout, and one the peer
/// answers later is woken by it.
fn waitsForData(io: Io) !void {
    const ends = try pair();
    defer closeAll(&ends);
    var data: [16]u8 = undefined;
    try testing.expectError(error.Timeout, message.receive(io, ends[1], &.{&data}, &.{}, ms(20)));

    var later = try io.concurrent(struct {
        fn send(inner: Io, fd: posix.fd_t) !void {
            try inner.sleep(.fromMilliseconds(20), .awake);
            _ = try message.send(inner, fd, &.{"late"}, &.{}, ms(5_000));
        }
    }.send, .{ io, ends[0] });
    const got = try message.receive(io, ends[1], &.{&data}, &.{}, ms(5_000));
    try testing.expectEqualStrings("late", data[0..got.data_len]);
    try later.await(io);

    // The end of the stream reads as no data.
    _ = posix.system.shutdown(ends[0], posix.SHUT.WR);
    const end = try message.receive(io, ends[1], &.{&data}, &.{}, ms(5_000));
    try testing.expectEqual(@as(usize, 0), end.data_len);
}

fn both(io: Io) !void {
    try passesData(io);
    try waitsForData(io);
}

test "messages carry data and control data, on Threaded and on a runtime" {
    if (is_windows) return error.SkipZigTest;
    try both(testing.io);
    if (!supported) return;
    var r: reactor.Runtime = undefined;
    try r.init(testing.allocator, small);
    defer r.deinit();
    try r.start();
    var task = try r.io().concurrent(both, .{r.io()});
    try task.await(r.io());
}

test {
    _ = @import("sys/message.zig");
}
