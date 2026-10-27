//! A runtime with real worker threads and real time over the idle fake:
//! the scheduler's threaded behaviour (stealing, wakes across threads,
//! cancels across threads) on any system, with no kernel queue.
const Threads = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Runtime = @import("../Runtime.zig");
const slots = @import("../runtime/slots.zig");
const backend = @import("../backend.zig");
const Fake = @import("Fake.zig");
const Core = @import("../runtime/Core.zig");

runtime: Runtime,
fakes: []Fake,
gpa: Allocator,
backends: Core.Backends = .{ .backendFor = backendFor },

/// `t` must not move after this. Starts the workers.
pub fn init(t: *Threads, gpa: Allocator, options: Runtime.Options) !void {
    const count = (options.workers orelse 3) + 1;
    t.gpa = gpa;
    t.fakes = try gpa.alloc(Fake, count);
    errdefer gpa.free(t.fakes);
    for (t.fakes) |*f| f.* = .init(gpa, .idle);
    var o = options;
    o.workers = count - 1;
    t.backends = .{ .backendFor = backendFor };
    try t.runtime.core.init(gpa, o, .{ .custom = .{
        .backends = &t.backends,
        .clock = .system,
    } }, &slots.vtable);
    errdefer t.runtime.deinit();
    try t.runtime.start();
}

fn backendFor(b: *Core.Backends, processor: u16) *backend.Custom {
    const t: *Threads = @alignCast(@fieldParentPtr("backends", b)); // safe: the field belongs to this record
    return t.fakes[processor].custom();
}

pub fn deinit(t: *Threads) void {
    t.runtime.deinit();
    for (t.fakes) |*f| f.deinit();
    t.gpa.free(t.fakes);
    t.* = undefined;
}

pub fn io(t: *Threads) Io {
    return t.runtime.io();
}
