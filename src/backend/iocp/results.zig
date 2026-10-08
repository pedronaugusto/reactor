//! IOCP completions as std's results: each status mapped as `Threaded`
//! maps it for the same call where std maps it, and to the error the same
//! condition gets on POSIX where std leaves it unexpected, so a program
//! sees one set of errors on every backend.
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const windows = std.os.windows;
const Status = windows.NTSTATUS;
const Threaded = Io.Threaded;

const op = @import("../op.zig");
const pending = @import("../pending.zig");

/// Whether `status` says the kernel ended the call because it was
/// cancelled or its handle closed, rather than finishing it.
pub fn ended(status: Status) bool {
    return switch (status) {
        .CANCELLED, .CONNECTION_ABORTED, .LOCAL_DISCONNECT, .HANDLES_CLOSED => true,
        else => false,
    };
}

/// Whether a status the call returned at once means an entry still
/// follows. With the port skipped on success, an entry follows a pending
/// call and a warning (`BUFFER_OVERFLOW`, for one); success and failure
/// returned at once are final.
pub fn entryFollows(status: Status) bool {
    const word = @backingInt(status);
    return status == .PENDING or (word >> 30) == 0b10;
}

fn unexpected(status: Status) error{Unexpected} {
    return windows.unexpectedStatus(status);
}

/// The result of a completed operation whose final status and transfer
/// count are `status` and `information`.
pub fn of(o: anytype, status: Status, information: usize) op.Result {
    const canceled = ended(status);
    const ours = canceled and o.state.canceled;
    return switch (o.kind) {
        .raw => .{ .raw = if (ours) error.Canceled else .{ .windows = .{ .u = .{ .Status = status }, .Information = information } } },
        .io => |operation| .{ .io = if (ours) error.Canceled else io(o, operation, status, information) },
        // A connection taken is the backend's to report: only failures come here.
        .accept => .{ .accept = if (ours) error.Canceled else if (canceled) error.SocketNotListening else accept(status) },
        .connect => .{ .connect = if (ours) error.Canceled else if (status == .SUCCESS) {} else connect(status) },
        .read_at => .{ .read_at = if (ours) error.Canceled else readAt(status, information) },
        .write_at => .{ .write_at = if (ours) error.Canceled else writeAt(status, information) },
        .sync => .{ .sync = sync(status) },
        .close => .{ .close = {} },
        .abort => .{ .abort = 0 },
        .timer => .{ .timer = if (status == .SUCCESS) {} else error.Canceled },
        .wait => .{
            .wait = if (ours) error.Canceled else switch (status) {
                // Ready, or its handle closed: a wait ends either way.
                .SUCCESS, .CANCELLED, .CONNECTION_ABORTED, .LOCAL_DISCONNECT, .HANDLES_CLOSED => {},
                // Not a socket: readiness has no meaning there.
                .INVALID_DEVICE_REQUEST, .INVALID_HANDLE, .NOT_SUPPORTED, .INVALID_PARAMETER => error.Unsupported,
                else => unexpected(status),
            },
        },
    };
}

fn io(o: anytype, operation: Io.Operation, status: Status, information: usize) Io.Operation.Result {
    // Ended though nobody here asked: its handle was closed.
    const closed = ended(status);
    return switch (operation) {
        .file_read_streaming => .{ .file_read_streaming = if (closed) error.SocketUnconnected else fileRead(status, information) },
        .file_write_streaming => .{ .file_write_streaming = if (closed) error.BrokenPipe else fileWrite(status, information) },
        .net_read => .{ .net_read = if (closed) error.SocketUnconnected else if (status == .SUCCESS) .{ .data_len = information } else netRead(status) },
        .net_write => .{ .net_write = if (closed) error.SocketUnconnected else if (status == .SUCCESS) information else netWrite(status) },
        .net_receive => |r| .{ .net_receive = if (closed) .{ error.SocketUnconnected, 0 } else received(o, r, status, information) },
        // A send that reached the kernel is the backend's, one message at a
        // time: only a refusal comes here.
        .net_send => .{ .net_send = .{ if (closed) error.SocketUnconnected else send(status), 0 } },
        .device_io_control => .{ .device_io_control = .{ .u = .{ .Status = status }, .Information = information } },
    };
}

/// A batch operation's outcome.
pub fn ofPending(operation: Io.Operation, status: Status, information: usize, address: ?*const Threaded.PosixAddress) pending.Outcome {
    if (ended(status)) return .canceled;
    return .{ .result = switch (operation) {
        .file_read_streaming => .{ .file_read_streaming = fileRead(status, information) },
        .file_write_streaming => .{ .file_write_streaming = fileWrite(status, information) },
        .net_read => .{ .net_read = if (status == .SUCCESS) .{ .data_len = information } else netRead(status) },
        .net_write => .{ .net_write = if (status == .SUCCESS) information else netWrite(status) },
        .net_receive => |r| .{ .net_receive = datagram(&r.message_buffer[0], r.data_buffer, status, information, address.?) },
        .net_send => |s| .{ .net_send = if (status == .SUCCESS) one(s, information) else .{ send(status), 0 } },
        .device_io_control => .{ .device_io_control = .{ .u = .{ .Status = status }, .Information = information } },
    } };
}

fn one(s: Io.Operation.NetSend, information: usize) struct { ?net.Socket.SendError, usize } {
    s.messages[0].data_len = information;
    return .{ null, 1 };
}

fn received(o: anytype, r: Io.Operation.NetReceive, status: Status, information: usize) struct { ?net.Socket.ReceiveError, usize } {
    const d = &o.state.scratch.iocp.request.datagram_in;
    return datagram(&r.message_buffer[0], r.data_buffer, status, information, &d.address);
}

fn datagram(message: *net.IncomingMessage, buffer: []u8, status: Status, information: usize, address: *const Threaded.PosixAddress) struct { ?net.Socket.ReceiveError, usize } {
    switch (status) {
        .SUCCESS, .RECEIVE_EXPEDITED => {
            message.* = .{
                .from = Threaded.addressFromPosix(address),
                .data = buffer[0..@min(information, buffer.len)],
                .control = &.{},
                .flags = .{
                    .eor = false,
                    .trunc = false,
                    .ctrunc = false,
                    .oob = status == .RECEIVE_EXPEDITED,
                    .errqueue = false,
                },
            };
            return .{ null, 1 };
        },
        // A message longer than the buffer is `MessageOversize`, as std
        // reports it on Windows.
        else => return .{ receive(status), 0 },
    }
}

fn fileRead(status: Status, information: usize) Io.Operation.FileReadStreaming.Error!usize {
    return switch (status) {
        .SUCCESS => information,
        .END_OF_FILE, .PIPE_BROKEN, .PIPE_CLOSING => error.EndOfStream,
        .INVALID_HANDLE => error.NotOpenForReading,
        .INVALID_DEVICE_REQUEST => error.IsDir,
        .FILE_LOCK_CONFLICT => error.LockViolation,
        .ACCESS_DENIED => error.AccessDenied,
        .INSUFFICIENT_RESOURCES, .NO_MEMORY => error.SystemResources,
        else => unexpected(status),
    };
}

fn fileWrite(status: Status, information: usize) Io.Operation.FileWriteStreaming.Error!usize {
    return switch (status) {
        .SUCCESS => information,
        .INVALID_USER_BUFFER, .NO_MEMORY, .QUOTA_EXCEEDED, .WORKING_SET_QUOTA, .INSUFFICIENT_RESOURCES => error.SystemResources,
        .PIPE_BROKEN, .PIPE_CLOSING => error.BrokenPipe,
        .INVALID_HANDLE => error.NotOpenForWriting,
        .FILE_LOCK_CONFLICT => error.LockViolation,
        .ACCESS_DENIED => error.AccessDenied,
        .DISK_FULL => error.NoSpaceLeft,
        else => unexpected(status),
    };
}

fn readAt(status: Status, information: usize) (Io.File.ReadPositionalError || Io.Cancelable)!usize {
    return switch (status) {
        .SUCCESS => information,
        .END_OF_FILE => 0,
        .INVALID_HANDLE => error.NotOpenForReading,
        .INVALID_DEVICE_REQUEST => error.IsDir,
        .FILE_LOCK_CONFLICT => error.LockViolation,
        .ACCESS_DENIED => error.AccessDenied,
        .INSUFFICIENT_RESOURCES, .NO_MEMORY => error.SystemResources,
        .INVALID_PARAMETER => error.Unseekable,
        else => unexpected(status),
    };
}

fn writeAt(status: Status, information: usize) (Io.File.WritePositionalError || Io.Cancelable)!usize {
    return switch (status) {
        .SUCCESS => information,
        .INVALID_USER_BUFFER, .NO_MEMORY, .QUOTA_EXCEEDED, .WORKING_SET_QUOTA, .INSUFFICIENT_RESOURCES => error.SystemResources,
        .PIPE_BROKEN, .PIPE_CLOSING => error.BrokenPipe,
        .INVALID_HANDLE => error.NotOpenForWriting,
        .FILE_LOCK_CONFLICT => error.LockViolation,
        .ACCESS_DENIED => error.AccessDenied,
        .DISK_FULL => error.NoSpaceLeft,
        .INVALID_PARAMETER => error.Unseekable,
        else => unexpected(status),
    };
}

fn sync(status: Status) Io.File.SyncError!void {
    return switch (status) {
        .SUCCESS => {},
        .DISK_FULL => error.NoSpaceLeft,
        .ACCESS_DENIED => error.AccessDenied,
        .INSUFFICIENT_RESOURCES, .NO_MEMORY => error.InputOutput,
        else => unexpected(status),
    };
}

pub fn netRead(status: Status) Io.Operation.NetRead.Error {
    return switch (status) {
        .INSUFFICIENT_RESOURCES, .NO_MEMORY => error.SystemResources,
        .CONNECTION_RESET, .REMOTE_DISCONNECT => error.ConnectionResetByPeer,
        .IO_TIMEOUT => error.ConnectionTimedOut,
        .INVALID_CONNECTION, .CONNECTION_INVALID, .CONNECTION_DISCONNECTED, .GRACEFUL_DISCONNECT => error.SocketUnconnected,
        .NETWORK_UNREACHABLE, .HOST_UNREACHABLE => error.NetworkDown,
        else => unexpected(status),
    };
}

pub fn netWrite(status: Status) Io.Operation.NetWrite.Error {
    return switch (status) {
        .INSUFFICIENT_RESOURCES, .NO_MEMORY => error.SystemResources,
        .CONNECTION_RESET, .REMOTE_DISCONNECT => error.ConnectionResetByPeer,
        .IO_TIMEOUT => error.ConnectionTimedOut,
        .INVALID_CONNECTION, .CONNECTION_INVALID, .CONNECTION_DISCONNECTED, .GRACEFUL_DISCONNECT, .PIPE_DISCONNECTED => error.SocketUnconnected,
        .NETWORK_UNREACHABLE => error.NetworkUnreachable,
        .HOST_UNREACHABLE => error.HostUnreachable,
        .CONNECTION_REFUSED => error.ConnectionRefused,
        else => unexpected(status),
    };
}

pub fn receive(status: Status) net.Socket.ReceiveError {
    return switch (status) {
        .INSUFFICIENT_RESOURCES, .NO_MEMORY => error.SystemResources,
        .BUFFER_OVERFLOW => error.MessageOversize,
        .PORT_UNREACHABLE => error.PortUnreachable,
        .CONNECTION_RESET, .REMOTE_DISCONNECT => error.ConnectionResetByPeer,
        .IO_TIMEOUT => error.ConnectionTimedOut,
        .INVALID_CONNECTION, .CONNECTION_INVALID, .CONNECTION_DISCONNECTED => error.SocketUnconnected,
        .NETWORK_UNREACHABLE, .HOST_UNREACHABLE => error.NetworkDown,
        else => unexpected(status),
    };
}

pub fn send(status: Status) net.Socket.SendError {
    return switch (status) {
        .INSUFFICIENT_RESOURCES, .NO_MEMORY => error.SystemResources,
        .BUFFER_OVERFLOW, .INVALID_BUFFER_SIZE => error.MessageOversize,
        .NETWORK_UNREACHABLE => error.NetworkUnreachable,
        .HOST_UNREACHABLE => error.HostUnreachable,
        .CONNECTION_REFUSED, .PORT_UNREACHABLE => error.ConnectionRefused,
        .CONNECTION_RESET, .REMOTE_DISCONNECT => error.ConnectionResetByPeer,
        .IO_TIMEOUT => error.ConnectionTimedOut,
        .INVALID_CONNECTION, .CONNECTION_INVALID, .CONNECTION_DISCONNECTED => error.SocketUnconnected,
        .ACCESS_DENIED => error.AccessDenied,
        else => unexpected(status),
    };
}

pub fn connect(status: Status) op.ConnectError {
    return switch (status) {
        .INSUFFICIENT_RESOURCES, .NO_MEMORY => error.SystemResources,
        .CONNECTION_REFUSED => error.ConnectionRefused,
        .CONNECTION_RESET, .REMOTE_DISCONNECT => error.ConnectionResetByPeer,
        .NETWORK_UNREACHABLE => error.NetworkUnreachable,
        .HOST_UNREACHABLE, .PROTOCOL_UNREACHABLE, .PORT_UNREACHABLE => error.HostUnreachable,
        .IO_TIMEOUT => error.Timeout,
        .ADDRESS_ALREADY_ASSOCIATED, .ADDRESS_ALREADY_EXISTS => error.AddressUnavailable,
        .INVALID_ADDRESS, .INVALID_ADDRESS_COMPONENT => error.AddressUnavailable,
        .ACCESS_DENIED, .NETWORK_ACCESS_DENIED => error.AccessDenied,
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => error.FileNotFound,
        else => unexpected(status),
    };
}

pub fn accept(status: Status) net.Server.AcceptError {
    return switch (status) {
        .INSUFFICIENT_RESOURCES, .NO_MEMORY => error.SystemResources,
        .CONNECTION_RESET, .CONNECTION_ABORTED, .REMOTE_DISCONNECT, .CONNECTION_DISCONNECTED => error.ConnectionAborted,
        .INVALID_PARAMETER, .INVALID_CONNECTION, .CONNECTION_INVALID => error.SocketNotListening,
        .TOO_MANY_OPENED_FILES => error.ProcessFdQuotaExceeded,
        else => unexpected(status),
    };
}
