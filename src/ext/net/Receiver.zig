//! Receives into buffers from a pool shared by every `Receiver` made with
//! it, so a connection that is idle holds no buffer: a receiver waits for
//! its socket to be readable, then takes a buffer and reads what is there.
//! A buffer is lent to the caller until `release` or the next `next`.
const Receiver = @This();

const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const receive = @import("../../sys/receive.zig");
const wait = @import("../wait.zig");

pool: *Pool,
socket: Io.net.Socket.Handle,
/// The buffer the last `next` lent; not to be touched.
lent: ?u32 = null,

/// Buffers of one length, all allocated at `init`, taken and given back
/// from any thread without a lock.
pub const Pool = struct {
    memory: []u8,
    buffer_len: u32,
    links: []u32,
    /// The free list's head: an index plus one, and a tag against ABA.
    head: std.atomic.Value(u64) = .init(0),

    pub const Options = struct { buffer_len: u32 = 4096, buffers: u32 = 4096 };
    pub const InitError = Allocator.Error;

    pub fn init(gpa: Allocator, io: Io, options: Options) InitError!Pool {
        _ = io;
        std.debug.assert(options.buffer_len > 0);
        std.debug.assert(options.buffers > 0);
        const memory = try gpa.alloc(u8, @as(usize, options.buffer_len) * options.buffers);
        errdefer gpa.free(memory);
        var p: Pool = .{ .memory = memory, .buffer_len = options.buffer_len, .links = try gpa.alloc(u32, options.buffers) };
        var i = options.buffers;
        while (i > 0) {
            i -= 1;
            p.give(i);
        }
        return p;
    }

    /// Every buffer given back.
    pub fn deinit(p: *Pool, gpa: Allocator, io: Io) void {
        _ = io;
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
    return .{ .pool = pool, .socket = socket };
}

/// Gives back a buffer still lent.
pub fn deinit(r: *Receiver, io: Io) void {
    _ = io;
    r.giveBack();
    r.* = undefined;
}

pub const NextError = Io.Operation.NetRead.Error || error{ Timeout, EndOfStream } || Io.Cancelable;

/// The next bytes the socket has, in a buffer from the pool, waiting
/// until `timeout` for them. `SystemResources` when every buffer is lent.
/// The bytes are borrowed until `release` or the next `next`.
pub fn next(r: *Receiver, io: Io, timeout: Io.Timeout) NextError![]const u8 {
    r.giveBack();
    const deadline = timeout.toDeadline(io);
    while (true) {
        wait.wait(io, .{ .readable = r.socket }, deadline) catch |err| return switch (err) {
            error.Timeout => error.Timeout,
            error.Canceled => error.Canceled,
            error.Unsupported, error.Unexpected => error.Unexpected,
        };
        const index = r.pool.take() orelse return error.SystemResources;
        const n = read(io, r.socket, r.pool.buffer(index)) catch |err| {
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
    r.pool.give(index);
}

/// What the socket has now; null when nothing.
fn read(io: Io, socket: Io.net.Socket.Handle, buffer: []u8) (Io.Operation.NetRead.Error || Io.Cancelable)!?usize {
    if (builtin.os.tag != .windows) return receive.now(socket, buffer);
    var data: [1][]u8 = .{buffer};
    const result = try io.operate(.{ .net_read = .{ .socket_handle = socket, .data = &data } });
    const r = try result.net_read;
    return r.data_len;
}
