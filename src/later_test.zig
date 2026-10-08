//! LATER ownership, bounded scheduling, replay and native kernel evidence.
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const linux = std.os.linux;
const shakedown = @import("shakedown");
const reactor = @import("reactor.zig");
const Loop = reactor.Loop;
const Runtime = reactor.Runtime;
const Driver = @import("testing/Driver.zig");
const perform = @import("ops/perform.zig");
const pending = @import("backend/pending.zig");
const UringState = @import("backend/op.zig").UringState;

fn native(r: *Runtime, backend: Loop.Backend) !void {
    r.init(testing.allocator, .{ .workers = 0, .backend = backend, .max_tasks = 64 }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => return err,
    };
}
fn ms(value: i64) Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(value), .clock = .awake } };
}

test "later: callback delivery permits reuse and never also enters reap" {
    const Count = struct {
        const Self = @This();
        count: usize = 0,
        fn done(loop: *Loop, op: *Loop.Op) void {
            const count: *Self = @ptrFromInt(op.user_data); // safe: this test retains the counter through delivery
            count.count += 1;
            if (count.count < 8) {
                op.kind = .{ .timer = .now(testing.io, .awake) };
                loop.submit(op) catch @panic("bounded callback resubmission failed");
            }
        }
    };
    var loop: Loop = undefined;
    loop.init(testing.allocator, .{ .max_ops = 4 }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer loop.deinit(testing.allocator);
    var count: Count = .{};
    var op: Loop.Op = .{ .kind = .{ .timer = .now(testing.io, .awake) }, .callback = Count.done, .user_data = @intFromPtr(&count) }; // safe: retained through every callback
    try loop.submit(&op);
    while (count.count < 8) _ = try loop.run(.once);
    var reaped: [1]*Loop.Op = undefined;
    try testing.expectEqual(@as(usize, 0), loop.reap(&reaped).len);
    try testing.expectEqual(@as(u32, 0), loop.in_flight);
}

fn ownershipProperty(_: void, c: *shakedown.Case) !void {
    // Exhaust every ordering, including a notification before the primary
    // and a linked timer before either. A frame is free only after all 3.
    var state: UringState = .{ .timeout_pending = true };
    var order = [_]u8{ 0, 1, 2 };
    for (0..3) |i| {
        const j = i + @as(usize, @intCast(c.source.below(2 - i)));
        std.mem.swap(u8, &order[i], &order[j]);
    }
    for (order, 0..) |event, i| {
        switch (event) {
            0 => state.completed(.{ .user_data = 0, .res = 100, .flags = linux.IORING_CQE_F_MORE }),
            1 => state.completed(.{ .user_data = 0, .res = 0, .flags = linux.IORING_CQE_F_NOTIF }),
            2 => state.timeout_pending = false,
            else => unreachable, // unreachable: only three event kinds
        }
        try testing.expectEqual(i == 2, state.ready());
    }
    try testing.expectEqual(@as(i32, 100), state.primary.res);
}

test "later: linked timeout and zero-copy notifications retain every completion ordering" {
    try shakedown.check(testing.allocator, {}, ownershipProperty, .{ .cases = 64, .regressions = &.{ "0:0", "1:0", "2:1" } });
}

fn fakeRequest(io: Io) anyerror!usize {
    const core = Runtime.recognize(io).?;
    var byte: [1]u8 = undefined;
    const handle: Io.File.Handle = if (builtin.os.tag == .windows) @ptrFromInt(42) else 42; // safe: the fake never dereferences a descriptor
    var op: Loop.Op = .{ .kind = .{ .read_at = .{ .file = handle, .buffer = &byte, .offset = 0 } } };
    try perform.run(&core.core.scheduler, &op, .{});
    return op.result.read_at;
}

fn raceProperty(_: void, c: *shakedown.Case) !void {
    var d: Driver = undefined;
    try d.initSource(c.gpa, c.source, .{ .max_tasks = 32, .stack_size = 128 << 10, .offload = .none });
    defer d.deinit();
    const io = d.io();
    const n = 1 + c.source.below(7);
    var tasks: [8]Io.Future(anyerror!usize) = undefined;
    for (tasks[0..@intCast(n)]) |*task| task.* = try io.concurrent(fakeRequest, .{io});
    for (tasks[0..@intCast(n)]) |*task| {
        const result = if (c.source.below(1) == 0) task.await(io) else task.cancel(io);
        if (result) |got| try testing.expectEqual(@as(usize, 0), got) else |err| try testing.expectEqual(error.Canceled, err);
    }
    try testing.expectEqual(@as(usize, 0), d.fake.ops.items.len);
    try testing.expectEqual(@as(u32, 0), d.runtime.stats().tasks);
    try testing.expectEqual(@as(u32, 0), d.runtime.core.processors[0].loop.in_flight);
}

test "later: cancellation schedules share a shrinkable source with the production scheduler" {
    try shakedown.check(testing.allocator, {}, raceProperty, .{ .cases = 128, .regressions = &.{ "0", "7:1:0:1" } });
}

fn witness(_: void, c: *shakedown.Case) !void {
    var d: Driver = undefined;
    try d.initSource(c.gpa, c.source, .{ .max_tasks = 8, .stack_size = 128 << 10, .offload = .none });
    defer d.deinit();
    var future = try d.io().concurrent(fakeRequest, .{d.io()});
    _ = try future.await(d.io());
    if (c.source.below(1) == 1) return error.ExpectedWitness;
}

test "later: a scheduler property failure shrinks and its tape replays" {
    var report: shakedown.CheckReport = undefined;
    try testing.expectError(error.PropertyFailed, shakedown.check(testing.allocator, {}, witness, .{ .cases = 32, .seed = 7, .diagnostics = &report }));
    defer report.deinit();
    try testing.expectEqual(error.ExpectedWitness, report.err);
    try testing.expect(report.shrink_runs > 0);
    var text: Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    try (shakedown.Source.Tape{ .choices = report.tape }).format(&text.writer);
    var replay: shakedown.CheckReport = undefined;
    try testing.expectError(error.PropertyFailed, shakedown.check(testing.allocator, {}, witness, .{ .cases = 0, .regressions = &.{text.written()}, .diagnostics = &replay }));
    defer replay.deinit();
    try testing.expectEqualSlices(u64, report.tape, replay.tape);
}

test "later: each failed submission leaves no operation or frame retained" {
    for (1..9) |step| {
        var d: Driver = undefined;
        try d.init(testing.allocator, 0, .{ .max_tasks = 16, .offload = .none });
        defer d.deinit();
        d.fake.fail_submit_at = step;
        for (1..9) |attempt| {
            var task = try d.io().concurrent(fakeRequest, .{d.io()});
            const result = task.await(d.io());
            if (attempt == step) try testing.expectError(error.SystemResources, result) else try testing.expectEqual(@as(usize, 0), try result);
        }
        try testing.expectEqual(@as(usize, 0), d.fake.ops.items.len);
        try testing.expectEqual(@as(u32, 0), d.runtime.stats().tasks);
    }
}

test "later: a registered pool uses fixed reads and writes and unregisters after draining" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Runtime = undefined;
    try native(&r, .io_uring);
    defer r.deinit();
    var pool = reactor.net.Receiver.Pool.init(testing.allocator, r.io(), .{ .buffers = 2, .buffer_len = 4096, .registered = true }) catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    defer pool.deinit(testing.allocator, r.io());
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(r.io(), "fixed-buffer", .{ .read = true });
    defer file.close(r.io());
    const ring = &r.core.processors[0].loop.backend.io_uring;
    @memset(pool.memory, 0x3d);
    var write: Loop.Op = .{ .kind = .{ .write_at = .{ .file = file.handle, .bytes = pool.memory[0..4096], .offset = 0 } } };
    try ring.submit(&write);
    const sqe = ring.ring.sq.sqes[(ring.ring.sq.sqe_tail -% 1) & ring.ring.sq.mask];
    try testing.expectEqual(linux.IORING_OP.WRITE_FIXED, sqe.opcode);
    // Use the ordinary loop path for delivery accounting after inspecting.
    // The ring already owns this request, so complete it with a sink here.
    const Sink = struct {
        const Self = @This();
        completed: bool = false,
        pub fn complete(self: *Self, _: *Loop.Op) void {
            self.completed = true;
        }
        pub fn completePending(_: *Self, _: pending.Token, _: pending.Outcome) void {
            @panic("no batch in this test");
        }
        pub fn notified(_: *Self) void {}
    };
    var sink: Sink = .{};
    while (!sink.completed) try ring.poll(.forever, &sink);
    try testing.expectEqual(@as(usize, 4096), try write.result.write_at);
    @memset(pool.memory[4096..], 0);
    var read: Loop.Op = .{ .kind = .{ .read_at = .{ .file = file.handle, .buffer = pool.memory[4096..], .offset = 0 } } };
    try ring.submit(&read);
    try testing.expectEqual(linux.IORING_OP.READ_FIXED, ring.ring.sq.sqes[(ring.ring.sq.sqe_tail -% 1) & ring.ring.sq.mask].opcode);
    sink.completed = false;
    while (!sink.completed) try ring.poll(.forever, &sink);
    try testing.expectEqual(@as(usize, 4096), try read.result.read_at);
    for (pool.memory[4096..]) |byte| try testing.expectEqual(@as(u8, 0x3d), byte);
    const slot = pool.fixed.?.items[0].index;
    try testing.expectEqual(@as(u32, 0), ring.buffers.slots[slot].users);
}

test "later: explicitly requested SQPOLL stays enabled and wakes after idle" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var loop: Loop = undefined;
    loop.init(testing.allocator, .{ .backend = .io_uring, .max_ops = 8, .sqpoll = .{ .idle_ms = 1 } }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer loop.deinit(testing.allocator);
    try testing.expect(loop.backend.io_uring.ring.flags & linux.IORING_SETUP_SQPOLL != 0);
    try testing.io.sleep(.fromMilliseconds(10), .awake);
    const Request = struct {
        fn prepare(_: *anyopaque, sqe: *linux.io_uring_sqe) void {
            sqe.prep_nop();
        }
    };
    var context: u8 = 0;
    var op: Loop.Op = .{ .kind = .{ .raw = .{ .uring = .{ .context = &context, .prepare = Request.prepare } } } };
    try loop.submit(&op);
    var reaped: [1]*Loop.Op = undefined;
    while (loop.reap(&reaped).len == 0) _ = try loop.run(.once);
    try testing.expectEqual(@as(i32, 0), (try op.result.raw).uring);
}

fn boundPair(io: Io, interface: Io.net.Interface) !void {
    var listener = try (Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    defer listener.deinit(io);
    const connected = try reactor.net.connect(io, &listener.socket.address, .{
        .local_address = .{ .ip4 = .loopback(0) },
        .interface = interface,
        .timeout = ms(1000),
    });
    defer connected.stream.close(io);
    const accepted = try listener.accept(io);
    defer accepted.close(io);
    try testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &accepted.socket.address.ip4.bytes);
    try testing.expectEqual(connected.stream.socket.address.getPort(), accepted.socket.address.getPort());
    try testing.expect(connected.timeout_enforced);
}

test "later: native and foreign dialing bind the requested address and interface" {
    const name = if (builtin.os.tag == .linux) "lo" else if (builtin.os.tag == .macos) "lo0" else return error.SkipZigTest;
    const interface_name = try Io.net.Interface.Name.fromSlice(name);
    const selected = try interface_name.resolve(testing.io);
    try boundPair(testing.io, selected);
    var r: Runtime = undefined;
    try native(&r, .auto);
    defer r.deinit();
    try boundPair(r.io(), selected);
    const target: Io.net.IpAddress = .{ .ip4 = .loopback(9) };
    try testing.expectError(error.AddressFamilyUnsupported, reactor.net.connect(r.io(), &target, .{ .local_address = .{ .ip6 = .loopback(0) } }));
}

const Step = struct { kind: u8, offset: u8, length: u8, byte: u8 };
const Observation = struct { count: usize = 0, err: ?anyerror = null, bytes: [32]u8 = @splat(0) };
fn fileSequence(io: Io, dir: Io.Dir, path: []const u8, steps: []const Step, out: []Observation) !void {
    const file = try dir.createFile(io, path, .{ .read = true });
    defer file.close(io);
    for (steps, out) |step, *observation| {
        var bytes: [32]u8 = @splat(step.byte);
        switch (step.kind) {
            0 => file.writePositionalAll(io, bytes[0..step.length], step.offset) catch |err| {
                observation.err = err;
            },
            1 => observation.count = file.readPositionalAll(io, observation.bytes[0..step.length], step.offset) catch |err| blk: {
                observation.err = err;
                break :blk 0;
            },
            2 => observation.count = (try file.stat(io)).size,
            3 => try file.setLength(io, step.offset),
            4 => {
                if (dir.openFile(io, "missing-differential", .{})) |unexpected| {
                    unexpected.close(io);
                    return error.MissingFileOpened;
                } else |err| observation.err = err;
            },
            5 => {
                if (dir.createFile(io, path, .{ .exclusive = true })) |unexpected| {
                    unexpected.close(io);
                    return error.ExclusiveFileReplaced;
                } else |err| observation.err = err;
            },
            else => unreachable, // unreachable: the generator draws six operations
        }
    }
}
fn differential(_: void, c: *shakedown.Case) !void {
    var r: Runtime = undefined;
    try native(&r, .auto);
    defer r.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var steps: [24]Step = undefined;
    const length: usize = 1 + @as(usize, @intCast(c.source.below(23)));
    for (steps[0..length]) |*step| step.* = .{ .kind = @intCast(c.source.below(5)), .offset = @intCast(c.source.below(63)), .length = @intCast(c.source.below(32)), .byte = @intCast(c.source.below(255)) };
    var expected: [24]Observation = @splat(.{});
    var actual: [24]Observation = @splat(.{});
    try fileSequence(testing.io, tmp.dir, "oracle", steps[0..length], expected[0..length]);
    try fileSequence(r.io(), tmp.dir, "candidate", steps[0..length], actual[0..length]);
    for (expected[0..length], actual[0..length]) |a, b| {
        try testing.expectEqual(a.count, b.count);
        try testing.expectEqual(a.err, b.err);
        try testing.expectEqualSlices(u8, &a.bytes, &b.bytes);
    }
    const left = try tmp.dir.openFile(testing.io, "oracle", .{});
    defer left.close(testing.io);
    const right = try tmp.dir.openFile(r.io(), "candidate", .{});
    defer right.close(r.io());
    var a: [128]u8 = undefined;
    var b: [128]u8 = undefined;
    const n = try left.readPositionalAll(testing.io, &a, 0);
    try testing.expectEqual(n, try right.readPositionalAll(r.io(), &b, 0));
    try testing.expectEqualSlices(u8, a[0..n], b[0..n]);
}

test "later: generated native file contents metadata and errors match Threaded" {
    try shakedown.check(testing.allocator, {}, differential, .{ .cases = 64, .regressions = &.{ "0:0:0:0:0", "3:0:3f:20:ff:1:3f:20" } });
}

fn blockedPipe(lane: Io, io: Io, file: Io.File, begun: *Io.Event) !usize {
    begun.set(io);
    var byte: [1]u8 = undefined;
    return (try lane.operate(.{ .file_read_streaming = .{ .file = file, .data = &.{&byte} } })).file_read_streaming;
}
fn onPipe(io: Io, lane: Io, file: Io.File, begun: *Io.Event) !usize {
    return reactor.blocking(io, .wait, blockedPipe, .{ lane, io, file, begun });
}
test "V3 owned lane cancellation interrupts a blocked Threaded pipe read" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var r: Runtime = undefined;
    try native(&r, .auto);
    defer r.deinit();
    const pipe = try Io.Threaded.pipe2(.{ .CLOEXEC = true });
    defer for (pipe) |fd| {
        _ = std.posix.system.close(fd);
    };
    var begun: Io.Event = .unset;
    const file: Io.File = .{ .handle = pipe[0], .flags = .{ .nonblocking = false } };
    var future = try r.io().concurrent(onPipe, .{ r.io(), r.core.lanes.executor(.wait), file, &begun });
    try begun.wait(r.io());
    try r.io().sleep(.fromMilliseconds(2), .awake);
    try testing.expectError(error.Canceled, future.cancel(r.io()));
    try testing.expectEqual(@as(u64, 0), r.stats().lanes[@backingInt(Runtime.Lane.wait)].@"inline");
}

test "later: cross-ring message wake reaches the target CQ and disabled support uses eventfd" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var source: Loop = undefined;
    source.init(testing.allocator, .{ .backend = .io_uring, .max_ops = 8 }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer source.deinit(testing.allocator);
    if (!source.backend.io_uring.features.msg_ring) return error.SkipZigTest;
    var target: Loop = undefined;
    try target.init(testing.allocator, .{ .backend = .io_uring, .max_ops = 8 });
    defer target.deinit(testing.allocator);
    target.wakeFrom(&source);
    const ring = &source.backend.io_uring.ring;
    try testing.expectEqual(linux.IORING_OP.MSG_RING, ring.sq.sqes[(ring.sq.sqe_tail -% 1) & ring.sq.mask].opcode);
    _ = try source.run(.nowait);
    for (0..100) |_| {
        if (target.backend.io_uring.ring.cq_ready() > 0) break;
        _ = try source.run(.nowait);
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expect(target.backend.io_uring.ring.cq_ready() > 0);
    _ = try target.run(.nowait);
    source.backend.io_uring.features.msg_ring = false;
    target.wakeFrom(&source);
    try testing.expect(target.backend.io_uring.wake_pending.load(.acquire));
    _ = try target.run(.nowait);
    _ = try source.run(.nowait);
}

fn ringGuard(done: *std.atomic.Value(bool)) void {
    for (0..2000) |_| {
        if (done.load(.acquire)) return;
        testing.io.sleep(.fromMilliseconds(1), .awake) catch return;
    }
    std.process.exit(97);
}
test "later: full SQ and CQ drain ownership without invoking callbacks during submit" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var loop: Loop = undefined;
    loop.init(testing.allocator, .{ .backend = .io_uring, .max_ops = 128, .submission_entries = 2 }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer loop.deinit(testing.allocator);
    var done = std.atomic.Value(bool).init(false);
    const guard = try std.Thread.spawn(.{}, ringGuard, .{&done});
    defer {
        done.store(true, .release);
        guard.join();
    }
    const Counter = struct {
        fn prepare(_: *anyopaque, sqe: *linux.io_uring_sqe) void {
            sqe.prep_nop();
        }
        fn callback(_: *Loop, op: *Loop.Op) void {
            const count: *usize = @ptrFromInt(op.user_data); // safe: retained through the last callback
            count.* += 1;
        }
    };
    var count: usize = 0;
    var context: u8 = 0;
    var ops: [128]Loop.Op = undefined;
    for (&ops) |*op| {
        op.* = .{ .kind = .{ .raw = .{ .uring = .{ .context = &context, .prepare = Counter.prepare } } }, .callback = Counter.callback, .user_data = @intFromPtr(&count) }; // safe: the counter is retained through run
        try loop.submit(op);
        loop.cancel(op);
        try testing.expectEqual(@as(usize, 0), count);
    }
    while (count < ops.len) _ = try loop.run(.once);
    try testing.expectEqual(@as(u32, 0), loop.in_flight);
    try testing.expectEqual(@as(usize, 0), loop.backend.io_uring.active);
}

test "later: native linked deadline drains timer and read before releasing the frame" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Runtime = undefined;
    try native(&r, .io_uring);
    defer r.deinit();
    if (!r.core.processors[0].loop.backend.io_uring.features.linked_timeout) return error.SkipZigTest;
    const pair = try Io.net.Socket.createPair(r.io(), .{ .mode = .stream });
    defer for (pair) |socket| socket.close(r.io());
    var byte: [1]u8 = undefined;
    var data: [1][]u8 = .{&byte};
    try testing.expectError(error.Timeout, r.io().operateTimeout(.{ .net_read = .{ .socket_handle = pair[0].handle, .data = &data } }, ms(1)));
    var storage: [1]Io.Operation.Storage = undefined;
    var batch: Io.Batch = .init(&storage);
    defer batch.cancel(r.io());
    _ = batch.add(.{ .net_read = .{ .socket_handle = pair[0].handle, .data = &data } });
    try testing.expectError(error.Timeout, batch.awaitConcurrent(r.io(), ms(1)));
    try testing.expect(batch.pending.head == .none and batch.submitted.head != .none);
    _ = try (try r.io().operate(.{ .net_write = .{ .socket_handle = pair[1].handle, .data = &.{"z"} } })).net_write;
    try batch.awaitConcurrent(r.io(), ms(1000));
    const completion = batch.next().?;
    try testing.expectEqual(@as(usize, 1), (try completion.result.net_read).data_len);
    try testing.expectEqual(@as(u8, 'z'), byte[0]);
    try testing.expectEqual(@as(u32, 0), r.core.processors[0].loop.in_flight);
}

fn drainPayload(socket: Io.net.Socket, total: usize) !void {
    var buffer: [4096]u8 = undefined;
    var received: usize = 0;
    while (received < total) {
        var data: [1][]u8 = .{buffer[0..@min(buffer.len, total - received)]};
        const n = (try (try testing.io.operate(.{ .net_read = .{ .socket_handle = socket.handle, .data = &data } })).net_read).data_len;
        if (n == 0) return error.EndOfStream;
        for (buffer[0..n]) |byte| try testing.expectEqual(@as(u8, 0x6d), byte);
        received += n;
    }
}
test "later: native zero-copy send completes ownership before payload reuse" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var loop: Loop = undefined;
    loop.init(testing.allocator, .{ .backend = .io_uring, .max_ops = 8, .zero_copy_min = 1 }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer loop.deinit(testing.allocator);
    if (!loop.backend.io_uring.features.zero_copy) return error.SkipZigTest;
    var server = try (Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(testing.io, .{});
    defer server.deinit(testing.io);
    const stream = try server.socket.address.connect(testing.io, .{ .mode = .stream });
    defer stream.close(testing.io);
    const peer = try server.accept(testing.io);
    defer peer.close(testing.io);
    var payload: [64 << 10]u8 = @splat(0x6d);
    var reader = try testing.io.concurrent(drainPayload, .{ peer.socket, payload.len });
    defer _ = reader.cancel(testing.io) catch {};
    var sent: usize = 0;
    var notified = false;
    while (sent < payload.len) {
        var op: Loop.Op = .{ .kind = .{ .io = .{ .net_write = .{ .socket_handle = stream.socket.handle, .data = &.{payload[sent..]} } } } };
        try loop.submit(&op);
        try testing.expectEqual(linux.IORING_OP.SEND_ZC, loop.backend.io_uring.ring.sq.sqes[(loop.backend.io_uring.ring.sq.sqe_tail -% 1) & loop.backend.io_uring.ring.sq.mask].opcode);
        var out: [1]*Loop.Op = undefined;
        while (loop.reap(&out).len == 0) _ = try loop.run(.once);
        const n = try (try op.result.io).net_write;
        try testing.expect(n > 0);
        try testing.expect(op.state.uring.ready());
        notified = notified or op.state.uring.notification_seen;
        @memset(payload[sent..][0..n], 0);
        sent += n;
    }
    try reader.await(testing.io);
    try testing.expect(notified);
    try testing.expectEqual(@as(usize, 0), loop.backend.io_uring.active);
}

const FaultContext = struct {
    tmp: testing.TmpDir = undefined,
    base: Io,
    pub fn setUp(self: *FaultContext, _: *shakedown.FaultIo) !void {
        self.tmp = testing.tmpDir(.{});
    }
    pub fn run(self: *FaultContext, io: Io) !void {
        const file = try self.tmp.dir.createFile(io, "faulted", .{ .read = true });
        defer file.close(io);
        try file.writePositionalAll(io, "fault payload", 0);
        var bytes: [13]u8 = undefined;
        const n = try file.readPositionalAll(io, &bytes, 0);
        if (n != bytes.len) return error.ShortRead;
        try testing.expectEqualSlices(u8, "fault payload", &bytes);
        try testing.expectEqual(@as(u64, 13), (try file.stat(io)).size);
    }
    pub fn check(self: *FaultContext, _: Io, result: anyerror!void, injected: ?shakedown.Injected) !void {
        if (injected == null) try result else if (result) |_| {} else |err| switch (err) {
            error.Canceled, error.InputOutput, error.NoSpaceLeft, error.AccessDenied, error.SystemResources => {},
            error.ShortRead => if (injected.?.fault != .short) return err,
            else => return err,
        }
        const runtime = Runtime.recognize(self.base).?;
        try testing.expectEqual(@as(u32, 0), runtime.core.processors[0].loop.in_flight);
        try testing.expectEqual(@as(u32, 0), runtime.stats().tasks);
    }
    pub fn tearDown(self: *FaultContext) void {
        self.tmp.cleanup();
    }
};
test "later: every native file fault short transfer and cancellation leaves ownership drained" {
    var r: Runtime = undefined;
    try native(&r, .auto);
    defer r.deinit();
    var context: FaultContext = .{ .base = r.io() };
    var report = try shakedown.everyFault(testing.allocator, r.io(), &context, .{ .errors = &.{ error.InputOutput, error.NoSpaceLeft, error.AccessDenied, error.SystemResources }, .max_steps = 64 });
    defer report.deinit();
    try testing.expect(report.runs > 10);
}

noinline fn touchWithoutPark() u8 {
    var data: [96 << 10]u8 = undefined;
    const bytes: *volatile [96 << 10]u8 = &data;
    for (0..data.len) |at| bytes[at] = 0x39;
    return bytes[7];
}
fn measured(io: Io) !void {
    try testing.expectEqual(@as(u8, 0x39), touchWithoutPark());
    try io.sleep(.fromMilliseconds(1), .awake);
}
test "later: diagnostic overall depth includes returned frames and survives task release" {
    var r: Runtime = undefined;
    r.init(testing.allocator, .{ .workers = 0, .max_tasks = 4, .stack_size = 256 << 10, .measure_stacks = true }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer r.deinit();
    var future = try r.io().concurrent(measured, .{r.io()});
    try future.await(r.io());
    const snapshot = r.stats();
    try testing.expect(snapshot.parked_high_water > 0);
    try testing.expect(snapshot.stack_high_water.? > 96 << 10);
    try testing.expect(snapshot.stack_high_water.? > snapshot.parked_high_water);
    try testing.expectEqual(@as(u32, 0), snapshot.tasks);
}

test "V3 owned Windows lane cancellation interrupts a synchronous pipe read" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var child = try std.process.spawn(testing.io, .{ .argv = &.{ "cmd.exe", "/d", "/c", "ping -n 6 127.0.0.1 >nul" }, .stdout = .pipe });
    defer child.kill(testing.io);
    var r: Runtime = undefined;
    try native(&r, .iocp);
    defer r.deinit();
    var begun: Io.Event = .unset;
    var future = try r.io().concurrent(onPipe, .{ r.io(), r.core.lanes.executor(.wait), child.stdout.?, &begun });
    try begun.wait(r.io());
    try r.io().sleep(.fromMilliseconds(2), .awake);
    try testing.expectError(error.Canceled, future.cancel(r.io()));
    try testing.expectEqual(@as(u64, 0), r.stats().lanes[@backingInt(Runtime.Lane.wait)].@"inline");
}

fn canceledWait(io: Io, begun: *Io.Event, word: *u32) Io.Cancelable!void {
    begun.set(io);
    while (word.* == 0) try io.futexWait(u32, word, 0);
}
const NetObservation = struct { bytes: [256]u8 = @splat(0), timeout: ?anyerror = null, canceled: ?anyerror = null, eof: usize = 1 };
fn networkSequence(io: Io, payload: []const u8) !NetObservation {
    var out: NetObservation = .{};
    var listener = try (Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    defer listener.deinit(io);
    const stream = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    const peer = try listener.accept(io);
    defer peer.close(io);
    var buffer: [256]u8 = undefined;
    var data: [1][]u8 = .{buffer[0..payload.len]};
    var storage: [1]Io.Operation.Storage = undefined;
    var batch: Io.Batch = .init(&storage);
    defer batch.cancel(io);
    _ = batch.add(.{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &data } });
    batch.awaitConcurrent(io, ms(1)) catch |err| {
        out.timeout = err;
    };
    if (out.timeout == null or out.timeout.? != error.Timeout) return error.WrongTimeout;
    var sent: usize = 0;
    while (sent < payload.len) sent += try (try io.operate(.{ .net_write = .{ .socket_handle = peer.socket.handle, .data = &.{payload[sent..]} } })).net_write;
    try batch.awaitConcurrent(io, ms(1000));
    var got = (try batch.next().?.result.net_read).data_len;
    @memcpy(out.bytes[0..got], buffer[0..got]);
    while (got < payload.len) {
        var remaining: [1][]u8 = .{out.bytes[got..payload.len]};
        const n = (try (try io.operate(.{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &remaining } })).net_read).data_len;
        if (n == 0) return error.EndOfStream;
        got += n;
    }
    try peer.shutdown(io, .send);
    data = .{&buffer};
    out.eof = (try (try io.operate(.{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &data } })).net_read).data_len;
    var begun: Io.Event = .unset;
    var word: u32 = 0;
    var future = try io.concurrent(canceledWait, .{ io, &begun, &word });
    try begun.wait(io);
    future.cancel(io) catch |err| {
        out.canceled = err;
    };
    return out;
}
fn networkDifferential(backend: Loop.Backend, c: *shakedown.Case) !void {
    var r: Runtime = undefined;
    try native(&r, backend);
    defer r.deinit();
    var payload: [256]u8 = undefined;
    const count = 1 + @as(usize, @intCast(c.source.below(255)));
    for (payload[0..count]) |*byte| byte.* = @intCast(c.source.below(255));
    const expected = try networkSequence(testing.io, payload[0..count]);
    const actual = try networkSequence(r.io(), payload[0..count]);
    try testing.expectEqualSlices(u8, &expected.bytes, &actual.bytes);
    try testing.expectEqual(expected.timeout, actual.timeout);
    try testing.expectEqual(expected.canceled, actual.canceled);
    try testing.expectEqual(expected.eof, actual.eof);
    try testing.expectEqual(@as(u32, 0), r.stats().tasks);
    try testing.expectEqual(@as(u32, 0), r.core.processors[0].loop.in_flight);
}
test "later: generated streams EOF batch retry and futex cancellation match Threaded" {
    for (if (builtin.os.tag == .linux) @as([]const Loop.Backend, &.{ .io_uring, .epoll }) else @as([]const Loop.Backend, &.{.auto})) |backend| {
        var probe: Runtime = undefined;
        native(&probe, backend) catch |err| switch (err) {
            error.SkipZigTest => continue,
            else => return err,
        };
        probe.deinit();
        try shakedown.check(testing.allocator, backend, networkDifferential, .{ .cases = 32, .regressions = &.{ "0:7f", "ff:0:ff" } });
    }
}

test "later: canceled fixed-buffer pipe read drains before unregister and a full table rolls back" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Runtime = undefined;
    r.init(testing.allocator, .{ .workers = 0, .backend = .io_uring, .max_tasks = 8, .registered_pools = 1 }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer r.deinit();
    var pool = reactor.net.Receiver.Pool.init(testing.allocator, r.io(), .{ .buffers = 2, .buffer_len = 4096, .registered = true }) catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    defer pool.deinit(testing.allocator, r.io());
    try testing.expectError(error.SystemResources, reactor.net.Receiver.Pool.init(testing.allocator, r.io(), .{ .buffers = 2, .buffer_len = 4096, .registered = true }));
    const pipe = try Io.Threaded.pipe2(.{ .CLOEXEC = true });
    defer for (pipe) |fd| {
        _ = linux.close(fd);
    };
    const ring = &r.core.processors[0].loop.backend.io_uring;
    const index = pool.fixed.?.items[0].index;
    for (0..32) |_| {
        var data: [1][]u8 = .{pool.memory[0..4096]};
        var op: Loop.Op = .{ .kind = .{ .io = .{ .file_read_streaming = .{ .file = .{ .handle = pipe[0], .flags = .{ .nonblocking = false } }, .data = &data } } } };
        const loop = &r.core.processors[0].loop;
        try loop.submit(&op);
        try testing.expectEqual(linux.IORING_OP.READ_FIXED, ring.ring.sq.sqes[(ring.ring.sq.sqe_tail -% 1) & ring.ring.sq.mask].opcode);
        try testing.expectEqual(@as(u32, 1), ring.buffers.slots[index].users);
        loop.cancel(&op);
        var out: [1]*Loop.Op = undefined;
        while (loop.reap(&out).len == 0) _ = try loop.run(.once);
        try testing.expectError(error.Canceled, op.result.io);
        try testing.expectEqual(@as(u32, 0), ring.buffers.slots[index].users);
        @memset(pool.memory, 0xdd);
    }
}
