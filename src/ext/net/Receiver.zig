//! Receives into buffers from a pool shared by every `Receiver` made with
//! it, so a connection that is idle holds no buffer: a receiver waits for
//! its socket to be readable, then takes a buffer and reads what is there.
//! A buffer is lent to the caller until `release` or the next `next`.
const Receiver = @This();

const builtin = @import("builtin");
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const receive = @import("../../sys/receive.zig");
const Scheduler = @import("../../Scheduler.zig");
const Receive = @import("../../backend/uring/Receive.zig");
const Registrations = @import("receiver/Registrations.zig");
const Groups = @import("receiver/Groups.zig");
const native = @import("../native.zig");
const wait = @import("../wait.zig");
const timed = @import("../../ops/timeout.zig");

pool: *Pool,
socket: Io.net.Socket.Handle,
/// The buffer the last `next` lent; not to be touched.
lent: ?u32 = null,
native_state: if (builtin.os.tag == .linux) ?Native else void = if (builtin.os.tag == .linux) null else {},

/// Buffers of one length, all allocated at `init`, taken and given back
/// from any thread without a lock.
pub const Pool = struct {
    memory: []u8,
    buffer_len: u32,
    links: []u32,
    lengths: []u32,
    groups: if (builtin.os.tag == .linux) ?Groups else void = if (builtin.os.tag == .linux) null else {},
    fixed: if (builtin.os.tag == .linux) ?Registrations else void = if (builtin.os.tag == .linux) null else {},
    /// The free list's head: an index plus one, and a tag against ABA.
    head: std.atomic.Value(u64) = .init(0),
    receivers: std.atomic.Value(u32) = .init(0),

    pub const Options = struct {
        buffer_len: aegis.units.Bytes(u32) = .fromRaw(4096),
        buffers: u32 = 4096,
        /// Pin the pool on every ring for positional READ_FIXED/WRITE_FIXED.
        /// Unsupported is reported; every operation using the pool must end before deinit.
        registered: bool = false,
    };
    pub const InitError = Groups.Error || Registrations.Error;

    pub fn init(gpa: Allocator, io: Io, options: Options) InitError!Pool {
        std.debug.assert(!options.buffer_len.eql(.fromRaw(0)));
        std.debug.assert(options.buffers > 0);
        // Sizes come from the caller: a pool too large to count is too large to allocate.
        const length = options.buffer_len.convert(usize);
        const size = length.mul(options.buffers) catch return error.OutOfMemory;
        const memory = try gpa.alloc(u8, size.raw());
        errdefer gpa.free(memory);
        const links = try gpa.alloc(u32, options.buffers);
        errdefer gpa.free(links);
        const lengths = try gpa.alloc(u32, options.buffers);
        errdefer gpa.free(lengths);
        var p: Pool = .{ .memory = memory, .buffer_len = options.buffer_len.raw(), .links = links, .lengths = lengths };
        if (options.registered) {
            if (builtin.os.tag != .linux) return error.Unsupported;
            p.fixed = try Registrations.init(gpa, io, memory);
        }
        errdefer if (builtin.os.tag == .linux) if (p.fixed) |*fixed| fixed.deinit(gpa, io);
        if (builtin.os.tag == .linux) p.groups = try Groups.init(gpa, io, memory, options.buffer_len, options.buffers);
        var i = options.buffers;
        while (i > 0) {
            i -= 1;
            p.give(i);
        }
        return p;
    }

    /// Every buffer given back; before the owning runtime stops.
    pub fn deinit(p: *Pool, gpa: Allocator, io: Io) void {
        std.debug.assert(p.receivers.load(.acquire) == 0);
        if (builtin.os.tag == .linux) {
            if (p.groups) |*groups| groups.deinit(gpa, io);
            if (p.fixed) |*fixed| fixed.deinit(gpa, io);
        }
        gpa.free(p.lengths);
        gpa.free(p.memory);
        gpa.free(p.links);
        p.* = undefined;
    }

    fn buffer(p: *Pool, index: u32) []u8 {
        const start = @as(usize, index) * p.buffer_len;
        return p.memory[start..][0..p.buffer_len];
    }

    const Free = packed struct(u64) { index_plus_one: u32, tag: u32 };

    fn take(p: *Pool) ?u32 {
        if (builtin.os.tag == .linux) if (p.groups != null) return null;
        var raw = p.head.load(.acquire);
        while (true) {
            const f: Free = @bitCast(raw);
            if (f.index_plus_one == 0) return null;
            const index = f.index_plus_one - 1;
            const next_free: Free = .{ .index_plus_one = @atomicLoad(u32, &p.links[index], .monotonic), .tag = f.tag +% 1 };
            raw = p.head.cmpxchgWeak(raw, @bitCast(next_free), .acq_rel, .acquire) orelse return index;
        }
    }

    fn give(p: *Pool, index: u32) void {
        var raw = p.head.load(.monotonic);
        while (true) {
            const f: Free = @bitCast(raw);
            @atomicStore(u32, &p.links[index], f.index_plus_one, .monotonic);
            const first: Free = .{ .index_plus_one = index + 1, .tag = f.tag +% 1 };
            raw = p.head.cmpxchgWeak(raw, @bitCast(first), .release, .monotonic) orelse return;
        }
    }
};

pub fn init(io: Io, pool: *Pool, socket: Io.net.Socket.Handle) Receiver {
    _ = io;
    _ = pool.receivers.fetchAdd(1, .monotonic);
    return .{ .pool = pool, .socket = socket };
}

/// Gives back a buffer still lent.
pub fn deinit(r: *Receiver, io: Io) void {
    r.giveBack();
    if (builtin.os.tag == .linux) if (r.native_state) |*state| state.close(io);
    _ = r.pool.receivers.fetchSub(1, .release);
    r.* = undefined;
}

pub const NextError = Io.Operation.NetRead.Error || error{ Timeout, EndOfStream } || Io.Cancelable;

/// The next bytes the socket has, in a buffer from the pool, waiting
/// until `timeout` for them. `SystemResources` when every buffer is lent.
/// The bytes are borrowed until `release` or the next `next`.
pub fn next(r: *Receiver, io: Io, timeout: Io.Timeout) NextError![]const u8 {
    r.giveBack();
    if (builtin.os.tag == .linux) if (r.pool.groups) |*groups| {
        const core = native.runtimeOf(io) orelse return error.Unexpected;
        if (!native.taskRuntime(core)) return error.Unexpected;
        if (r.native_state == null) {
            const p = Scheduler.processor().?;
            r.native_state = .{ .receiver = r, .owner = p, .group = &groups.items[p.index], .io = io };
            const state = &r.native_state.?;
            var held = state.mailbox.acquireUncancelable(Native.system());
            held.value().request = .{ .socket = r.socket, .group = state.group.id, .context = state, .complete = Native.completed };
            held.deinit(Native.system());
        }
        return r.native_state.?.next(io, timeout.toDeadline(io));
    };
    const deadline = timeout.toDeadline(io);
    while (true) {
        wait.wait(io, .{ .readable = r.socket }, deadline) catch |err| return switch (err) {
            error.Timeout => error.Timeout,
            error.Canceled => error.Canceled,
            error.Unsupported, error.Unexpected => error.Unexpected,
        };
        const index = r.pool.take() orelse return error.SystemResources;
        const n = read(io, r.socket, r.pool.buffer(index), deadline) catch |err| {
            r.pool.give(index);
            return err;
        } orelse {
            // Readable, but someone else read it first: wait again.
            r.pool.give(index);
            continue;
        };
        if (n == 0) {
            r.pool.give(index);
            return error.EndOfStream;
        }
        r.lent = index;
        return r.pool.buffer(index)[0..n];
    }
}

/// Gives back the buffer `bytes` came in.
pub fn release(r: *Receiver, bytes: []const u8) void {
    const index = r.lent orelse return;
    const start = @intFromPtr(r.pool.buffer(index).ptr); // safe: an address compared, never dereferenced
    std.debug.assert(@intFromPtr(bytes.ptr) >= start); // safe: an address compared, never dereferenced
    std.debug.assert(@intFromPtr(bytes.ptr) < start + r.pool.buffer_len); // safe: an address compared, never dereferenced
    r.giveBack();
}

fn giveBack(r: *Receiver) void {
    const index = r.lent orelse return;
    r.lent = null;
    if (builtin.os.tag == .linux) if (r.native_state) |*state| {
        state.group.give(r.pool.memory, r.pool.buffer_len, index - state.group.first);
        return;
    };
    r.pool.give(index);
}

/// What the socket has now; null when nothing.
fn read(io: Io, socket: Io.net.Socket.Handle, buffer: []u8, deadline: Io.Timeout) NextError!?usize {
    if (builtin.os.tag != .windows) return receive.now(socket, buffer);
    var data: [1][]u8 = .{buffer};
    const result = timed.operate(io, .{ .net_read = .{ .socket_handle = socket, .data = &data } }, deadline) catch |err| return switch (err) {
        error.ConcurrencyUnavailable => error.SystemResources,
        else => |e| e,
    };
    const r = try result.net_read;
    return r.data_len;
}

/// What the receiver's lock guards: the kernel request, what it has
/// delivered and not yet been taken, and the command that serves it.
const Mailbox = struct {
    request: Receive = undefined,
    command_queued: bool = false,
    closed: bool = false,
    eof: bool = false,
    failure: ?NextError = null,
    head: ?u32 = null,
    tail: ?u32 = null,
};

/// Native requests stay pinned here until their terminal completion.
const Native = struct {
    receiver: *Receiver,
    owner: *Scheduler.Processor,
    group: *Groups.Group,
    io: Io,
    mailbox: aegis.BlockingGuarded(Mailbox) = .init(.{}),
    ready: Io.Event = .unset,
    ended: Io.Event = .unset,
    command: Scheduler.Errand = .{ .run = commandRun },

    fn system() Io {
        return Io.Threaded.global_single_threaded.io();
    }

    fn send(state: *Native, close_request: bool) void {
        var held = state.mailbox.acquireUncancelable(system());
        const mailbox = held.value();
        if (close_request) mailbox.closed = true;
        if (mailbox.command_queued) {
            held.deinit(system());
            return;
        }
        mailbox.command_queued = true;
        held.deinit(system());
        if (Scheduler.processor() == state.owner) commandRun(&state.command, state.owner) else state.owner.send(&state.command);
    }

    fn commandRun(command: *Scheduler.Errand, _: *Scheduler.Processor) void {
        const state: *Native = @alignCast(@fieldParentPtr("command", command)); // safe: this command belongs to the receiver's native state
        var held = state.mailbox.acquireUncancelable(system());
        const mailbox = held.value();
        mailbox.command_queued = false;
        const closing = mailbox.closed;
        if (closing) {
            mailbox.request.cancel(state.group.ring);
        } else if (!mailbox.request.active and !mailbox.eof) {
            mailbox.failure = null;
            state.ended.reset();
            state.owner.hold(state.receiver.socket);
            mailbox.request.arm(state.group.ring);
        }
        const ended = closing and !mailbox.request.active;
        held.deinit(system());
        if (ended) state.ended.set(state.io);
    }

    fn completed(context: *anyopaque, cqe: std.os.linux.io_uring_cqe) void {
        const state: *Native = @ptrCast(@alignCast(context)); // safe: the receive request retained this native state
        const pool = state.receiver.pool;
        var held = state.mailbox.acquireUncancelable(system());
        const mailbox = held.value();
        const final = cqe.flags & std.os.linux.IORING_CQE_F_MORE == 0;
        if (final) state.owner.release(state.receiver.socket);
        if (cqe.flags & std.os.linux.IORING_CQE_F_BUFFER != 0) {
            const local: u32 = @as(u16, @truncate(cqe.flags >> 16));
            std.debug.assert(local < state.group.count);
            const index = state.group.first + local;
            if (cqe.res <= 0 or mailbox.closed) {
                state.group.give(pool.memory, pool.buffer_len, local);
            } else {
                pool.lengths[index] = @intCast(cqe.res);
                pool.links[index] = std.math.maxInt(u32);
                if (mailbox.tail) |tail| pool.links[tail] = index else mailbox.head = index;
                mailbox.tail = index;
            }
        }
        if (cqe.res == 0) mailbox.eof = true;
        if (cqe.res < 0 and !mailbox.closed) mailbox.failure = switch (cqe.err()) {
            .NOBUFS, .NOMEM => error.SystemResources,
            .CANCELED, .BADF, .NOTCONN => error.SocketUnconnected,
            .CONNRESET => error.ConnectionResetByPeer,
            else => error.Unexpected,
        };
        state.ready.set(state.io);
        const ended = final and mailbox.closed and !mailbox.command_queued;
        held.deinit(system());
        if (ended) state.ended.set(state.io);
    }

    fn take(state: *Native) NextError!?[]const u8 {
        var held = state.mailbox.acquireUncancelable(system());
        defer held.deinit(system());
        const mailbox = held.value();
        if (mailbox.head) |index| {
            const pool = state.receiver.pool;
            const following = pool.links[index];
            mailbox.head = if (following == std.math.maxInt(u32)) null else following;
            if (mailbox.head == null) {
                mailbox.tail = null;
                state.ready.reset();
            }
            state.receiver.lent = index;
            return pool.buffer(index)[0..pool.lengths[index]];
        }
        if (mailbox.eof) return error.EndOfStream;
        if (mailbox.failure) |failure| {
            mailbox.failure = null;
            state.ready.reset();
            return failure;
        }
        state.ready.reset();
        return null;
    }

    fn next(state: *Native, io: Io, deadline: Io.Timeout) NextError![]const u8 {
        if (try state.take()) |bytes| return bytes;
        state.send(false);
        while (true) {
            state.ready.waitTimeout(io, deadline) catch |err| {
                if (try state.take()) |bytes| return bytes;
                if (err == error.Canceled) return error.Canceled;
                if (deadline.toDurationFromNow(io)) |remaining| if (remaining.raw.nanoseconds <= 0) return error.Timeout;
                continue;
            };
            if (try state.take()) |bytes| return bytes;
        }
    }

    fn close(state: *Native, io: Io) void {
        state.send(true);
        state.ended.waitUncancelable(io);
        var held = state.mailbox.acquireUncancelable(system());
        defer held.deinit(system());
        const mailbox = held.value();
        const pool = state.receiver.pool;
        while (mailbox.head) |index| {
            const following = pool.links[index];
            mailbox.head = if (following == std.math.maxInt(u32)) null else following;
            state.group.give(pool.memory, pool.buffer_len, index - state.group.first);
        }
    }
};
