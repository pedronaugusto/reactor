//! A listener owns at most eight accepts, pending or completed.
//! Ordinary accepts leave excess connections in the kernel backlog;
//! multishot accept cannot bound the sockets produced before cancellation.
//! Request storage outlives every waiting task and the terminal completion.
const Accept = @This();
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const bound = 8;
pub const Slot = struct {
    record: *Record = undefined,
    active: bool = false,
    address: Io.Threaded.PosixAddress = undefined,
    address_len: posix.socklen_t = @sizeOf(Io.Threaded.PosixAddress),
};

pub const Record = struct {
    slots: [bound]Slot = @splat(.{}),
    pending: usize = 0,
    ahead: usize = 1,
    fd: linux.fd_t = -1,
    sockets: [bound]Io.net.Socket = undefined,
    count: usize = 0,
    first: usize = 0,
    armed: bool = false,
    ending: bool = false,
    closing: bool = false,
    head: ?*anyopaque = null,
    tail: ?*anyopaque = null,
};

records: []Record,
descriptors: []std.atomic.Value(linux.fd_t),
ready_head: ?*anyopaque = null,
ready_tail: ?*anyopaque = null,
enabled: bool,

pub fn init(gpa: Allocator, count: usize, enabled: bool) Allocator.Error!Accept {
    const records = try gpa.alloc(Record, count);
    errdefer gpa.free(records);
    @memset(records, .{});
    const descriptors = try gpa.alloc(std.atomic.Value(linux.fd_t), count);
    for (descriptors) |*fd| fd.* = .init(-1);
    return .{ .records = records, .descriptors = descriptors, .enabled = enabled };
}

pub fn deinit(a: *Accept, gpa: Allocator) void {
    for (a.records) |*r| a.discard(r);
    gpa.free(a.records);
    gpa.free(a.descriptors);
    a.* = undefined;
}

/// Close routing may ask from another processor.
pub fn contains(a: *const Accept, fd: linux.fd_t) bool {
    const first = @as(u32, @bitCast(fd)) % a.records.len;
    for (0..@min(8, a.records.len)) |offset| {
        const found = a.descriptors[(first + offset) % a.records.len].load(.acquire);
        if (found == -1) return false;
        if (found == fd) return true;
    }
    return false;
}

/// Reserves ownership without touching the ring owner's record. The runtime
/// serializes first claims across rings; the record is initialized at submit.
pub fn reserve(a: *Accept, fd: linux.fd_t) bool {
    if (!a.enabled) return false;
    const first = @as(u32, @bitCast(fd)) % a.records.len;
    for (0..@min(8, a.records.len)) |offset| {
        const descriptor = &a.descriptors[(first + offset) % a.records.len];
        const found = descriptor.load(.acquire);
        if (found == fd) return true;
        if (found >= 0) continue;
        if (descriptor.cmpxchgStrong(found, fd, .acq_rel, .acquire) == null) return true;
    }
    return false;
}

fn index(a: *Accept, r: *Record) usize {
    return (@intFromPtr(r) - @intFromPtr(a.records.ptr)) / @sizeOf(Record); // safe: r is an entry in this table
}

pub fn reset(a: *Accept, r: *Record) void {
    a.descriptors[a.index(r)].store(-2, .release); // tombstone: a later colliding listener remains reachable
    r.* = .{};
}

fn discard(_: *Accept, r: *Record) void {
    while (r.count > 0) {
        _ = linux.close(r.sockets[r.first].handle);
        r.first = (r.first + 1) % bound;
        r.count -= 1;
        if (r.count == 0) r.ahead = 1;
    }
}

fn find(a: *Accept, fd: linux.fd_t) ?*Record {
    const first = @as(u32, @bitCast(fd)) % a.records.len;
    for (0..@min(8, a.records.len)) |offset| {
        const i = (first + offset) % a.records.len;
        const found = a.descriptors[i].load(.monotonic);
        if (found == -1) return null;
        if (found != fd) continue;
        const r = &a.records[i];
        if (r.fd == fd and !r.closing) return r;
    }
    return null;
}

pub fn submit(a: *Accept, u: anytype, o: anytype) bool {
    const fd = o.kind.accept;
    if (!a.enabled and a.find(fd) == null) return false;
    const r = a.find(fd) orelse free: {
        const first = @as(u32, @bitCast(fd)) % a.records.len;
        for (0..@min(8, a.records.len)) |offset| {
            const r = &a.records[(first + offset) % a.records.len];
            if (r.fd != -1) continue;
            const reserved = a.descriptors[a.index(r)].load(.acquire);
            if (reserved >= 0 and reserved != fd) continue;
            r.* = .{ .fd = fd };
            a.descriptors[a.index(r)].store(fd, .release);
            break :free r;
        }
        return false;
    };
    if (!a.enabled and !r.armed and r.count == 0) {
        a.reset(r);
        return false;
    }
    if (r.count > 0) {
        const socket = r.sockets[r.first];
        r.first = (r.first + 1) % bound;
        r.count -= 1;
        o.result = .{ .accept = socket };
        a.ready(o);
    } else {
        o.state.next = null;
        if (r.tail) |raw| {
            const tail: @TypeOf(o) = @ptrCast(@alignCast(raw)); // safe: this listener links operations of one type
            tail.state.next = o;
        } else r.head = o;
        r.tail = o;
    }
    if (a.enabled and !r.ending) a.arm(u, r);
    return true;
}

fn arm(_: *Accept, u: anytype, r: *Record) void {
    std.debug.assert(!r.closing);
    for (&r.slots) |*slot| {
        if (r.count + r.pending >= r.ahead) break;
        if (slot.active) continue;
        slot.* = .{ .record = r, .active = true };
        const sqe = u.entry();
        sqe.prep_accept(r.fd, &slot.address.any, &slot.address_len, linux.SOCK.CLOEXEC);
        sqe.user_data = @intFromPtr(slot) | 5; // safe: decoded as this persistent accept slot
        r.pending += 1;
    }
    r.armed = r.pending != 0;
}

fn ready(a: *Accept, o: anytype) void {
    o.state.next = null;
    if (a.ready_tail) |raw| {
        const tail: @TypeOf(o) = @ptrCast(@alignCast(raw)); // safe: this list contains operations of one type
        tail.state.next = o;
    } else a.ready_head = o;
    a.ready_tail = o;
}

fn pop(comptime Op: type, r: *Record) ?*Op {
    const o: *Op = @ptrCast(@alignCast(r.head orelse return null)); // safe: submit linked an Op here
    r.head = o.state.next;
    if (r.head == null) r.tail = null;
    o.state.next = null;
    return o;
}

pub fn deliver(a: *Accept, sink: anytype) bool {
    const Op = @typeInfo(@typeInfo(@TypeOf(@TypeOf(sink.*).complete)).@"fn".param_types[1].?).pointer.child;
    const any = a.ready_head != null;
    while (a.ready_head) |raw| {
        const o: *Op = @ptrCast(@alignCast(raw)); // safe: ready linked an Op here
        a.ready_head = o.state.next;
        if (a.ready_head == null) a.ready_tail = null;
        o.state.next = null;
        sink.complete(o);
    }
    return any;
}

pub fn cancel(a: *Accept, o: anytype) bool {
    const r = a.find(o.kind.accept) orelse return false;
    var previous: ?@TypeOf(o) = null;
    var raw = r.head;
    while (raw) |address| {
        const current: @TypeOf(o) = @ptrCast(@alignCast(address)); // safe: submit linked operations of this type
        if (current == o) {
            if (previous) |p| p.state.next = o.state.next else r.head = o.state.next;
            if (r.tail == @as(?*anyopaque, o)) r.tail = @ptrCast(previous); // safe: previous is an operation in this listener's list
            o.result = .{ .accept = error.Canceled };
            a.ready(o);
            return true;
        }
        previous = current;
        raw = current.state.next;
    }
    return false;
}

pub fn close(a: *Accept, u: anytype, fd: linux.fd_t) void {
    const r = a.find(fd) orelse return;
    r.closing = true;
    a.discard(r);
    if (r.armed) stop(u, r) else if (r.head == null) a.reset(r);
}

fn stop(u: anytype, r: *Record) void {
    if (r.ending) return;
    r.ending = true;
    for (&r.slots) |*slot| {
        if (!slot.active) continue;
        const sqe = u.entry();
        sqe.prep_cancel(@intFromPtr(slot) | 5, 0); // safe: this accept slot's own completion token
        sqe.user_data = 4; // ignored cancellation acknowledgement
    }
}

/// A slot is retained until its sole completion, including after close.
pub fn complete(a: *Accept, u: anytype, slot: *Slot, cqe: linux.io_uring_cqe, sink: anytype) void {
    const Op = @typeInfo(@typeInfo(@TypeOf(@TypeOf(sink.*).complete)).@"fn".param_types[1].?).pointer.child;
    const r = slot.record;
    std.debug.assert(slot.active);
    slot.active = false;
    r.pending -= 1;
    r.armed = r.pending != 0;
    if (cqe.res >= 0) {
        if (r.closing) {
            _ = linux.close(cqe.res);
        } else if (pop(Op, r)) |o| {
            o.result = .{ .accept = peer(slot, cqe.res) };
            sink.complete(o);
        } else {
            std.debug.assert(r.count < bound);
            r.sockets[(r.first + r.count) % bound] = peer(slot, cqe.res);
            r.count += 1;
            // Grow only when a connection arrives before its consumer.
            // A listener keeping up pays for one request at a time.
            r.ahead = @min(bound, r.ahead * 2);
        }
    } else if (cqe.err() != .CANCELED or r.closing) {
        while (pop(Op, r)) |o| {
            o.result = .{ .accept = failure(cqe.err()) };
            sink.complete(o);
        }
        if (!r.closing) r.ending = true;
    }
    if (r.closing) {
        if (r.pending == 0) a.reset(r);
    } else if (r.pending == 0 and r.ending) {
        r.ending = false;
    } else if (cqe.res >= 0 and !r.ending) {
        a.arm(u, r);
    }
}

/// Shutdown has no live task operations; release late accepted descriptors.
pub fn drain(a: *Accept, slot: *Slot, result: i32) void {
    const r = slot.record;
    std.debug.assert(slot.active);
    std.debug.assert(r.closing);
    std.debug.assert(r.head == null);
    if (result >= 0) _ = linux.close(result);
    slot.active = false;
    r.pending -= 1;
    r.armed = r.pending != 0;
    if (!r.armed) a.reset(r);
}

fn peer(slot: *const Slot, fd: linux.fd_t) Io.net.Socket {
    return .{ .handle = fd, .address = Io.Threaded.addressFromPosix(&slot.address) };
}

fn failure(e: linux.E) Io.net.Server.AcceptError {
    return switch (e) {
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => error.SystemResources,
        .CONNABORTED => error.ConnectionAborted,
        .CANCELED, .BADF, .INVAL => error.SocketNotListening,
        .PROTO => error.ProtocolFailure,
        .PERM => error.BlockedByFirewall,
        else => error.Unexpected,
    };
}
