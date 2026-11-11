//! reactor's seam: under an `Io` whose sockets are not the system's, the raw
//! socket calls ask the test's hook (`reactor.testing`) and run nothing.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const reactor = @import("reactor.zig");
const seam_testing = @import("reactor.testing");
const sys = @import("sys/options.zig");

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
