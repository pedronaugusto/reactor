//! The extensions and the embedding API on io_uring itself: native waits
//! on descriptors, processes and wakes, signals, receivers, deadlines and
//! connects against the real kernel, and a host loop driving a runtime
//! through its handle. Linux only; skipped where io_uring is missing or
//! refused.
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const posix = std.posix;
const IpAddress = Io.net.IpAddress;

const reactor = @import("reactor.zig");
const Runtime = reactor.Runtime;
const fiber = @import("fiber.zig");

fn runtime(r: *Runtime, workers: u16) !void {
    if (builtin.os.tag != .linux or !fiber.supported) return error.SkipZigTest;
    r.init(testing.allocator, .{ .workers = workers, .max_tasks = 512, .stack_size = 256 << 10 }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => |e| return e,
    };
    errdefer r.deinit();
    try r.start();
}

fn ms(n: i64) Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(n), .clock = .awake } };
}

fn pipe() ![2]posix.fd_t {
    return Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
}

fn closeAll(fds: []const posix.fd_t) void {
    for (fds) |fd| _ = posix.system.close(fd);
}

fn writeSoon(io: Io, fd: posix.fd_t) Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(2), .awake);
    _ = posix.system.write(fd, "x", 1);
}

test "a native wait on io_uring reports the member another task made ready" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Runtime = undefined;
    try runtime(&r, 2);
    defer r.deinit();
    const io = r.io();
    const a = try pipe();
    defer closeAll(&a);
    const b = try pipe();
    defer closeAll(&b);
    try testing.expectError(error.Timeout, reactor.waitAny(io, &.{ .{ .readable = a[0] }, .{ .readable = b[0] } }, ms(5)));
    var writer = try io.concurrent(writeSoon, .{ io, b[1] });
    try testing.expectEqual(@as(usize, 1), try reactor.waitAny(io, &.{ .{ .readable = a[0] }, .{ .readable = b[0] } }, ms(5000)));
    try writer.await(io);
    // Native: no fallback was taken.
    const before = reactor.fallbacks();
    try reactor.wait(io, .{ .writable = a[1] }, .none);
    try testing.expectEqual(before, reactor.fallbacks());
}

fn signalFromThread(w: *reactor.Wake) void {
    var threaded: Io.Threaded = .init_single_threaded;
    threaded.io().sleep(.fromMilliseconds(5), .awake) catch return;
    w.signal();
}

fn waitWake(io: Io, w: *reactor.Wake) reactor.WaitError!void {
    return reactor.wait(io, .{ .wake = w }, .none);
}

test "a Wake from a thread outside the runtime ends a task's native wait; a cancel ends another" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Runtime = undefined;
    try runtime(&r, 1);
    defer r.deinit();
    const io = r.io();
    var wake = try reactor.Wake.init(io);
    defer wake.deinit(io);
    const thread = try std.Thread.spawn(.{}, signalFromThread, .{&wake});
    defer thread.join();
    try reactor.wait(io, .{ .wake = &wake }, ms(5000));
    var waiting = try io.concurrent(waitWake, .{ io, &wake });
    try io.sleep(.fromMilliseconds(2), .awake);
    try testing.expectError(error.Canceled, waiting.cancel(io));
}

test "a process is waited for on its pidfd in the loop, and a child's own wait reaps it there" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Runtime = undefined;
    try runtime(&r, 1);
    defer r.deinit();
    const io = r.io();
    var child = try std.process.spawn(io, .{ .argv = &.{ "sleep", "0.05" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    var p = try reactor.Process.open(io, child.id.?);
    defer p.close(io);
    try reactor.wait(io, .{ .process = &p }, ms(10_000));
    const wait_lane = r.stats().lanes[@backingInt(Runtime.Lane.wait)];
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
    // The child's wait took no lane thread.
    try testing.expectEqual(wait_lane.running, r.stats().lanes[@backingInt(Runtime.Lane.wait)].running);
}

test "a signal is delivered to a runtime task waiting for it" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Runtime = undefined;
    try runtime(&r, 1);
    defer r.deinit();
    const io = r.io();
    var s = try reactor.Signals.start(io, &.{.user1});
    defer s.stop(io);
    try posix.raise(.USR1);
    try testing.expectEqual(reactor.Signals.Signal.user1, try s.next(io, ms(5000)));
}

/// A connected loopback TCP pair.
fn tcpPair(io: Io) ![2]Io.net.Stream {
    const address: IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var connecting = try io.concurrent(reactor.net.connect, .{ io, &server.socket.address, .{ .timeout = ms(5000) } });
    const accepted = try server.accept(io);
    const connected = try connecting.await(io);
    try testing.expect(connected.timeout_enforced);
    return .{ accepted, connected.stream };
}

test "a receiver on io_uring reads into the pool once the socket is readable" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Runtime = undefined;
    try runtime(&r, 1);
    defer r.deinit();
    const io = r.io();
    const pair = try tcpPair(io);
    defer for (pair) |s| s.close(io);
    var pool: reactor.net.Receiver.Pool = try .init(testing.allocator, io, .{ .buffer_len = 64, .buffers = 2 });
    defer pool.deinit(testing.allocator, io);
    var receiver: reactor.net.Receiver = .init(io, &pool, pair[0].socket.handle);
    defer receiver.deinit(io);
    try testing.expectError(error.Timeout, receiver.next(io, ms(5)));
    var out: [16]u8 = undefined;
    var writer = pair[1].writer(io, &out);
    try writer.interface.writeAll("ring");
    try writer.interface.flush();
    try testing.expectEqualStrings("ring", try receiver.next(io, ms(5000)));
}

test "a native deadline ends a read in the kernel, poisons the socket, and nothing writes the buffer after" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Runtime = undefined;
    try runtime(&r, 0);
    defer r.deinit();
    const io = r.io();
    const pair = try tcpPair(io);
    defer for (pair) |s| s.close(io);
    var deadlines: reactor.net.Deadlines = .init(.fromMilliseconds(5));
    defer deadlines.deinit(io);
    var watch: reactor.net.Deadlines.Watch = .init(pair[0].socket.handle);
    try testing.expect(deadlines.add(io, &watch));
    defer deadlines.remove(io, &watch);
    var buffer: [16]u8 = @splat(0xaa);
    var data: [1][]u8 = .{&buffer};
    const read: Io.Operation = .{ .net_read = .{ .socket_handle = pair[0].socket.handle, .data = &data } };
    const at = Io.Clock.awake.now(io).addDuration(.fromMilliseconds(5));
    try testing.expectError(error.Timeout, deadlines.operate(io, &watch, read, .{ .clock = .awake, .raw = at }));
    @memset(&buffer, 0xdd);
    var send: [1][]const u8 = .{"late"};
    const sent = (try io.operate(.{ .net_write = .{ .socket_handle = pair[1].socket.handle, .data = &send } })).net_write;
    // The peer was aborted: the write may be refused. Either way nothing
    // may reach the buffer.
    if (sent) |_| {} else |_| {}
    try io.sleep(.fromMilliseconds(5), .awake);
    for (buffer) |byte| try testing.expectEqual(@as(u8, 0xdd), byte);
    try testing.expectError(error.Timeout, deadlines.operate(io, &watch, read, .{ .clock = .awake, .raw = at.addDuration(.fromSeconds(60)) }));
}

test "resolve on a runtime is bounded inline; blocking runs on a lane" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Runtime = undefined;
    try runtime(&r, 1);
    defer r.deinit();
    const io = r.io();
    var storage: [4]IpAddress = undefined;
    const found = try reactor.net.resolve(io, "localhost", 80, .{}, &storage);
    try testing.expect(found.len >= 1);
    try testing.expectEqual(@as(u16, 80), found[0].getPort());
    const before = r.stats().lanes[@backingInt(Runtime.Lane.sync)].@"inline";
    try testing.expectEqual(@as(u32, 10), reactor.blocking(io, .sync, double, .{5}));
    try testing.expectEqual(before, r.stats().lanes[@backingInt(Runtime.Lane.sync)].@"inline");
}

fn double(x: u32) u32 {
    return 2 * x;
}

// Embedding: a host that owns its loop.

fn slowCall() u32 {
    Io.Threaded.global_single_threaded.io().sleep(.fromMilliseconds(20), .awake) catch return 0;
    return 7;
}

fn laneTask(io: Io, done: *std.atomic.Value(bool)) void {
    std.debug.assert(reactor.blocking(io, .general, slowCall, .{}) == 7);
    done.store(true, .release);
}

test "a host waiting on the runtime's handle is woken when a lane call ends" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Runtime = undefined;
    try runtime(&r, 0);
    defer r.deinit();
    const io = r.io();
    const handle = try r.backendHandle();
    var done: std.atomic.Value(bool) = .init(false);
    var task = try io.concurrent(laneTask, .{ io, &done });
    const start = Io.Clock.awake.now(io);
    // The host's own loop: wait on the handle as long as the runtime says,
    // then run what is ready.
    while (!done.load(.acquire)) {
        const wait_ms: i32 = if (r.nextTimeout()) |t| @intCast(@divTrunc(t.nanoseconds, std.time.ns_per_ms)) else 5000;
        var fds = [1]posix.pollfd{.{ .fd = handle, .events = posix.POLL.IN, .revents = 0 }};
        _ = try posix.poll(&fds, wait_ms);
        var count: u64 = 0;
        _ = posix.system.read(handle, @ptrCast(&count), 8);
        r.run(.nowait);
    }
    task.await(io);
    // Woken by the lane's completion, not by the host's own timeout.
    try testing.expect(start.durationTo(Io.Clock.awake.now(io)).nanoseconds < 2 * std.time.ns_per_s);
}
