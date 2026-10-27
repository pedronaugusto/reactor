//! What an operation is, what it returns, and what the loop and its
//! backend keep in it while it is under way: `Op`, the operation as its
//! backend sees it, which `Loop.Op` embeds beside its completion.
const builtin = @import("builtin");
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const Wheel = @import("../Wheel.zig");
const uring = @import("uring/scratch.zig");
const iocp = @import("iocp/scratch.zig");
const Waiter = @import("readiness/Waiter.zig");
const kernel_time = @import("kernel_time.zig");

/// An operation as its backend sees it: what to do, its result, the
/// loop's and the backend's state while it is under way, and its linked
/// deadline. Caller-owned and pinned from `submit` until its completion is
/// delivered.
pub const Op = struct {
    kind: Kind,
    /// Valid once completed, under the field of `kind`.
    result: Result align(@alignOf(Kind)) = undefined,
    /// The loop's and its backend's from `submit` to delivery.
    state: State = .{},
    /// Absolute deadline, linked in the kernel where supported. Other
    /// backends are timed by the runtime's wheel.
    linked: if (builtin.os.tag == .linux) Linked else void = if (builtin.os.tag == .linux) .{} else {},
};

/// A deadline in the operation's own bytes: sixteen of them, where an
/// optional timestamp would take forty-eight in every operation.
pub const Linked = struct {
    /// The deadline on `clock`; read only when `set`.
    at: kernel_time.KernelTime = .fromRaw(0),
    clock: Io.Clock = .awake,
    set: bool = false,

    pub fn of(at: ?Io.Clock.Timestamp) Linked {
        const t = at orelse return .{};
        return .{ .at = kernel_time.of(t.raw), .clock = t.clock, .set = true };
    }
};

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

/// What moves an operation from one phase to the next.
pub const Move = enum(u8) {
    /// A timer goes on the loop's wheel.
    arm,
    /// Handed to the backend.
    hand,
    /// The backend gave it back without holding it: refused, or made at once.
    back,
    /// Completed at submit, queued for delivery.
    finish,
    /// Completed by the kernel or its cancel, queued for delivery.
    complete,
    /// Delivered to its completion.
    deliver,
    /// Delivered with no completion: kept for `reap`.
    keep,
    /// Taken by `reap`.
    reap,
};

/// The phases an operation goes through, and the moves between them.
pub const Life = aegis.state.Machine(Phase, Move, .{ .initial = .idle, .edges = &.{
    .{ .from = .idle, .on = .arm, .to = .timer },
    .{ .from = .idle, .on = .hand, .to = .kernel },
    .{ .from = .kernel, .on = .back, .to = .idle },
    .{ .from = .idle, .on = .finish, .to = .done },
    .{ .from = .kernel, .on = .complete, .to = .done },
    .{ .from = .timer, .on = .deliver, .to = .idle },
    .{ .from = .kernel, .on = .deliver, .to = .idle },
    .{ .from = .done, .on = .deliver, .to = .idle },
    .{ .from = .timer, .on = .keep, .to = .done },
    .{ .from = .kernel, .on = .keep, .to = .done },
    .{ .from = .done, .on = .keep, .to = .done },
    .{ .from = .done, .on = .reap, .to = .idle },
} });

/// The loop's and the backend's, from `submit` to delivery.
pub const State = struct {
    phase: Life.Runtime(void) = .init({}),
    /// The owner asked the kernel to end it.
    canceled: bool = false,
    /// The link of whichever queue holds it: the loop's completions, a
    /// backend's own.
    next: ?*Op = null,
    /// The phase owns the wheel node or kernel scratch, never both.
    storage: Storage = .{ .node = .{} },

    /// Kernel ownership beyond the primary CQE: linked timeout and
    /// SEND_ZC notification must both settle before the frame is freed.
    uring: if (builtin.os.tag == .linux) UringState else struct { timeout_pending: bool = false, timed_out: bool = false } = .{},

    pub const Storage = union {
        node: Wheel.Node,
        scratch: Scratch,
    };

    /// Where the operation is.
    pub fn current(s: *const State) Phase {
        return s.phase.current();
    }

    /// Moves the operation on; a move its phase does not have is a bug in the
    /// loop, stopped in every build.
    pub fn move(s: *State, m: Move) void {
        _ = s.phase.step(m) catch std.debug.panic("reactor: an operation in phase {t} cannot {t}", .{ s.phase.current(), m });
    }
};

/// What an operation keeps for its backend while the kernel holds it,
/// under the backend's field (a readiness backend's under its poller's
/// `name`).
pub const Scratch = union {
    /// A custom backend keeps nothing in an operation.
    custom: void,
    io_uring: if (has_uring) uring.Scratch else void,
    iocp: if (has_iocp) iocp.Scratch else void,
    epoll: if (has_epoll) Waiter else void,
    kqueue: if (has_kqueue) Waiter else void,
};

/// The backends this system has.
pub const has_uring = builtin.os.tag == .linux;
pub const has_iocp = builtin.os.tag == .windows;
pub const has_epoll = builtin.os.tag == .linux;
pub const has_kqueue = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

/// Backend escapes preserve the ordinary operation's cancellation lifetime.
/// Each is a node the caller keeps in its own request, which its function
/// finds again from the node (`@fieldParentPtr`).
pub const Raw = union(enum) {
    uring: *UringRequest,
    windows: *WindowsRequest,
};

/// A request a caller writes into an io_uring submission entry itself.
pub const UringRequest = struct {
    prepare: *const fn (*UringRequest, *std.os.linux.io_uring_sqe) void,
};

/// An NT overlapped call a caller makes itself on `handle`, its status
/// block and APC context the backend's.
pub const WindowsRequest = struct {
    handle: std.os.windows.HANDLE,
    start: *const fn (*WindowsRequest, *std.os.windows.IO_STATUS_BLOCK, *anyopaque) std.os.windows.NTSTATUS,
};
pub const RawResult = union(enum) { uring: i32, windows: std.os.windows.IO_STATUS_BLOCK };

pub const UringState = struct {
    /// Its `user_data` while the ring holds it: the key of its entry in the
    /// ring's table.
    key: u64 = 0,
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
