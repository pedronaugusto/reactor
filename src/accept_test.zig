//! Listener lifetime and bounded multishot acceptance on a real ring.
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Runtime = @import("Runtime.zig");
const Accept = @import("backend/uring/Accept.zig");
const Loop = @import("Loop.zig");

const Harness = struct {
    sqe: std.os.linux.io_uring_sqe = undefined,
    submissions: usize = 0,
    completed: usize = 0,
    pub fn entry(h: *Harness) *std.os.linux.io_uring_sqe {
        h.submissions += 1;
        return &h.sqe;
    }
    pub fn submitSingleAccept(h: *Harness, _: *Loop.Op) void {
        h.submissions += 1;
    }
    pub fn complete(h: *Harness, _: *Loop.Op) void {
        h.completed += 1;
    }
};

test "multishot listener cancellation releases its task before the listener record" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var table = try Accept.init(testing.allocator, 2, true);
    defer table.deinit(testing.allocator);
    var h: Harness = .{};
    var a: Loop.Op = .{ .kind = .{ .accept = 17 } };
    var b: Loop.Op = .{ .kind = .{ .accept = 17 } };
    try testing.expect(table.submit(&h, &a));
    try testing.expect(table.submit(&h, &b));
    try testing.expectEqual(@as(usize, 1), h.submissions);
    try testing.expect(table.cancel(&a));
    try testing.expect(table.deliver(&h));
    try testing.expectEqual(@as(usize, 1), h.completed);
    try testing.expectError(error.Canceled, a.result.accept);
    table.close(&h, 17);
    const record = &table.records[1];
    try testing.expect(record.closing);
    const cqe: std.os.linux.io_uring_cqe = .{ .user_data = 0, .res = -@as(i32, @backingInt(std.os.linux.E.CANCELED)), .flags = 0 };
    table.complete(&h, record, cqe, &h);
    try testing.expectEqual(@as(usize, 2), h.completed);
    try testing.expectError(error.SocketNotListening, b.result.accept);
    try testing.expectEqual(@as(i32, -1), record.fd);
}

fn accept(io: Io, server: *Io.net.Server) !Io.net.Stream {
    return server.accept(io);
}

test "a ring keeps at most eight accepted sockets between accepts" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var runtime: Runtime = undefined;
    runtime.init(testing.allocator, .{ .backend = .io_uring, .workers = 0, .max_tasks = 32, .stack_size = 256 << 10 }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer runtime.deinit();
    const io = runtime.io();
    var server = try (Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var first = try io.concurrent(accept, .{ io, &server });
    var first_live = true;
    defer if (first_live) {
        if (first.cancel(io)) |stream| stream.close(io) else |_| {}
    };
    try io.sleep(.fromMilliseconds(1), .awake);
    var clients: [9]Io.net.Stream = undefined;
    var made: usize = 0;
    defer for (clients[0..made]) |stream| stream.close(io);
    for (&clients) |*stream| {
        stream.* = try server.socket.address.connect(io, .{ .mode = .stream });
        made += 1;
    }
    const outcome = first.await(io);
    first_live = false;
    const taken = try outcome;
    defer taken.close(io);
    try io.sleep(.fromMilliseconds(1), .awake);
    const table = &runtime.core.processors[0].loop.backend.io_uring.accepts;
    try testing.expect(table.enabled);
    const listener = for (table.records) |*record| {
        if (record.fd == server.socket.handle) break record;
    } else return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, Accept.bound), listener.count);
    for (0..8) |_| {
        const stream = try server.accept(io);
        stream.close(io);
    }
}
