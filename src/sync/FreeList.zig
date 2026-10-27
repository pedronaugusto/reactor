//! A lock-free stack of the free entries of a caller's table, by index,
//! linked through the caller's `links` (one per entry). Its head carries a
//! tag moved on at every change, so a head seen before a pop and a push is
//! not taken for the head after them (ABA).
const FreeList = @This();

const std = @import("std");
const aegis = @import("aegis");

/// An entry's next: another entry's index, or `end`.
pub const Link = enum(u32) {
    end = std.math.maxInt(u32),
    _,

    pub fn of(at: u32) Link {
        return @fromBackingInt(at);
    }

    /// The index it names, or null at the end.
    pub fn index(l: Link) ?u32 {
        return if (l == .end) null else @backingInt(l);
    }
};

const Head = enum(u64) {
    _,

    const Parts = packed struct(u64) { first: Link, tag: u32 };

    const empty: Head = of(.end, 0);

    fn of(first_: Link, tag_: u32) Head {
        return @fromBackingInt(@as(u64, @bitCast(Parts{ .first = first_, .tag = tag_ })));
    }

    fn parts(h: Head) Parts {
        return @bitCast(@backingInt(h));
    }
};

head: aegis.Atomic(Head) = .init(.empty),

/// The free entry taken, or null when none is free.
pub fn pop(f: *FreeList, links: []aegis.Atomic(Link)) ?u32 {
    var head = f.head.load(.acquire);
    while (true) {
        const parts = head.parts();
        const index = parts.first.index() orelse return null;
        const next = Head.of(links[index].load(.monotonic), parts.tag +% 1);
        head = f.head.cmpxchgWeak(head, next, .acq_rel, .acquire) orelse return index;
    }
}

/// Entry `index` free again.
pub fn push(f: *FreeList, links: []aegis.Atomic(Link), index: u32) void {
    var head = f.head.load(.monotonic);
    while (true) {
        const parts = head.parts();
        links[index].store(parts.first, .monotonic);
        head = f.head.cmpxchgWeak(head, Head.of(.of(index), parts.tag +% 1), .release, .monotonic) orelse return;
    }
}

test "entries come off in the order they went on, last first, until none is left" {
    var links: [3]aegis.Atomic(Link) = @splat(.init(.end));
    var f: FreeList = .{};
    try std.testing.expect(f.pop(&links) == null);
    for (0..3) |i| f.push(&links, @intCast(i));
    try std.testing.expectEqual(@as(?u32, 2), f.pop(&links));
    try std.testing.expectEqual(@as(?u32, 1), f.pop(&links));
    f.push(&links, 2);
    try std.testing.expectEqual(@as(?u32, 2), f.pop(&links));
    try std.testing.expectEqual(@as(?u32, 0), f.pop(&links));
    try std.testing.expect(f.pop(&links) == null);
}
