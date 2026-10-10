//! What an operation is, what it returns, and what the loop and its
//! backend keep in it while it is under way. `Loop.Op` is built from these;
//! the backends see an operation through these fields only.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Wheel = @import("../Wheel.zig");

pub const SqPoll = struct { idle_ms: u32 = 1000, cpu: ?u32 = null };

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
    /// The descriptor has a priority event, which `poll` reports as
    /// `POLLPRI`: urgent data on a stream socket, a change to a
    /// `cgroup.events` or sysfs attribute file; or an error. io_uring and
    /// epoll only: kqueue has no filter for it, and Windows no such event.
    priority: Io.File.Handle,
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
        /// The phase owns the wheel node or kernel scratch, never both.
        storage: Storage = .{ .node = .{} },

        /// Kernel ownership beyond the primary CQE: linked timeout and
        /// SEND_ZC notification must both settle before the frame is freed.
        uring: if (builtin.os.tag == .linux) UringState else struct { timeout_pending: bool = false, timed_out: bool = false } = .{},

        pub const Storage = union {
            node: Wheel.Node,
            scratch: Scratch,
        };
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

pub const UringState = struct {
    timeout_pending: bool = false,
    notification_pending: bool = false,
    notification_seen: bool = false,
    primary_done: bool = false,
    use_copy: bool = false,
    zero_copy: bool = false,
    fixed_buffer: ?u16 = null,
    timed_out: bool = false,
    timespec: std.os.linux.kernel_timespec = undefined,
    primary: std.os.linux.io_uring_cqe = undefined,

    /// Completion ordering is independent of storage lifetime. Every
    /// ownership grant ends before ready becomes true, in either order.
    pub fn completed(state: *UringState, cqe: std.os.linux.io_uring_cqe) void {
        if (cqe.flags & std.os.linux.IORING_CQE_F_NOTIF != 0) {
            state.notification_seen = true;
            state.notification_pending = false;
        } else {
            state.primary_done = true;
            state.primary = cqe;
            state.notification_pending = cqe.flags & std.os.linux.IORING_CQE_F_MORE != 0 and !state.notification_seen;
        }
    }
    pub fn ready(state: *const UringState) bool {
        return state.primary_done and !state.timeout_pending and !state.notification_pending;
    }
};
