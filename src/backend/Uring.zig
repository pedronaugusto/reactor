//! io_uring: every operation an entry in the submission ring, submitted
//! with the wait for completions in one `io_uring_enter` per pass.
//!
//! The ring belongs to one thread for its life (`SINGLE_ISSUER`, and
//! `DEFER_TASKRUN` where the kernel has it: completions run only when that
//! thread asks for them). A ring built for another thread starts disabled
//! and is enabled there. Wakes from other threads write an eventfd the ring
//! polls (multishot); a host's poller gets a second eventfd the kernel
//! signals on every completion, registered only when asked for, since it
//! costs a signal per completion.
//!
//! A completion's `user_data` is an operation's address, or a batch token,
//! with a tag in its three low bits.
const Uring = @This();

const std = @import("std");
const aegis = @import("aegis");
const assert = std.debug.assert;
const Io = std.Io;
const net = Io.net;
const linux = std.os.linux;
const posix = std.posix;
const Threaded = Io.Threaded;

const op = @import("op.zig");
const pending = @import("pending.zig");
const Wait = @import("wait.zig").Wait;
const timeline = @import("../clock.zig");
const Receive = @import("uring/Receive.zig");
const Accept = @import("uring/Accept.zig");
const Buffers = @import("uring/Buffers.zig");
const Files = @import("uring/Files.zig");
const Allocator = std.mem.Allocator;
const results = @import("uring/results.zig");

pub const Features = packed struct(u7) {
    accept_ahead: bool = false,
    fixed_files: bool = false,
    defer_taskrun: bool = false,
    msg_ring: bool = false,
    waitid: bool = false,
    linked_timeout: bool = false,
    zero_copy: bool = false,
};

pub const Options = struct {
    /// Submission queue entries, a power of two.
    entries: u16,
    /// Completion queue entries, a power of two at least `2 * entries`.
    completions: u32,
    /// Features left off.
    off: Features = .{},
    /// Built for another thread, which calls `enable`.
    disabled: bool = false,
    sqpoll: ?op.SqPoll = null,
    zero_copy_min: ?aegis.units.Bytes(usize) = null,
    registered_pools: u16 = 64,
    pending_bound: u32 = 1024,
};

pub const InitError = error{ BackendUnavailable, SystemResources, Unexpected };

/// What an operation keeps while the kernel holds it.
pub const Scratch = union {
    message: Message,
    address: Address,
    timespec: linux.kernel_timespec,
};

const Message = struct {
    header: linux.msghdr,
    iovecs: [Threaded.max_iovecs_len]posix.iovec,
    address: Threaded.PosixAddress,
    splat: [Threaded.splat_buffer_size]u8,
};

const Address = struct {
    storage: extern union { ip: Threaded.PosixAddress, unix: posix.sockaddr.un },
    len: posix.socklen_t,
};

const Tag = enum(u3) {
    /// An operation's completion: the address of its `Op`.
    op = 0,
    /// A batch operation's result: a token.
    batch = 1,
    /// A batch operation's readiness: a token; the call is made then.
    batch_ready = 2,
    /// The wake eventfd's poll.
    wake = 3,
    /// A completion nobody waits for (a cancel's, a close's first step).
    ignore = 4,
    listener = 5,
    receiver = 6,
    auxiliary = 7,
};

fn userData(address: u64, tag: Tag) u64 {
    assert(address & 7 == 0);
    return address | @backingInt(tag);
}

fn tagOf(user_data: u64) Tag {
    return @fromBackingInt(@intCast(@as(u3, @truncate(user_data))));
}

ring: linux.IoUring,
zero_copy_min: ?usize,
next_group: std.atomic.Value(u32) = .init(1),
accepts: Accept,
/// Requests that a descriptor-wide cancellation could end, excluding
/// listener slots (which close cancels individually) and the wake poll.
active: usize = 0,
files: Files,
buffers: Buffers,
/// Opcodes the kernel has.
supported: std.EnumSet(linux.IORING_OP),
features: Features,
wake_fd: linux.fd_t,
wake_armed: bool = false,
wake_buffer: u64 = 0,
/// Set by `wake` until the ring has read the eventfd: later wakes skip
/// the write.
wake_pending: std.atomic.Value(bool) = .init(false),
/// One queued ring message is enough until its target consumes it.
message_pending: std.atomic.Value(bool) = .init(false),
notify_fd: ?linux.fd_t = null,
enabled: bool,
/// The kernel flags the ring when completions wait to be run.
taskrun_flag: bool = false,
/// Batch lists belong to parked callers. Pressure keeps their CQEs until
/// poll instead of mutating a list a submitting/canceling task is walking.
deferred: []linux.io_uring_cqe,
deferred_head: usize = 0,
deferred_count: usize = 0,
draining_pressure: bool = false,
/// Installed by the loop on its owner before submissions. Pressure drains
/// kernel ownership while leaving user callbacks queued until Loop.run.
pressure: ?struct {
    context: *anyopaque,
    complete: *const fn (*anyopaque, linux.io_uring_cqe) void,
} = null,

pub fn init(gpa: Allocator, options: Options) (InitError || Allocator.Error)!Uring {
    var u: Uring = .{
        .ring = undefined,
        // Validated here once; the send path compares a plain length.
        .zero_copy_min = if (options.zero_copy_min) |min| min.raw() else null,
        .accepts = undefined,
        .files = undefined,
        .buffers = undefined,
        .supported = .empty,
        .features = .{},
        .wake_fd = undefined,
        .enabled = !options.disabled,
        .deferred = try gpa.alloc(linux.io_uring_cqe, options.pending_bound),
    };
    errdefer gpa.free(u.deferred);
    u.ring = try setup(options, &u.features, &u.taskrun_flag);
    errdefer u.ring.deinit();
    u.probe();
    u.features.waitid = !options.off.waitid and u.has(.WAITID);
    u.features.msg_ring = !options.off.msg_ring and u.has(.MSG_RING);
    u.features.linked_timeout = !options.off.linked_timeout and u.has(.LINK_TIMEOUT);
    u.features.zero_copy = !options.off.zero_copy and u.has(.SEND_ZC);
    u.accepts = try Accept.init(gpa, options.entries, !options.off.accept_ahead and u.has(.ACCEPT));
    errdefer u.accepts.deinit(gpa);
    u.files = try Files.init(gpa, &u.ring, options.entries, !options.off.fixed_files);
    errdefer u.files.deinit(gpa);
    u.buffers = try Buffers.init(gpa, &u.ring, options.registered_pools);
    errdefer u.buffers.deinit(gpa);
    u.features.accept_ahead = u.accepts.enabled;
    u.features.fixed_files = u.files.enabled;
    const efd = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(efd) != .SUCCESS) return error.SystemResources;
    u.wake_fd = @intCast(efd);
    return u;
}

/// The ring, with every flag the kernel takes, dropping them one by one.
fn setup(options: Options, features: *Features, taskrun_flag: *bool) InitError!linux.IoUring {
    if (options.entries < 2) return error.BackendUnavailable;
    const want_defer = options.sqpoll == null and !options.off.defer_taskrun;
    // TASKRUN_FLAG: the kernel marks the ring when completions wait to be
    // run, so a poll that has nothing to submit or wait for can skip the
    // syscall.
    const taskrun = linux.IORING_SETUP_TASKRUN_FLAG;
    const tries = [_]struct { flags: u32, defer_taskrun: bool, taskrun_flag: bool }{
        .{ .flags = linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_DEFER_TASKRUN | linux.IORING_SETUP_SUBMIT_ALL | taskrun, .defer_taskrun = true, .taskrun_flag = true },
        .{ .flags = linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_COOP_TASKRUN | linux.IORING_SETUP_SUBMIT_ALL | taskrun, .defer_taskrun = false, .taskrun_flag = true },
        .{ .flags = linux.IORING_SETUP_COOP_TASKRUN | linux.IORING_SETUP_SUBMIT_ALL, .defer_taskrun = false, .taskrun_flag = false },
        .{ .flags = 0, .defer_taskrun = false, .taskrun_flag = false },
    };
    for (tries) |t| {
        if (t.defer_taskrun and !want_defer) continue;
        var params = std.mem.zeroInit(linux.io_uring_params, .{
            .flags = (if (options.sqpoll) |polling| linux.IORING_SETUP_SQPOLL | linux.IORING_SETUP_SUBMIT_ALL | @as(u32, if (polling.cpu != null) linux.IORING_SETUP_SQ_AFF else 0) else t.flags) | linux.IORING_SETUP_CQSIZE | @as(u32, if (options.disabled) linux.IORING_SETUP_R_DISABLED else 0),
            .sq_thread_idle = if (options.sqpoll) |polling| polling.idle_ms else 0,
            .sq_thread_cpu = if (options.sqpoll) |polling| polling.cpu orelse 0 else 0,
            .cq_entries = options.completions,
        });
        const ring = linux.IoUring.init_params(options.entries, &params) catch |err| switch (err) {
            error.ArgumentsInvalid => continue,
            error.PermissionDenied, error.SystemOutdated => return error.BackendUnavailable,
            error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.SystemResources => return error.SystemResources,
            else => return error.Unexpected,
        };
        // The floor: completions never dropped, and a wait with a timeout.
        if (params.features & linux.IORING_FEAT_NODROP == 0 or params.features & linux.IORING_FEAT_EXT_ARG == 0) {
            var r = ring;
            r.deinit();
            return error.BackendUnavailable;
        }
        features.defer_taskrun = options.sqpoll == null and t.defer_taskrun;
        taskrun_flag.* = options.sqpoll == null and t.taskrun_flag;
        return ring;
    }
    return error.BackendUnavailable;
}

fn probe(u: *Uring) void {
    const p = u.ring.get_probe() catch return;
    // Read by index: a newer kernel may name opcodes this enum does not.
    for (p.ops[0..@min(p.ops_len, p.ops.len)], 0..) |o, i| {
        if (o.flags & linux.IO_URING_OP_SUPPORTED == 0) continue;
        if (std.enums.fromInt(linux.IORING_OP, i)) |known| u.supported.insert(known);
    }
}

pub fn has(u: *const Uring, opcode: linux.IORING_OP) bool {
    return u.supported.contains(opcode);
}

/// On the ring's own thread, for a ring built disabled.
pub fn enable(u: *Uring) void {
    if (u.enabled) return;
    const rc = linux.io_uring_register(u.ring.fd, .REGISTER_ENABLE_RINGS, null, 0);
    if (linux.errno(rc) != .SUCCESS) std.debug.panic("reactor: enabling a ring failed: {t}", .{linux.errno(rc)});
    u.enabled = true;
}

pub fn deinit(u: *Uring, gpa: Allocator) void {
    u.drainListeners();
    u.accepts.deinit(gpa);
    gpa.free(u.deferred);
    u.files.deinit(gpa);
    u.buffers.deinit(gpa);
    if (u.notify_fd) |fd| _ = linux.close(fd);
    _ = linux.close(u.wake_fd);
    u.ring.deinit();
    u.* = undefined;
}

/// Persistent listeners are reaped on the ring's owner before it exits.
pub fn drainListeners(u: *Uring) void {
    for (u.accepts.records) |*r| if (r.fd != -1) u.accepts.close(u, r.fd);
    while (true) {
        const active = for (u.accepts.records) |r| {
            if (r.armed) break true;
        } else false;
        if (!active) return;
        u.enter(.forever) catch |err| std.debug.panic("reactor: draining listeners failed: {t}", .{err});
        var cqes: [256]linux.io_uring_cqe = undefined;
        const count = u.ring.copy_cqes(&cqes, 0) catch unreachable; // unreachable: the ring remains valid until the terminal completions
        for (cqes[0..count]) |cqe| switch (tagOf(cqe.user_data)) {
            .listener => {
                const slot: *Accept.Slot = @ptrFromInt(cqe.user_data & ~@as(u64, 7)); // safe: a live table entry owns this token
                u.accepts.drain(slot, cqe.res);
            },
            .wake, .ignore => {},
            .auxiliary => if (cqe.user_data & ~@as(u64, 7) != 0) std.debug.panic("reactor: an operation outlived its owner", .{}),
            else => std.debug.panic("reactor: an operation outlived its owner", .{}),
        };
    }
}

/// Persistent kernel ownership survives the task that first used it.
pub fn contains(u: *const Uring, fd: linux.fd_t) bool {
    return u.files.contains(fd) or u.accepts.contains(fd);
}

// Submission.

/// An entry to fill: flushes the queue to the kernel when it is full.
pub fn entry(u: *Uring) *linux.io_uring_sqe {
    while (true) {
        return u.ring.get_sqe() catch {
            _ = u.ring.submit() catch |err| switch (err) {
                error.SignalInterrupt => {},
                error.SystemResources => u.drainPressure(),
                else => std.debug.panic("reactor: the ring refused its submissions: {t}", .{err}),
            };
            continue;
        };
    }
}

/// Free CQ capacity without running user callbacks inside submission.
fn drainPressure(u: *Uring) void {
    const pressure = u.pressure orelse std.debug.panic("reactor: unowned ring exhausted its completion queue", .{});
    var cqes: [256]linux.io_uring_cqe = undefined;
    const count = u.ring.copy_cqes(&cqes, 0) catch |err| switch (err) {
        error.SignalInterrupt => return,
        else => std.debug.panic("reactor: pressure drain failed: {t}", .{err}),
    };
    const previous = u.draining_pressure;
    u.draining_pressure = true;
    defer u.draining_pressure = previous;
    for (cqes[0..count]) |cqe| pressure.complete(pressure.context, cqe);
}

/// SQPOLL may consume published entries concurrently. Wait until it has
/// acquired their file references before editing or unregistering a slot.
pub fn consumePublished(u: *Uring) void {
    if (u.ring.flags & linux.IORING_SETUP_SQPOLL == 0) return;
    const tail = u.ring.sq.sqe_head;
    while (@atomicLoad(u32, u.ring.sq.head, .acquire) != tail) {
        u.enter(.nowait) catch |err| std.debug.panic("reactor: SQPOLL submission failed: {t}", .{err});
        if (u.ring.cq_ready() == u.ring.cq.cqes.len) u.drainPressure();
        std.atomic.spinLoopHint();
    }
}

pub fn submit(u: *Uring, o: anytype) error{ SystemResources, Unexpected }!void {
    // The kernel's linked timeout is two more entries and a timer in the
    // kernel for each operation, and most operations finish before their
    // deadline: a read under a deadline lost 60% of its rate on a two-thread
    // runtime in the lima VM and 4% on a hosted runner against the wheel,
    // which arms and disarms in userspace. A connect is one operation per
    // connection and the one that most often sits out its deadline, so it
    // alone is linked.
    const linked = u.features.linked_timeout and o.linked.set and o.kind == .connect;
    if (linked) u.reserveEntries(2);
    const ud = userData(@intFromPtr(o), .op); // safe: read back as the `Op` in `complete`
    switch (o.kind) {
        .raw => |raw| switch (raw) {
            .uring => |request| {
                const sqe = u.entry();
                request.prepare(request.context, sqe);
                sqe.user_data = ud;
            },
            .windows => unreachable, // unreachable: only uring requests reach Linux
        },
        .io => |*operation| u.submitIo(o, operation, ud),
        .accept => {
            if (u.accepts.submit(u, o)) return;
            u.submitSingleAccept(o);
        },
        .connect => |c| {
            o.state.storage.scratch = .{ .io_uring = .{ .address = undefined } };
            const a = &o.state.storage.scratch.io_uring.address;
            a.* = .{ .storage = undefined, .len = 0 };
            a.len = switch (c.address) {
                .ip => |*ip| Threaded.addressToPosix(ip, &a.storage.ip),
                .unix => |unix| unixToPosix(unix, &a.storage.unix),
            };
            const sqe = u.entry();
            sqe.prep_connect(c.socket, @ptrCast(&a.storage), a.len); // safe: the storage is a socket address of the length given
            sqe.user_data = ud;
        },
        .read_at => |r| {
            const sqe = u.entry();
            sqe.prep_read(r.file, r.buffer[0..@min(r.buffer.len, max_rw)], r.offset);
            sqe.user_data = ud;
            u.files.use(&u.ring, sqe);
            o.state.uring.fixed_buffer = u.buffers.use(sqe);
        },
        .write_at => |w| {
            const sqe = u.entry();
            sqe.prep_write(w.file, w.bytes[0..@min(w.bytes.len, max_rw)], w.offset);
            sqe.user_data = ud;
            u.files.use(&u.ring, sqe);
            o.state.uring.fixed_buffer = u.buffers.use(sqe);
        },
        .sync => |fd| {
            const sqe = u.entry();
            sqe.prep_fsync(fd, 0);
            sqe.user_data = ud;
            u.files.use(&u.ring, sqe);
        },
        .close => |fd| u.submitClose(fd, ud),
        .abort => |fd| {
            u.accepts.close(u, fd);
            u.files.remove(u, fd);
            const sqe = u.entry();
            sqe.prep_cancel_fd(fd, linux.IORING_ASYNC_CANCEL_ALL);
            sqe.user_data = ud;
        },
        .timer => |deadline| {
            o.state.storage.scratch = .{ .io_uring = .{ .timespec = undefined } };
            const ts = &o.state.storage.scratch.io_uring.timespec;
            ts.* = timespecOf(deadline.raw.nanoseconds);
            const clock_flag: u32 = switch (deadline.clock) {
                .real => linux.IORING_TIMEOUT_REALTIME,
                .boot => linux.IORING_TIMEOUT_BOOTTIME,
                else => 0,
            };
            const sqe = u.entry();
            sqe.prep_timeout(ts, 0, linux.IORING_TIMEOUT_ABS | clock_flag);
            sqe.user_data = ud;
        },
        .wait => |w| {
            const sqe = u.entry();
            switch (w) {
                .readable => |fd| sqe.prep_poll_add(fd, linux.POLL.IN),
                .writable => |fd| sqe.prep_poll_add(fd, linux.POLL.OUT),
                // On Linux 6.8 a poll for `POLLPRI` alone sleeps through a
                // socket's urgent data, whose wake carries `IN | PRI |
                // RDNORM | RDBAND`. Asking for `RDBAND` as well lets that
                // wake in; no file reports it steadily, so the poll still
                // ends on `PRI` and not on plain data.
                .priority => |fd| sqe.prep_poll_add(fd, linux.POLL.PRI | linux.POLL.RDBAND),
                .object => unreachable, // unreachable: Windows objects do not exist on Linux
            }
            sqe.user_data = ud;
        },
    }
    if (linked) {
        const primary = &u.ring.sq.sqes[(u.ring.sq.sqe_tail -% 1) & u.ring.sq.mask];
        primary.flags |= linux.IOSQE_IO_LINK;
        const at = o.linked;
        o.state.uring.timespec = timespecOf(at.ns);
        o.state.uring.timeout_pending = true;
        const sqe = u.entry();
        sqe.prep_link_timeout(&o.state.uring.timespec, linux.IORING_TIMEOUT_ABS | @as(u32, switch (at.clock) {
            .real => linux.IORING_TIMEOUT_REALTIME,
            .boot => linux.IORING_TIMEOUT_BOOTTIME,
            else => 0,
        }));
        sqe.user_data = userData(@intFromPtr(o), .auxiliary); // safe: retained until primary and timeout complete
    }
    u.active += 1;
}

fn reserveEntries(u: *Uring, count: u32) void {
    while (u.ring.sq_ready() + count > u.ring.sq.sqes.len) {
        _ = u.ring.submit() catch |err| switch (err) {
            error.SignalInterrupt => {},
            error.SystemResources => u.drainPressure(),
            else => std.debug.panic("reactor: reserving linked entries failed: {t}", .{err}),
        };
    }
}

/// A kernel without multishot support uses ordinary accept requests.
pub fn submitSingleAccept(u: *Uring, o: anytype) void {
    o.state.storage.scratch = .{ .io_uring = .{ .address = undefined } };
    const a = &o.state.storage.scratch.io_uring.address;
    a.* = .{ .storage = undefined, .len = @sizeOf(@TypeOf(a.storage)) };
    const sqe = u.entry();
    sqe.prep_accept(o.kind.accept, @ptrCast(&a.storage), &a.len, linux.SOCK.CLOEXEC); // safe: the kernel writes a socket address here
    sqe.user_data = userData(@intFromPtr(o), .op); // safe: this operation's own token
}

/// The most one read or write moves: Linux's own cap.
const max_rw = 0x7ffff000;

fn submitIo(u: *Uring, o: anytype, operation: *const Io.Operation, ud: u64) void {
    const sqe = u.entry();
    switch (operation.*) {
        .file_read_streaming => |r| sqe.prep_read(r.file.handle, firstBuffer(r.data), std.math.maxInt(u64)),
        .file_write_streaming => |w| sqe.prep_write(w.file.handle, firstChunk(w.header, w.data, w.splat), std.math.maxInt(u64)),
        .net_read => |r| if (r.control.len == 0) {
            sqe.prep_recv(r.socket_handle, firstBuffer(r.data), 0);
        } else {
            o.state.storage.scratch = .{ .io_uring = .{ .message = undefined } };
            const m = &o.state.storage.scratch.io_uring.message;
            m.header = .{ .name = null, .namelen = 0, .iov = &m.iovecs, .iovlen = gather(&m.iovecs, r.data), .control = r.control.ptr, .controllen = @intCast(r.control.len), .flags = 0 };
            sqe.prep_recvmsg(r.socket_handle, &m.header, posix.MSG.CMSG_CLOEXEC);
        },
        .net_write => |w| {
            o.state.storage.scratch = .{ .io_uring = .{ .message = undefined } };
            const m = &o.state.storage.scratch.io_uring.message;
            const count = scatter(&m.iovecs, &m.splat, w.header, w.data, w.splat);
            if (count == 1 and w.control.len == 0) {
                const bytes = @as([*]const u8, m.iovecs[0].base)[0..m.iovecs[0].len];
                if (!o.state.uring.use_copy and u.features.zero_copy and bytes.len >= (u.zero_copy_min orelse std.math.maxInt(usize))) sqe.prep_send_zc(w.socket_handle, bytes, posix.MSG.NOSIGNAL, 0) else sqe.prep_send(w.socket_handle, bytes, posix.MSG.NOSIGNAL);
            } else {
                m.header = .{ .name = null, .namelen = 0, .iov = &m.iovecs, .iovlen = count, .control = if (w.control.len == 0) null else @constCast(w.control.ptr), .controllen = @intCast(w.control.len), .flags = 0 }; // safe: the kernel only reads what a send gives it
                sqe.prep_sendmsg(w.socket_handle, @ptrCast(&m.header), posix.MSG.NOSIGNAL); // safe: msghdr and msghdr_const share their layout
            }
        },
        .net_receive => |r| {
            o.state.storage.scratch = .{ .io_uring = .{ .message = undefined } };
            const m = &o.state.storage.scratch.io_uring.message;
            const message = &r.message_buffer[0];
            m.iovecs[0] = .{ .base = r.data_buffer.ptr, .len = r.data_buffer.len };
            m.header = .{ .name = &m.address.any, .namelen = @sizeOf(Threaded.PosixAddress), .iov = &m.iovecs, .iovlen = 1, .control = message.control.ptr, .controllen = @intCast(message.control.len), .flags = 0 };
            sqe.prep_recvmsg(r.socket_handle, &m.header, receiveFlags(r.flags));
        },
        .net_send => |s| {
            o.state.storage.scratch = .{ .io_uring = .{ .message = undefined } };
            const m = &o.state.storage.scratch.io_uring.message;
            const message = &s.messages[0];
            m.iovecs[0] = .{ .base = @constCast(message.data_ptr), .len = message.data_len }; // safe: the kernel only reads what a send gives it
            m.header = .{ .name = &m.address.any, .namelen = Threaded.addressToPosix(message.address, &m.address), .iov = &m.iovecs, .iovlen = 1, .control = if (message.control.len == 0) null else @constCast(message.control.ptr), .controllen = @intCast(message.control.len), .flags = 0 }; // safe: the kernel only reads what a send gives it
            sqe.prep_sendmsg(s.socket_handle, @ptrCast(&m.header), results.sendFlags(s.flags)); // safe: msghdr and msghdr_const share their layout
        },
        .device_io_control => unreachable, // unreachable: device control runs borrowed
    }
    o.state.uring.zero_copy = sqe.opcode == .SEND_ZC;
    sqe.user_data = ud;
    switch (operation.*) {
        .file_read_streaming, .file_write_streaming => {
            u.files.use(&u.ring, sqe);
            o.state.uring.fixed_buffer = u.buffers.use(sqe);
        },
        else => {},
    }
}

/// Ends every operation this ring holds on `fd`, then closes it; the
/// close completes the operation.
fn submitClose(u: *Uring, fd: linux.fd_t, ud: u64) void {
    u.accepts.close(u, fd);
    u.files.remove(u, fd);
    if (u.active != 0 and u.has(.ASYNC_CANCEL)) {
        const cancel_sqe = u.entry();
        cancel_sqe.prep_cancel_fd(fd, linux.IORING_ASYNC_CANCEL_ALL);
        // Hard-linked: the close runs whatever the cancel found.
        cancel_sqe.flags |= linux.IOSQE_IO_HARDLINK;
        cancel_sqe.user_data = userData(0, .ignore);
    }
    const sqe = u.entry();
    sqe.prep_close(fd);
    sqe.user_data = ud;
}

pub fn cancel(u: *Uring, o: anytype) void {
    if (o.kind == .accept and u.accepts.cancel(o)) return;
    const sqe = u.entry();
    sqe.prep_cancel(userData(@intFromPtr(o), .op), 0); // safe: the operation's own user data
    sqe.flags |= linux.IOSQE_CQE_SKIP_SUCCESS;
    sqe.user_data = userData(0, .ignore);
}

// Batches.

/// How a batch operation is submitted: as itself (one buffer), or as a
/// poll after which the call is made, for what needs memory the batch's
/// storage cannot spare (control messages, message arrays).
fn readinessOnly(operation: Io.Operation) ?u32 {
    return switch (operation) {
        .net_read => |r| if (r.control.len != 0) linux.POLL.IN else null,
        .net_write => |w| if (w.control.len != 0) linux.POLL.OUT else null,
        .net_receive => linux.POLL.IN,
        .net_send => linux.POLL.OUT,
        else => null,
    };
}

pub fn submitPending(u: *Uring, token: pending.Token, operation: Io.Operation) error{ SystemResources, Unexpected }!void {
    u.active += 1;
    const sqe = u.entry();
    if (readinessOnly(operation)) |events| {
        sqe.prep_poll_add(socketOf(operation), events);
        sqe.user_data = userData(@backingInt(token), .batch_ready);
        return;
    }
    switch (operation) {
        .file_read_streaming => |r| sqe.prep_read(r.file.handle, firstBuffer(r.data), std.math.maxInt(u64)),
        .file_write_streaming => |w| sqe.prep_write(w.file.handle, firstChunk(w.header, w.data, w.splat), std.math.maxInt(u64)),
        .net_read => |r| sqe.prep_recv(r.socket_handle, firstBuffer(r.data), 0),
        .net_write => |w| sqe.prep_send(w.socket_handle, firstChunk(w.header, w.data, w.splat), posix.MSG.NOSIGNAL),
        else => unreachable, // unreachable: the rest go by readiness, device control never pends
    }
    sqe.user_data = userData(@backingInt(token), .batch);
    switch (operation) {
        .file_read_streaming, .file_write_streaming => u.files.use(&u.ring, sqe),
        else => {},
    }
}

pub fn cancelPending(u: *Uring, token: pending.Token) void {
    const tag: Tag = if (readinessOnly(pending.unpack(token.pending()))) |_| .batch_ready else .batch;
    const sqe = u.entry();
    sqe.prep_cancel(userData(@backingInt(token), tag), 0);
    sqe.flags |= linux.IOSQE_CQE_SKIP_SUCCESS;
    sqe.user_data = userData(0, .ignore);
}

fn socketOf(operation: Io.Operation) linux.fd_t {
    return switch (operation) {
        .net_read => |r| r.socket_handle,
        .net_write => |w| w.socket_handle,
        .net_receive => |r| r.socket_handle,
        .net_send => |s| s.socket_handle,
        .file_read_streaming => |r| r.file.handle,
        .file_write_streaming => |w| w.file.handle,
        .device_io_control => |d| d.file.handle,
    };
}

// Completion.

pub fn poll(u: *Uring, wait: Wait, sink: anytype) error{ SystemResources, Unexpected }!void {
    if (!u.wake_armed) u.armWake();
    var delivered = u.accepts.deliver(sink);
    while (u.deferred_count > 0) {
        const cqe = u.deferred[u.deferred_head];
        u.deferred_head = (u.deferred_head + 1) % u.deferred.len;
        u.deferred_count -= 1;
        u.complete(cqe, sink);
        delivered = true;
    }
    try u.enter(if (delivered) .nowait else wait);
    var cqes: [256]linux.io_uring_cqe = undefined;
    while (true) {
        const n = u.ring.copy_cqes(&cqes, 0) catch |err| switch (err) {
            error.SignalInterrupt => 0,
            else => return error.Unexpected,
        };
        for (cqes[0..n]) |cqe| u.complete(cqe, sink);
        if (n < cqes.len) break;
    }
}

/// Submits what is queued and, as `wait` allows, waits for a completion.
fn enter(u: *Uring, wait: Wait) error{ SystemResources, Unexpected }!void {
    var ts: linux.kernel_timespec = undefined;
    var arg: linux.io_uring_getevents_arg = .{ .sigmask = 0, .sigmask_sz = 0, .pad = 0, .ts = 0 };
    const min: u32 = switch (wait) {
        .nowait => 0,
        .forever => 1,
        .up_to => |span| blk: {
            const cut = timeline.parts(span);
            ts = .{ .sec = @intCast(cut.sec), .nsec = cut.nsec }; // safe: seconds of a u64 of nanoseconds fit i64
            arg.ts = @intFromPtr(&ts); // safe: the kernel reads the timespec during this call
            break :blk 1;
        },
    };
    const queued = u.ring.flush_sq();
    var sq_flags: u32 = 0;
    const needs_enter = u.ring.sq_ring_needs_enter(&sq_flags) and (queued > 0 or sq_flags != 0);
    const to_submit = if (u.ring.flags & linux.IORING_SETUP_SQPOLL == 0) queued else 0;
    // Nothing to submit and nothing to wait for: no syscall, unless the
    // kernel holds completions back until asked (deferred task work, or an
    // overflow), which it flags when it can.
    if (!needs_enter and min == 0 and !u.pendingInKernel()) return;
    const flags = linux.IORING_ENTER_GETEVENTS | linux.IORING_ENTER_EXT_ARG | sq_flags;
    while (true) {
        // The extended argument's size goes where a signal mask's would:
        // std's wrapper passes the mask's.
        const rc = linux.syscall6(.io_uring_enter, @as(u32, @bitCast(u.ring.fd)), to_submit, min, flags, @intFromPtr(&arg), @sizeOf(linux.io_uring_getevents_arg)); // safe: the kernel reads the wait argument during the call
        switch (linux.errno(rc)) {
            .SUCCESS, .TIME, .INTR => return,
            // The completion queue is full: take completions, then submit.
            .BUSY => return,
            .AGAIN, .NOMEM => return error.SystemResources,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn pendingInKernel(u: *Uring) bool {
    const flags = @atomicLoad(u32, u.ring.sq.flags, .acquire);
    if (flags & linux.IORING_SQ_CQ_OVERFLOW != 0) return true;
    if (u.taskrun_flag) return flags & linux.IORING_SQ_TASKRUN != 0;
    // Without the flag, a deferring ring must be asked every time.
    return u.features.defer_taskrun;
}

pub fn complete(u: *Uring, cqe: linux.io_uring_cqe, sink: anytype) void {
    const ud = cqe.user_data;
    const tag = tagOf(ud);
    if (u.draining_pressure and (tag == .batch or tag == .batch_ready)) {
        std.debug.assert(u.deferred_count < u.deferred.len);
        u.deferred[(u.deferred_head + u.deferred_count) % u.deferred.len] = cqe;
        u.deferred_count += 1;
        return;
    }
    switch (tag) {
        .op => {
            const Op = @typeInfo(@typeInfo(@TypeOf(@TypeOf(sink.*).complete)).@"fn".param_types[1].?).pointer.child;
            const o: *Op = @ptrFromInt(ud); // safe: submit retains this op through every completion
            o.state.uring.completed(cqe);
            u.settle(o, sink);
        },
        .auxiliary => {
            const address = ud & ~@as(u64, 7);
            if (address == 0) {
                u.message_pending.store(false, .release);
                return sink.notified();
            }
            const Op = @typeInfo(@typeInfo(@TypeOf(@TypeOf(sink.*).complete)).@"fn".param_types[1].?).pointer.child;
            const o: *Op = @ptrFromInt(address); // safe: the linked timer shares the op's retained lifetime
            o.state.uring.timeout_pending = false;
            if (cqe.err() == .TIME) o.state.uring.timed_out = true;
            u.settle(o, sink);
        },
        .batch => {
            u.active -= 1;
            const token: pending.Token = @fromBackingInt(@intCast(ud & ~@as(u64, 7)));
            sink.completePending(token, results.ofPending(token.pending().tag, cqe));
        },
        .batch_ready => {
            u.active -= 1;
            const token: pending.Token = @fromBackingInt(@intCast(ud & ~@as(u64, 7)));
            if (cqe.err() == .CANCELED) return sink.completePending(token, .canceled);
            const operation = pending.unpack(token.pending());
            if (results.attempt(operation)) |result| return sink.completePending(token, .{ .result = result });
            // Readiness that the call found gone: wait again.
            u.submitPending(token, operation) catch sink.completePending(token, .{ .result = results.failure(operation) });
        },
        .wake => {
            _ = linux.read(u.wake_fd, @ptrCast(&u.wake_buffer), 8); // safe: eight bytes, as an eventfd reads
            u.wake_pending.store(false, .release);
            if (cqe.flags & linux.IORING_CQE_F_MORE == 0) u.wake_armed = false;
        },
        .receiver => {
            if (cqe.flags & linux.IORING_CQE_F_MORE == 0) u.active -= 1;
            const r: *Receive = @ptrFromInt(ud & ~@as(u64, 7)); // safe: the receiver owns this record through the terminal completion
            r.deliver(cqe);
            // A receiver wakes tasks without completing a Loop.Op.
            sink.notified();
        },
        .listener => {
            const r: *Accept.Slot = @ptrFromInt(ud & ~@as(u64, 7)); // safe: the table owns this record through the terminal completion
            u.accepts.complete(u, r, cqe, sink);
        },
        .ignore => if (cqe.res < 0 and ud & ~@as(u64, 7) != 0) {
            const target: *Uring = @ptrFromInt(ud & ~@as(u64, 7)); // safe: runtimes retain every ring until workers stop
            target.message_pending.store(false, .release);
            target.wake();
        },
    }
}

fn settle(u: *Uring, o: anytype, sink: anytype) void {
    const ownership = &o.state.uring;
    if (!ownership.ready()) return;
    const primary = ownership.primary;
    if (ownership.fixed_buffer) |index| {
        u.buffers.release(index);
        ownership.fixed_buffer = null;
    }
    if (!o.state.canceled and !ownership.timed_out and (primary.err() == .OPNOTSUPP or primary.err() == .INVAL) and ownership.zero_copy and !ownership.use_copy) {
        if (o.kind == .io and o.kind.io == .net_write) {
            o.state.uring = .{ .use_copy = true };
            u.active -= 1;
            u.submit(o) catch unreachable; // unreachable: native submission queues or flushes an SQE
            return;
        }
    }
    u.active -= 1;
    if (ownership.timed_out and primary.err() == .CANCELED) o.state.canceled = true;
    o.result = results.of(o, primary);
    u.finishOp(o, primary);
    sink.complete(o);
}

/// What a completion leaves to do: the rest of a multi-message send.
fn finishOp(u: *Uring, o: anytype, cqe: linux.io_uring_cqe) void {
    _ = u;
    _ = cqe;
    switch (o.kind) {
        .io => |operation| switch (operation) {
            .net_send => |s| if (o.result.io) |r| if (r.net_send[0] == null and s.messages.len > 1) {
                o.result = .{ .io = .{ .net_send = results.sendRest(s, 1) } };
            } else {} else |_| {},
            else => {},
        },
        else => {},
    }
}

fn armWake(u: *Uring) void {
    const sqe = u.entry();
    sqe.prep_poll_add(u.wake_fd, linux.POLL.IN);
    sqe.len = linux.IORING_POLL_ADD_MULTI;
    sqe.user_data = userData(0, .wake);
    u.wake_armed = true;
}

/// From any thread: ends a waiting `poll`.
pub fn wake(u: *Uring) void {
    if (u.wake_pending.swap(true, .acq_rel)) return;
    const one: u64 = 1;
    _ = linux.write(u.wake_fd, @ptrCast(&one), 8); // safe: eight bytes, as an eventfd is written
}

/// An eventfd the kernel signals on every completion, for a host's poller.
pub fn handle(u: *Uring) error{ SystemResources, Unexpected }!?linux.fd_t {
    if (u.notify_fd) |fd| return fd;
    const efd = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(efd) != .SUCCESS) return error.SystemResources;
    const fd: linux.fd_t = @intCast(efd);
    u.ring.register_eventfd(fd) catch {
        _ = linux.close(fd);
        return error.Unexpected;
    };
    u.notify_fd = fd;
    return fd;
}

// Buffers.

fn firstBuffer(data: []const []u8) []u8 {
    for (data) |d| if (d.len > 0) return d[0..@min(d.len, max_rw)];
    return &.{};
}

/// The first bytes a streaming write would send: a write may be short.
fn firstChunk(header: []const u8, data: []const []const u8, splat: usize) []const u8 {
    if (header.len > 0) return header[0..@min(header.len, max_rw)];
    for (data[0 .. data.len - 1]) |d| if (d.len > 0) return d[0..@min(d.len, max_rw)];
    const last = data[data.len - 1];
    if (splat > 0 and last.len > 0) return last[0..@min(last.len, max_rw)];
    return &.{};
}

/// The non-empty buffers of a read, at most the iovec array's length.
fn gather(iovecs: []posix.iovec, data: []const []u8) usize {
    var n: usize = 0;
    for (data) |d| {
        if (n == iovecs.len) break;
        if (d.len == 0) continue;
        iovecs[n] = .{ .base = d.ptr, .len = d.len };
        n += 1;
    }
    return n;
}

/// A write's buffers as `Threaded` lays them out: the header, the data,
/// and the splat (a one-byte pattern expanded through `splat_buffer`).
fn scatter(iovecs: []posix.iovec, splat_buffer: *[Threaded.splat_buffer_size]u8, header: []const u8, data: []const []const u8, splat: usize) usize {
    var n: usize = 0;
    const add = struct {
        fn f(v: []posix.iovec, count: *usize, bytes: []const u8) void {
            if (bytes.len == 0 or count.* == v.len) return;
            v[count.*] = .{ .base = @constCast(bytes.ptr), .len = bytes.len }; // safe: the kernel only reads what a send gives it
            count.* += 1;
        }
    }.f;
    add(iovecs, &n, header);
    for (data[0 .. data.len - 1]) |d| add(iovecs, &n, d);
    const pattern = data[data.len - 1];
    switch (splat) {
        0 => {},
        1 => add(iovecs, &n, pattern),
        else => if (pattern.len == 1) {
            const len = @min(splat, splat_buffer.len);
            @memset(splat_buffer[0..len], pattern[0]);
            var remaining = splat;
            while (remaining > 0 and n < iovecs.len) {
                const chunk = @min(remaining, len);
                add(iovecs, &n, splat_buffer[0..chunk]);
                remaining -= chunk;
            }
        } else for (0..@min(splat, iovecs.len)) |_| add(iovecs, &n, pattern),
    }
    return n;
}

fn receiveFlags(flags: net.ReceiveFlags) u32 {
    return @as(u32, if (flags.oob) posix.MSG.OOB else 0) |
        @as(u32, if (flags.peek) posix.MSG.PEEK else 0) |
        @as(u32, if (flags.trunc) posix.MSG.TRUNC else 0);
}

fn unixToPosix(a: *const net.UnixAddress, storage: *posix.sockaddr.un) posix.socklen_t {
    storage.* = .{ .family = posix.AF.UNIX, .path = @splat(0) };
    const n = @min(a.path.len, storage.path.len - 1);
    @memcpy(storage.path[0..n], a.path[0..n]);
    return @intCast(@offsetOf(posix.sockaddr.un, "path") + n + 1);
}

fn timespecOf(ns: i96) linux.kernel_timespec {
    const clamped: i96 = @max(ns, 0);
    return .{ .sec = @intCast(@divFloor(clamped, std.time.ns_per_s)), .nsec = @intCast(@mod(clamped, std.time.ns_per_s)) };
}

/// Only the source owner calls this. Failed messages fall back when their
/// CQE is reaped; neither ring's mutable queues are touched cross-thread.
/// The message is submitted at once: a source that does not return to its
/// loop (a task spawning in a loop, or computing) would otherwise leave the
/// sleeping target asleep with work waiting for it.
pub fn messageWake(source: *Uring, target: *Uring) bool {
    if (!source.features.msg_ring) return false;
    if (target.message_pending.swap(true, .acq_rel)) return true;
    const sqe = source.entry();
    sqe.* = std.mem.zeroInit(linux.io_uring_sqe, .{ .opcode = .MSG_RING, .fd = target.ring.fd, .addr = 0, .off = userData(0, .auxiliary), .len = 0, .user_data = userData(@intFromPtr(target), .ignore) }); // safe: target outlives source polling and worker shutdown
    // A refused submission stays queued for the source's next poll.
    source.enter(.nowait) catch return true;
    return true;
}
