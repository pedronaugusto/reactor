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
const assert = std.debug.assert;
const Io = std.Io;
const net = Io.net;
const linux = std.os.linux;
const posix = std.posix;
const Threaded = Io.Threaded;

const op = @import("op.zig");
const pending = @import("pending.zig");
const Wait = @import("wait.zig").Wait;
const Receive = @import("uring/Receive.zig");
const Accept = @import("uring/Accept.zig");
const Files = @import("uring/Files.zig");
const Allocator = std.mem.Allocator;
const results = @import("uring/results.zig");

pub const Features = packed struct(u6) {
    accept_ahead: bool = false,
    fixed_files: bool = false,
    defer_taskrun: bool = false,
    msg_ring: bool = false,
    waitid: bool = false,
    linked_timeout: bool = false,
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
};

fn userData(address: u64, tag: Tag) u64 {
    assert(address & 7 == 0);
    return address | @backingInt(tag);
}

fn tagOf(user_data: u64) Tag {
    return @fromBackingInt(@intCast(@as(u3, @truncate(user_data))));
}

ring: linux.IoUring,
next_group: std.atomic.Value(u32) = .init(1),
accepts: Accept,
/// Requests that a descriptor-wide cancellation could end, excluding
/// listener slots (which close cancels individually) and the wake poll.
active: usize = 0,
files: Files,
/// Opcodes the kernel has.
supported: std.EnumSet(linux.IORING_OP),
features: Features,
wake_fd: linux.fd_t,
wake_armed: bool = false,
wake_buffer: u64 = 0,
/// Set by `wake` until the ring has read the eventfd: later wakes skip
/// the write.
wake_pending: std.atomic.Value(bool) = .init(false),
notify_fd: ?linux.fd_t = null,
enabled: bool,
/// The kernel flags the ring when completions wait to be run.
taskrun_flag: bool = false,

pub fn init(gpa: Allocator, options: Options) (InitError || Allocator.Error)!Uring {
    var u: Uring = .{
        .ring = undefined,
        .accepts = undefined,
        .files = undefined,
        .supported = .empty,
        .features = .{},
        .wake_fd = undefined,
        .enabled = !options.disabled,
    };
    u.ring = try setup(options, &u.features, &u.taskrun_flag);
    errdefer u.ring.deinit();
    u.probe();
    u.accepts = try Accept.init(gpa, options.entries, !options.off.accept_ahead and u.has(.ACCEPT));
    errdefer u.accepts.deinit(gpa);
    u.files = try Files.init(gpa, &u.ring, options.entries, !options.off.fixed_files);
    errdefer u.files.deinit(gpa);
    u.features.accept_ahead = u.accepts.enabled;
    u.features.fixed_files = u.files.enabled;
    const efd = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(efd) != .SUCCESS) return error.SystemResources;
    u.wake_fd = @intCast(efd);
    return u;
}

/// The ring, with every flag the kernel takes, dropping them one by one.
fn setup(options: Options, features: *Features, taskrun_flag: *bool) InitError!linux.IoUring {
    const want_defer = !options.off.defer_taskrun;
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
            .flags = t.flags | linux.IORING_SETUP_CQSIZE | @as(u32, if (options.disabled) linux.IORING_SETUP_R_DISABLED else 0),
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
        features.defer_taskrun = t.defer_taskrun;
        taskrun_flag.* = t.taskrun_flag;
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
    u.files.deinit(gpa);
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
                error.SignalInterrupt, error.SystemResources => std.atomic.spinLoopHint(),
                else => std.debug.panic("reactor: the ring refused its submissions: {t}", .{err}),
            };
            continue;
        };
    }
}

pub fn submit(u: *Uring, o: anytype) error{ SystemResources, Unexpected }!void {
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
        },
        .write_at => |w| {
            const sqe = u.entry();
            sqe.prep_write(w.file, w.bytes[0..@min(w.bytes.len, max_rw)], w.offset);
            sqe.user_data = ud;
            u.files.use(&u.ring, sqe);
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
                .object => unreachable, // unreachable: Windows objects do not exist on Linux
            }
            sqe.user_data = ud;
        },
    }
    u.active += 1;
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
                sqe.prep_send(w.socket_handle, @as([*]const u8, m.iovecs[0].base)[0..m.iovecs[0].len], posix.MSG.NOSIGNAL);
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
    sqe.user_data = ud;
    switch (operation.*) {
        .file_read_streaming, .file_write_streaming => u.files.use(&u.ring, sqe),
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
    const delivered = u.accepts.deliver(sink);
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
        .ns => |ns| blk: {
            ts = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
            arg.ts = @intFromPtr(&ts); // safe: the kernel reads the timespec during this call
            break :blk 1;
        },
    };
    const to_submit = u.ring.flush_sq();
    // Nothing to submit and nothing to wait for: no syscall, unless the
    // kernel holds completions back until asked (deferred task work, or an
    // overflow), which it flags when it can.
    if (to_submit == 0 and min == 0 and !u.pendingInKernel()) return;
    const flags = linux.IORING_ENTER_GETEVENTS | linux.IORING_ENTER_EXT_ARG;
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

fn complete(u: *Uring, cqe: linux.io_uring_cqe, sink: anytype) void {
    const ud = cqe.user_data;
    switch (tagOf(ud)) {
        .op => {
            u.active -= 1;
            const Op = @typeInfo(@typeInfo(@TypeOf(@TypeOf(sink.*).complete)).@"fn".param_types[1].?).pointer.child;
            const o: *Op = @ptrFromInt(ud);
            o.result = results.of(o, cqe);
            u.finishOp(o, cqe);
            sink.complete(o);
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
        .ignore => {},
    }
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
