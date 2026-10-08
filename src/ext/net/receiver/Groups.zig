//! Provided buffer rings belong to the pool, one partition per runtime ring.
const Groups = @This();
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const BufferRing = @import("../../../sys/BufferRing.zig");
const Uring = @import("../../../backend/Uring.zig");
const Scheduler = @import("../../../Scheduler.zig");
const native = @import("../../native.zig");

pub const Group = struct {
    ring: *Uring,
    owner: *Scheduler.Processor,
    br: *align(std.heap.page_size_min) linux.io_uring_buf_ring,
    registration: BufferRing,
    id: u16,
    entries: u16,
    first: u32,
    count: u32,
    lock: Io.Mutex = .init,

    /// A buffer may be released from any worker; publication is serialized.
    pub fn give(g: *Group, memory: []u8, length: u32, index: u32) void {
        const io = Io.Threaded.global_single_threaded.io();
        g.lock.lockUncancelable(io);
        defer g.lock.unlock(io);
        const offset = @as(usize, g.first + index) * length;
        linux.IoUring.buf_ring_add(g.br, memory[offset..][0..length], @intCast(index), g.entries - 1, 0);
        linux.IoUring.buf_ring_advance(g.br, 1);
    }
};

items: []Group,

pub const Error = error{ SystemResources, Unexpected } || Allocator.Error;

pub fn init(gpa: Allocator, io: Io, memory: []u8, length: u32, buffers: u32) Error!?Groups {
    if (builtin.os.tag != .linux) return null;
    const core = native.runtimeOf(io) orelse return null;
    if (core.backendKind() != .io_uring) return null;
    if (buffers < core.processors.len or buffers > 32768) return error.SystemResources;
    const groups = try gpa.alloc(Group, core.processors.len);
    var made: usize = 0;
    var keep = false;
    defer if (!keep) {
        for (groups[0..made]) |*g| unregister(io, g);
        gpa.free(groups);
    };
    var first: u32 = 0;
    for (groups, core.processors) |*g, *p| {
        const ring = &p.loop.backend.io_uring;
        const count: u32 = @intCast((buffers - first) / (groups.len - made));
        const entries: u16 = @intCast(std.math.ceilPowerOfTwoAssert(u32, @max(2, count)));
        const id = ring.next_group.fetchAdd(1, .monotonic);
        if (id > std.math.maxInt(u16)) return error.SystemResources;
        const registration = register(io, p, entries, @intCast(id)) catch |err| switch (err) {
            error.Unsupported => return null,
            error.SystemResources => return error.SystemResources,
            error.Unexpected => return error.Unexpected,
        };
        const br = registration.br;
        g.* = .{ .ring = ring, .owner = p, .br = br, .registration = registration, .id = @intCast(id), .entries = entries, .first = first, .count = count };
        linux.IoUring.buf_ring_init(br);
        for (0..count) |i| {
            const offset = (@as(usize, first) + i) * length;
            linux.IoUring.buf_ring_add(br, memory[offset..][0..length], @intCast(i), entries - 1, @intCast(i));
        }
        linux.IoUring.buf_ring_advance(br, @intCast(count));
        made += 1;
        first += count;
    }
    keep = true;
    return .{ .items = groups };
}

pub fn deinit(g: *Groups, gpa: Allocator, io: Io) void {
    for (g.items) |*item| unregister(io, item);
    gpa.free(g.items);
    g.* = undefined;
}

// SINGLE_ISSUER registration calls belong to the ring's submitter too.
// Before a disabled ring is enabled, it has no submitter and can be set up here.
const Command = struct {
    errand: Scheduler.Errand = .{ .run = run },
    ready: Io.Event = .unset,
    io: Io,
    action: union(enum) { register: struct { entries: u16, id: u16 }, unregister: *BufferRing },
    result: BufferRing.Error!BufferRing = undefined,

    fn run(e: *Scheduler.Errand, p: *Scheduler.Processor) void {
        const c: *Command = @alignCast(@fieldParentPtr("errand", e)); // safe: embedded errand
        switch (c.action) {
            .register => |args| c.result = BufferRing.init(p.loop.backend.io_uring.ring.fd, args.entries, args.id),
            .unregister => |registration| registration.deinit(),
        }
        c.ready.set(c.io);
    }

    fn execute(c: *Command, p: *Scheduler.Processor) void {
        if (Scheduler.processor() == p or !p.loop.backend.io_uring.enabled) {
            run(&c.errand, p);
        } else {
            p.send(&c.errand);
            c.ready.waitUncancelable(c.io);
        }
    }
};

fn register(io: Io, p: *Scheduler.Processor, entries: u16, id: u16) BufferRing.Error!BufferRing {
    var command: Command = .{ .io = io, .action = .{ .register = .{ .entries = entries, .id = id } } };
    command.execute(p);
    return command.result;
}

fn unregister(io: Io, g: *Group) void {
    var command: Command = .{ .io = io, .action = .{ .unregister = &g.registration } };
    command.execute(g.owner);
}
