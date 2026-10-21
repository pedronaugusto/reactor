//! A file sent to a socket by the kernel through a runtime's `netWriteFile`
//! (Linux and Darwin): over loopback TCP with a small send buffer and a
//! slow reader, the socket in non-blocking mode and in blocking mode, on
//! each backend the system has; what the writer and the reader hold goes
//! first; the end of the file; and where the kernel's call is not taken.
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const Io = std.Io;
const net = Io.net;

const reactor = @import("reactor.zig");
const supported = @import("Scheduler.zig").supported;
const sendfile = @import("sys/sendfile.zig");

const small: reactor.Runtime.Options = .{ .max_tasks = 64, .stack_size = .fromRaw(256 << 10), .offload = .none };

const size = 1 << 20;

const backends: []const reactor.Runtime.Options = switch (builtin.os.tag) {
    .linux => &.{ with(.io_uring), with(.epoll) },
    else => &.{with(.kqueue)},
};

fn with(backend: @FieldType(reactor.Runtime.Options, "backend")) reactor.Runtime.Options {
    var options = small;
    options.backend = backend;
    return options;
}

fn setMode(fd: posix.fd_t, blocking: bool) !void {
    const bit: usize = 1 << @bitOffsetOf(posix.O, "NONBLOCK");
    const old = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    if (posix.errno(old) != .SUCCESS) return error.Fcntl;
    const flags = if (blocking) @as(usize, @intCast(old)) & ~bit else @as(usize, @intCast(old)) | bit;
    if (posix.errno(posix.system.fcntl(fd, posix.F.SETFL, flags)) != .SUCCESS) return error.Fcntl;
}

fn setBuffer(fd: posix.fd_t, option: u32, bytes: c_int) void {
    _ = posix.system.setsockopt(fd, posix.SOL.SOCKET, option, std.mem.asBytes(&bytes), @sizeOf(c_int));
}

/// The file's contents: a pattern no two nearby offsets share.
fn byteAt(i: usize) u8 {
    return @truncate((i *% 2654435761) >> 13);
}

fn makeFile(io: Io, dir: Io.Dir) !Io.File {
    const file = try dir.createFile(io, "sent", .{ .read = true });
    errdefer file.close(io);
    var chunk: [4096]u8 = undefined;
    var at: usize = 0;
    while (at < size) : (at += chunk.len) {
        for (&chunk, 0..) |*b, i| b.* = byteAt(at + i);
        try file.writePositionalAll(io, &chunk, at);
    }
    return file;
}

/// Reads to the end of the stream in small reads, sleeping now and then so
/// the sender finds the socket full, and checks every byte.
fn drain(io: Io, stream: net.Stream, header: []const u8) !void {
    var buffer: [8192]u8 = undefined;
    var reader = stream.reader(io, &buffer);
    const head = try reader.interface.take(header.len);
    try testing.expectEqualStrings(header, head);
    var at: usize = 0;
    var reads: usize = 0;
    while (true) {
        const got = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        for (got, 0..) |b, i| if (b != byteAt(at + i)) return error.Corrupt;
        at += got.len;
        reader.interface.toss(got.len);
        reads += 1;
        if (reads % 64 == 0) try io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(@as(usize, size), at);
}

/// Sends the file with `header` before it, through the slot itself (a
/// `Writer` would fall back to copying through memory unseen).
fn sendAll(io: Io, socket: net.Socket.Handle, header: []const u8, file_reader: *Io.File.Reader) !void {
    // Some of the file in the reader's buffer goes first, with the header.
    _ = try file_reader.interface.peek(100);
    const buffered = file_reader.interface.buffered().len;
    var first = true;
    while (true) {
        const n = io.vtable.netWriteFile(io.userdata, socket, if (first) header else "", file_reader, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (first) try testing.expectEqual(header.len + buffered, n);
        first = false;
    }
    try testing.expectEqual(@as(u64, size), file_reader.pos);
}

fn exchange(io: Io, file: Io.File, blocking: bool) !void {
    var listener = try (net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const client = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    const server = try listener.accept(io);
    defer server.close(io);
    try setMode(client.socket.handle, blocking);
    setBuffer(client.socket.handle, posix.SO.SNDBUF, 16 << 10);

    var reading = try io.concurrent(drain, .{ io, server, "head" });
    // glint-ignore: Z026 -- cleanup should the send fail first; the reader's own result is judged by `await` below
    defer reading.cancel(io) catch {};
    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    try sendAll(io, client.socket.handle, "head", &file_reader);
    try client.shutdown(io, .send);
    try reading.await(io);
}

fn modes(io: Io, file: Io.File) !void {
    try exchange(io, file, false);
    try exchange(io, file, true);
}

test "a file goes to a socket by the kernel, in non-blocking and in blocking mode, on every backend" {
    if (!sendfile.supported or !supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try makeFile(testing.io, tmp.dir);
    defer file.close(testing.io);
    for (backends) |options| {
        var r: reactor.Runtime = undefined;
        r.init(testing.allocator, options) catch |err| switch (err) {
            error.BackendUnavailable => continue,
            else => return err,
        };
        defer r.deinit();
        try r.start();
        var task = try r.io().concurrent(modes, .{ r.io(), file });
        try task.await(r.io());
    }
}

test "a reader at the end of its file ends the stream, and one the kernel cannot send from is copied" {
    if (!sendfile.supported or !supported) return error.SkipZigTest;
    var r: reactor.Runtime = undefined;
    try r.init(testing.allocator, small);
    defer r.deinit();
    try r.start();
    const io = r.io();
    var task = try io.concurrent(struct {
        fn run(inner: Io) !void {
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            const file = try tmp.dir.createFile(inner, "empty", .{ .read = true });
            defer file.close(inner);
            var listener = try (net.IpAddress{ .ip4 = .loopback(0) }).listen(inner, .{ .reuse_address = true });
            defer listener.deinit(inner);
            const client = try listener.socket.address.connect(inner, .{ .mode = .stream });
            defer client.close(inner);
            const server = try listener.accept(inner);
            defer server.close(inner);
            var buffer: [64]u8 = undefined;

            var positional = file.reader(inner, &buffer);
            try testing.expectError(error.EndOfStream, inner.vtable.netWriteFile(inner.userdata, client.socket.handle, "", &positional, .unlimited));
            try testing.expectEqual(@as(?u64, 0), positional.size);

            // A streaming reader: Linux sends from the file's own position,
            // Darwin's call has none and the writer copies.
            var streaming = file.readerStreaming(inner, &buffer);
            const result = inner.vtable.netWriteFile(inner.userdata, client.socket.handle, "", &streaming, .unlimited);
            if (sendfile.needs_offset) try testing.expectError(error.Unimplemented, result) else try testing.expectError(error.EndOfStream, result);

            // Nothing asked for, nothing sent.
            try testing.expectEqual(@as(usize, 0), try inner.vtable.netWriteFile(inner.userdata, client.socket.handle, "", &positional, .nothing));
        }
    }.run, .{io});
    try task.await(io);
}
