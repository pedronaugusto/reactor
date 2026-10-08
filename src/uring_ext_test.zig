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
const shakedown = @import("shakedown");

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

test "native provided buffers survive a receive timeout and return after detach" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Runtime = undefined;
    try runtime(&r, 0);
    defer r.deinit();
    const io = r.io();
    const pair = try tcpPair(io);
    defer for (pair) |stream| stream.close(io);
    var pool: reactor.net.Receiver.Pool = try .init(testing.allocator, io, .{ .buffer_len = 64, .buffers = 2 });
    defer pool.deinit(testing.allocator, io);
    if (pool.groups == null) return error.SkipZigTest;
    var receiver: reactor.net.Receiver = .init(io, &pool, pair[0].socket.handle);
    defer receiver.deinit(io);
    try testing.expectError(error.Timeout, receiver.next(io, ms(1)));
    var out: [16]u8 = undefined;
    var writer = pair[1].writer(io, &out);
    try writer.interface.writeAll("provided");
    try writer.interface.flush();
    const bytes = try receiver.next(io, ms(5000));
    try testing.expectEqualStrings("provided", bytes);
    try testing.expect(receiver.native_state != null);
    receiver.release(bytes);
}

test "closing a file removes an idle registration on another ring" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const Scheduler = @import("Scheduler.zig");
    const Cached = struct {
        const Self = @This();
        errand: Scheduler.Errand = .{ .run = run },
        io: Io,
        fd: posix.fd_t,
        done: Io.Event = .unset,
        fn run(errand: *Scheduler.Errand, p: *Scheduler.Processor) void {
            const cached: *Self = @alignCast(@fieldParentPtr("errand", errand)); // safe: the test sends this record
            var byte: [1]u8 = undefined;
            var sqe: std.os.linux.io_uring_sqe = undefined;
            sqe.prep_read(cached.fd, &byte, 0);
            const ring = &p.loop.backend.io_uring;
            ring.files.use(&ring.ring, &sqe);
            cached.done.set(cached.io);
        }
    };
    var r: Runtime = undefined;
    try runtime(&r, 1);
    defer r.deinit();
    const io = r.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "registered", .{ .read = true });
    var open = true;
    defer if (open) file.close(io);
    const ring = &r.core.processors[1].loop.backend.io_uring;
    if (!ring.files.enabled) return error.SkipZigTest;
    var cached: Cached = .{ .io = io, .fd = file.handle };
    r.core.processors[1].send(&cached.errand);
    try cached.done.wait(io);
    try testing.expect(ring.files.contains(file.handle));
    file.close(io);
    open = false;
    try testing.expect(!ring.files.contains(file.handle));
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

/// User threads only: io_uring can create PF_IO_WORKER kernel threads.
/// The flag is defined in Linux's include/linux/sched.h.
fn threadCount() !usize {
    var buffer: [4096]u8 = undefined;
    const io = Io.Threaded.global_single_threaded.io();
    const dir = try Io.Dir.openDirAbsolute(io, "/proc/self/task", .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |entry| {
        var path: [64]u8 = undefined;
        const name = try std.mem.print(&path, "{s}/stat", .{entry.name});
        const text = dir.readFile(io, name, &buffer) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        const end = std.mem.findScalarLast(u8, text, ')') orelse return error.NoThreadCount;
        var fields = std.mem.tokenizeScalar(u8, text[end + 1 ..], ' ');
        for (0..6) |_| _ = fields.next() orelse return error.NoThreadCount;
        const flags = try std.fmt.parseInt(u64, fields.next() orelse return error.NoThreadCount, 10);
        if (flags & 0x10 == 0) count += 1;
    }
    return count;
}

fn conformance(io: Io, failure: *shakedown.conformance.Failure, done: *std.atomic.Value(bool)) anyerror!void {
    defer done.store(true, .release);
    return shakedown.conformance.run(testing.allocator, io, .{ .failure = failure });
}

test "a runtime with no thread of its own runs the conformance suite in 1 ms frames, and starts no thread" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (!fiber.supported) return error.SkipZigTest;
    const before = try threadCount();
    var r: Runtime = undefined;
    r.init(testing.allocator, .{ .workers = 0, .offload = .none, .max_tasks = 512, .stack_size = 256 << 10 }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => |e| return e,
    };
    defer r.deinit();
    try r.start();
    const io = r.io();
    var failure: shakedown.conformance.Failure = undefined;
    var done: std.atomic.Value(bool) = .init(false);
    var suite = try io.concurrent(conformance, .{ io, &failure, &done });
    defer _ = suite.cancel(io) catch {};
    // The host's frames: a millisecond of the runtime's time each.
    var frames: usize = 0;
    while (!done.load(.acquire)) : (frames += 1) {
        r.run(.{ .until = Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = .fromMilliseconds(1), .clock = .awake }) });
        try testing.expectEqual(before, try threadCount());
    }
    suite.await(io) catch |err| {
        std.debug.print("{s}: {t}\n", .{ failure.check, failure.err });
        return err;
    };
    try testing.expect(frames > 0);
}

fn rawNop(_: void, sqe: *std.os.linux.io_uring_sqe) void {
    sqe.prep_nop();
}

const RawRead = struct { fd: posix.fd_t, buffer: []u8 };
fn rawRead(request: RawRead, sqe: *std.os.linux.io_uring_sqe) void {
    sqe.prep_read(request.fd, request.buffer, std.math.maxInt(u64));
}

fn rawMultishot(_: void, sqe: *std.os.linux.io_uring_sqe) void {
    sqe.prep_recv(0, &.{}, 0);
    sqe.ioprio = std.os.linux.IORING_RECV_MULTISHOT;
}

test "kernel submit returns one completion and rejects a multishot lifetime" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Runtime = undefined;
    try runtime(&r, 0);
    defer r.deinit();
    try testing.expectEqual(@as(i32, 0), try reactor.kernel.submit(r.io(), rawNop, {}, .none));
    try testing.expectError(error.Unsupported, reactor.kernel.submit(r.io(), rawMultishot, {}, .none));
}

test "kernel submit reaps a timed out read before its buffer is poisoned" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Runtime = undefined;
    try runtime(&r, 0);
    defer r.deinit();
    const fds = try pipe();
    defer closeAll(&fds);
    var buffer: [8]u8 = undefined;
    try testing.expectError(error.Timeout, reactor.kernel.submit(r.io(), rawRead, RawRead{ .fd = fds[0], .buffer = &buffer }, ms(1)));
    @memset(&buffer, 0xa5);
    try testing.expectEqual(@as(usize, 8), posix.system.write(fds[1], "latebyte", 8));
    try r.io().sleep(.fromMilliseconds(1), .awake);
    try testing.expectEqualSlices(u8, &@as([8]u8, @splat(0xa5)), &buffer);
}

fn pendingRead(io: Io, socket: Io.net.Socket.Handle, timeout: Io.Timeout) !usize {
    var byte: [1]u8 = undefined;
    var data: [1][]u8 = .{&byte};
    const result = try io.operateTimeout(.{ .net_read = .{ .socket_handle = socket, .data = &data } }, timeout);
    return (try result.net_read).data_len;
}

test "a socket close reports EOF while unrelated reads remain pending" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Runtime = undefined;
    try runtime(&r, 0);
    defer r.deinit();
    const io = r.io();
    const pair = try tcpPair(io);
    defer pair[0].close(io);
    var client_open = true;
    defer if (client_open) pair[1].close(io);
    const other = try tcpPair(io);
    defer for (other) |stream| stream.close(io);
    const out: [1][]const u8 = .{"x"};
    _ = try (try io.operate(.{ .net_write = .{ .socket_handle = pair[1].socket.handle, .data = &out } })).net_write;
    try testing.expectEqual(@as(usize, 1), try pendingRead(io, pair[0].socket.handle, ms(5000)));
    var peer = try io.concurrent(pendingRead, .{ io, pair[0].socket.handle, ms(100) });
    defer _ = peer.cancel(io) catch {};
    var unrelated = try io.concurrent(pendingRead, .{ io, other[0].socket.handle, Io.Timeout.none });
    defer _ = unrelated.cancel(io) catch {};
    r.run(.nowait);
    pair[1].close(io);
    client_open = false;
    try testing.expectEqual(@as(usize, 0), try peer.await(io));
}
