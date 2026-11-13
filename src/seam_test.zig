//! reactor's seam: under an `Io` whose sockets are not the system's, the raw
//! socket calls ask the test's hook (`reactor.testing`) and run nothing.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const reactor = @import("reactor.zig");
const seam_testing = @import("reactor.testing");
const sys = @import("sys/options.zig");
const shakedown = @import("shakedown");
const Io = std.Io;

test "a socket's options under a hooked Io are told to the hook, and none is set" {
    const io = testing.io;
    var server = try reactor.net.listen(io, &.{ .ip4 = .loopback(0) }, .{ .reuse_address = true });
    defer server.deinit(io);
    var s: seam_testing.Seam = undefined;
    s.init(io);
    var connected = try reactor.net.connect(s.io(), &server.borrow().socket.address, .{ .socket = .{ .nodelay = true } });
    defer connected.stream.deinit(io);
    const accepted = try server.borrowMut().accept(io);
    defer accepted.close(io);
    try reactor.net.setOptions(s.io(), accepted.socket, .{ .keepalive = .off });
    const asked = s.asked();
    try testing.expectEqual(@as(usize, 2), asked.count);
    try testing.expectEqual(@as(?bool, false), asked.last.?.keepalive);
    // Nothing raw ran: the connected socket keeps the system's default.
    try testing.expectEqual(@as(c_int, 0), try sys.get(connected.stream.borrow().socket.handle, sys.nodelay));
}

test "a peek under a hooked Io answers nothing; on the system it looks" {
    const io = testing.io;
    var server = try reactor.net.listen(io, &.{ .ip4 = .loopback(0) }, .{ .reuse_address = true });
    defer server.deinit(io);
    var connected = try reactor.net.connect(io, &server.borrow().socket.address, .{});
    defer connected.stream.deinit(io);
    const accepted = try server.borrowMut().accept(io);
    defer accepted.close(io);
    var s: seam_testing.Seam = undefined;
    s.init(io);
    try testing.expectEqual(@as(?reactor.net.Peek, null), reactor.net.peek(s.io(), accepted.socket.handle));
    const system: ?reactor.net.Peek = if (builtin.os.tag == .windows or builtin.os.tag == .wasi) null else .idle;
    try testing.expectEqual(system, reactor.net.peek(io, accepted.socket.handle));
}

fn finished(outcome: shakedown.Sim.Outcome) !void {
    if (outcome == .failed) return outcome.failed;
    try testing.expect(outcome == .finished);
}

test "a connect that makes its own socket is made on the simulation under a hooked Io: bound where asked, its port shared only as asked, its options told" {
    const sim = try shakedown.Sim.init(testing.allocator, .{ .watchdog = null });
    defer sim.deinit();
    const Work = struct {
        fn run(base: Io) !void {
            var s: seam_testing.Seam = undefined;
            s.init(base);
            const io = s.io();
            var a = try (try Io.net.IpAddress.parse("127.0.0.1", 80)).listen(base, .{});
            defer a.deinit(base);
            var b = try (try Io.net.IpAddress.parse("127.0.0.1", 81)).listen(base, .{});
            defer b.deinit(base);
            const local: Io.net.IpAddress = try .parse("127.0.0.1", 4000);
            var first = try reactor.net.connect(io, &a.socket.address, .{ .local_address = local, .reuse_address = true, .socket = .{ .receive_buffer = .fromRaw(96 << 10), .nodelay = true } });
            defer first.stream.deinit(io);
            const from_first = try a.accept(base);
            defer from_first.close(base);
            try testing.expect(from_first.socket.address.eql(&local));
            const asked = s.asked();
            try testing.expectEqual(@as(usize, 1), asked.count);
            try testing.expectEqual(@as(?u32, 96 << 10), asked.last.?.receive_buffer);
            try testing.expectEqual(@as(?bool, true), asked.last.?.nodelay);
            // Shared by both, the port binds again for another destination.
            var second = try reactor.net.connect(io, &b.socket.address, .{ .local_address = local, .reuse_address = true });
            defer second.stream.deinit(io);
            const from_second = try b.accept(base);
            defer from_second.close(base);
            try testing.expect(from_second.socket.address.eql(&local));
            // A bind that does not share it, and the same destination again, are refused.
            try testing.expectError(error.AddressUnavailable, reactor.net.connect(io, &b.socket.address, .{ .local_address = local }));
            try testing.expectError(error.AddressUnavailable, reactor.net.connect(io, &a.socket.address, .{ .local_address = local, .reuse_address = true }));
            // A bind alone tells no options.
            try testing.expectEqual(@as(usize, 1), s.asked().count);
        }
    };
    try finished(sim.run(Work.run, .{sim.io()}));
}

test "a connect that makes its own socket ends at its timeout on the simulation under a hooked Io" {
    const sim = try shakedown.Sim.init(testing.allocator, .{ .watchdog = null, .schedule = .fifo });
    defer sim.deinit();
    const address = try Io.net.IpAddress.parseIp4("10.7.0.2", 8000);
    const left = try sim.node("left", .{ .addresses = &.{try Io.net.IpAddress.parseIp4("10.7.0.1", 0)} });
    const right = try sim.node("right", .{ .addresses = &.{address} });
    const Work = struct {
        fn run(sm: *shakedown.Sim, l: *shakedown.Sim.Node, r: *shakedown.Sim.Node, addr: Io.net.IpAddress) !void {
            var server = try addr.listen(r.io(), .{});
            defer server.deinit(r.io());
            var s: seam_testing.Seam = undefined;
            s.init(l.io());
            sm.net().hold(l, r);
            const at = sm.now(.awake).nanoseconds;
            const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(250), .clock = .awake } };
            try testing.expectError(error.Timeout, reactor.net.connect(s.io(), &addr, .{ .local_address = try .parse("10.7.0.1", 0), .timeout = timeout }));
            try testing.expectEqual(250 * std.time.ns_per_ms, sm.now(.awake).nanoseconds - at);
        }
    };
    try finished(sim.run(Work.run, .{ sim, left, right, address }));
}
