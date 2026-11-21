//! Ending every operation under way on a socket, from any task.
const builtin = @import("builtin");
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

/// A connection shut down both ways, which ends a read or write waiting on
/// it and every one after it, and tells the peer; on Windows an abortive
/// disconnect, since AFD's graceful one leaves a pending receive waiting for
/// the peer. The socket stays open: its owner closes it.
///
/// It ends waits on a connection only. A socket with none (a datagram
/// socket, which answers that it is not connected) has nothing a shutdown
/// ends, and a wait on it goes on: such a wait is ended by its own cancel,
/// as `Deadlines` ends one. A connection the peer reset or disconnected
/// has already ended every wait on it.
///
/// Any other refusal leaves what waits on the socket waiting, and nothing
/// can end it from outside: a Debug build stops there, so the hang is a
/// failure that names its cause. No caller has a way on from one (a
/// deadline's watching task, a server closing its connections), which is
/// why it is a check and not an error returned.
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
        const result = io.operate(operation) catch |err| switch (err) {
            // A cancel stays asked for.
            error.Canceled => return io.recancel(),
        };
        aegis.assert.debug(endedBy(result.device_io_control.u.Status), "an abortive disconnect the socket refused leaves its operations waiting");
        return;
    }
    io.vtable.netShutdown(io.userdata, socket, .both) catch |err| switch (err) {
        error.Canceled => io.recancel(),
        // Reset or disconnected: its waits have ended already.
        error.ConnectionAborted, error.ConnectionResetByPeer => {},
        // No connection: nothing for a shutdown to end (see above).
        error.SocketUnconnected => {},
        error.NetworkDown, error.SystemResources, error.Unexpected => aegis.assert.debug(false, "a shutdown the socket refused leaves its operations waiting"),
    };
}

/// Whether an abortive disconnect's status leaves the socket ended: done
/// now, or ended before by a reset, a disconnect or no connection.
fn endedBy(status: std.os.windows.NTSTATUS) bool {
    return switch (status) {
        .SUCCESS, .INVALID_CONNECTION, .CONNECTION_INVALID, .CONNECTION_RESET, .CONNECTION_ABORTED, .CONNECTION_DISCONNECTED, .LOCAL_DISCONNECT, .REMOTE_DISCONNECT => true,
        else => false,
    };
}
