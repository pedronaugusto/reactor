//! Ending every operation under way on a socket, from any task.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;

/// A shutdown of both directions, which ends a read or write waiting on
/// the socket and every one after it; on Windows an abortive disconnect,
/// since AFD's graceful one leaves a pending receive waiting for the peer.
/// The socket stays open: its owner closes it. A refusal means it is ended
/// already.
pub fn abort(io: Io, socket: Io.net.Socket.Handle) void {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const info: windows.AFD.PARTIAL_DISCONNECT_INFO = .{
            .DisconnectMode = .{ .SEND = true, .RECEIVE = true, .ABORTIVE = true },
            .Timeout = -1,
        };
        const operation: Io.Operation = .{ .device_io_control = .{
            .file = .{ .handle = socket, .flags = .{ .nonblocking = false } },
            .code = windows.IOCTL.AFD.PARTIAL_DISCONNECT,
            .in = std.mem.asBytes(&info),
        } };
        // ziglint-ignore: Z026 a socket that cannot be disconnected is ended already, which is what this asks
        _ = io.operate(operation) catch {};
        return;
    }
    // ziglint-ignore: Z026 a socket that cannot be shut down is ended already, which is what this asks
    io.vtable.netShutdown(io.userdata, socket, .both) catch {};
}
