//! What an operation is, what it returns, and what the loop and its
//! backend keep in it while it is under way. `Loop.Op` is built from these;
//! the backends see an operation through these fields only.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Wheel = @import("../Wheel.zig");

pub const Kind = union(enum) {
    /// Every `Io.Operation`: net and file reads and writes, device control.
    io: Io.Operation,
    /// A connection from a listening socket.
    accept: Io.net.Socket.Handle,
    connect: Connect,
    read_at: ReadAt,
    write_at: WriteAt,
    sync: Io.File.Handle,
    close: Io.File.Handle,
    /// Ends every operation this loop's kernel queue holds on the
    /// descriptor; each completes as cancelled.
    abort: Io.File.Handle,
    /// Fires at a deadline on its clock.
    timer: Io.Clock.Timestamp,
    /// Readiness of a descriptor.
    wait: Waitable,
    /// A caller-prepared native request.
    raw: Raw,
};

pub const Connect = struct {
    socket: Io.net.Socket.Handle,
    address: Address,
    /// The socket is in non-blocking mode already, and its owner puts it
    /// back: a readiness backend need not look.
    nonblocking: bool = false,

    pub const Address = union(enum) {
        ip: Io.net.IpAddress,
        unix: *const Io.net.UnixAddress,
    };
};

pub const ReadAt = struct { file: Io.File.Handle, buffer: []u8, offset: u64 };
pub const WriteAt = struct { file: Io.File.Handle, bytes: []const u8, offset: u64 };

/// What a `wait` operation waits for.
pub const Waitable = union(enum) {
    /// The descriptor has data, end of file, or an error.
    readable: Io.File.Handle,
    /// The descriptor has room, or an error.
    writable: Io.File.Handle,
    /// Windows: a waitable kernel object.
    object: if (builtin.os.tag == .windows) std.os.windows.HANDLE else noreturn,

    pub const Error = error{ Unsupported, Unexpected };
};

/// The result of a completed operation, under the field of its kind. Each
/// error set is std's for the same call; a cancelled operation completes
/// with `error.Canceled` unless it finished first.
pub const Result = union {
    io: Io.Cancelable!Io.Operation.Result,
    /// The accepted socket and its peer's address.
    accept: Io.net.Server.AcceptError!Io.net.Socket,
    connect: ConnectError!void,
    read_at: (Io.File.ReadPositionalError || Io.Cancelable)!usize,
    write_at: (Io.File.WritePositionalError || Io.Cancelable)!usize,
    sync: Io.File.SyncError!void,
    close: void,
    /// How many operations it ended.
    abort: usize,
    timer: Io.Cancelable!void,
    wait: (Waitable.Error || Io.Cancelable)!void,
    raw: Io.Cancelable!RawResult,
};

pub const ConnectError = Io.net.IpAddress.ConnectError || Io.net.UnixAddress.ConnectError || Io.Cancelable;

/// Where an operation is between `submit` and its completion.
pub const Phase = enum(u8) {
    /// Not submitted, or completed and delivered.
    idle,
    /// On the loop's wheel (timers).
    timer,
    /// Handed to the kernel.
    kernel,
    /// Completed, waiting on the loop's completion queue.
    done,
};

/// The loop's and the backend's, from `submit` to delivery.
pub fn State(comptime Scratch: type) type {
    return struct {
        phase: Phase = .idle,
        /// The owner asked the kernel to end it.
        canceled: bool = false,
        /// The completion queue's link.
        next: ?*anyopaque = null,
        /// A timer's place on the wheel.
        node: Wheel.Node = .{},
        /// What the backend needs alive while the kernel holds the operation.
        scratch: Scratch = undefined,
    };
}

/// Backend escapes preserve the ordinary operation's cancellation lifetime.
pub const Raw = union(enum) {
    uring: struct { context: *anyopaque, prepare: *const fn (*anyopaque, *std.os.linux.io_uring_sqe) void },
    windows: struct {
        handle: std.os.windows.HANDLE,
        context: *anyopaque,
        start: *const fn (*anyopaque, *std.os.windows.IO_STATUS_BLOCK, *anyopaque) std.os.windows.NTSTATUS,
    },
};
pub const RawResult = union(enum) { uring: i32, windows: std.os.windows.IO_STATUS_BLOCK };
