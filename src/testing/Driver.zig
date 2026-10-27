//! A runtime whose one loop runs on the seeded fake and a virtual clock,
//! with no thread of its own: the production scheduler, cancellation and
//! timers, replayed exactly from a seed. Virtual time jumps to the next
//! deadline whenever every task waits.
const Driver = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Source = @import("shakedown").Source;
const Runtime = @import("../Runtime.zig");
const slots = @import("../runtime/slots.zig");
const backend = @import("../backend.zig");
const clock = @import("../clock.zig");
const Fake = @import("Fake.zig");
const Core = @import("../runtime/Core.zig");

runtime: Runtime,
fake: Fake,
virtual: clock.Virtual,
backends: Core.Backends = .{ .backendFor = backendFor },

/// `d` must not move after this.
pub fn init(d: *Driver, gpa: Allocator, seed: u64, options: Runtime.Options) !void {
    return d.initWith(gpa, gpa, seed, options);
}

/// `init` with the runtime's allocator apart from the fake's.
pub fn initWith(d: *Driver, fake_gpa: Allocator, gpa: Allocator, seed: u64, options: Runtime.Options) !void {
    try d.build(fake_gpa, gpa, seed, options);
    errdefer d.runtime.deinit();
    try d.runtime.start();
}

/// Build a stopped driver to exercise the runtime startup boundary.
pub fn initUnstarted(d: *Driver, gpa: Allocator, seed: u64, options: Runtime.Options) !void {
    return d.build(gpa, gpa, seed, options);
}

fn build(d: *Driver, fake_gpa: Allocator, gpa: Allocator, seed: u64, options: Runtime.Options) !void {
    d.virtual = .{};
    d.fake = .init(fake_gpa, .{ .seeded = .{ .seed = seed, .virtual = &d.virtual } });
    errdefer d.fake.deinit();
    var o = options;
    o.workers = 0;
    d.backends = .{ .backendFor = backendFor };
    try d.runtime.core.init(gpa, o, .{ .custom = .{
        .backends = &d.backends,
        .clock = .{ .virtual = &d.virtual },
    } }, &slots.vtable);
}

fn backendFor(b: *Core.Backends, processor: u16) *backend.Custom {
    _ = processor;
    const d: *Driver = @alignCast(@fieldParentPtr("backends", b)); // safe: the field belongs to this record
    return d.fake.custom();
}

pub fn deinit(d: *Driver) void {
    d.runtime.deinit();
    d.fake.deinit();
    d.* = undefined;
}

pub fn io(d: *Driver) Io {
    return d.runtime.io();
}

/// Virtual nanoseconds since the start.
pub fn elapsed(d: *const Driver) u64 {
    return d.virtual.ns.load(.acquire);
}

/// Every fake scheduling and completion choice joins the property's tape.
/// check then shrinks inputs, timings, cancellation and completion races
/// in one replay, using the production scheduler throughout.
pub fn initSource(d: *Driver, gpa: Allocator, source: *Source, options: Runtime.Options) !void {
    try d.init(gpa, 0, options);
    d.fake.shared_source = source;
}
