//! Every ring's fixed-buffer registration is made on that ring's owner.
const Registrations = @This();
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Scheduler = @import("../../../Scheduler.zig");
const native = @import("../../native.zig");
const Buffers = @import("../../../backend/uring/Buffers.zig");
pub const Error = Buffers.Error || std.mem.Allocator.Error;
const Item = struct { owner: *Scheduler.Processor, index: u16 };
items: []Item,

pub fn init(gpa: std.mem.Allocator, io: Io, memory: []u8) Error!Registrations {
    if (comptime builtin.os.tag != .linux) return error.Unsupported;
    const core = native.runtimeOf(io) orelse return error.Unsupported;
    if (core.backendKind() != .io_uring) return error.Unsupported;
    const items = try gpa.alloc(Item, core.processors.len);
    errdefer gpa.free(items);
    var made: usize = 0;
    errdefer for (items[0..made]) |item| unregister(io, item);
    for (items, core.processors) |*item, *owner| {
        var command: Command = .{ .io = io, .action = .{ .register = memory } };
        command.execute(owner);
        item.* = .{ .owner = owner, .index = try command.result };
        made += 1;
    }
    return .{ .items = items };
}

pub fn deinit(r: *Registrations, gpa: std.mem.Allocator, io: Io) void {
    for (r.items) |item| unregister(io, item);
    gpa.free(r.items);
    r.* = undefined;
}

fn unregister(io: Io, item: Item) void {
    var command: Command = .{ .io = io, .action = .{ .unregister = item.index } };
    command.execute(item.owner);
}

const Command = struct {
    errand: Scheduler.Errand = .{ .run = run },
    ready: Io.Event = .unset,
    io: Io,
    action: union(enum) { register: []u8, unregister: u16 },
    result: Buffers.Error!u16 = undefined,

    fn run(e: *Scheduler.Errand, p: *Scheduler.Processor) void {
        if (comptime builtin.os.tag != .linux) unreachable; // unreachable: registration is Linux only
        const command: *Command = @alignCast(@fieldParentPtr("errand", e)); // safe: embedded command
        const ring = p.loop.backend.io_uring;
        switch (command.action) {
            .register => |memory| command.result = ring.buffers.register(&ring.ring, memory),
            .unregister => |index| ring.buffers.unregister(&ring.ring, index),
        }
        command.ready.set(command.io);
    }

    fn execute(command: *Command, owner: *Scheduler.Processor) void {
        if (comptime builtin.os.tag != .linux) unreachable; // unreachable: registration is Linux only
        const core = native.runtimeOf(command.io).?;
        if (Scheduler.processor() == owner or (!core.started.load(.acquire) and !owner.loop.backend.io_uring.enabled)) run(&command.errand, owner) else {
            owner.send(&command.errand);
            command.ready.waitUncancelable(command.io);
        }
    }
};
