//! What a backend hands its kernel to name an operation: a slot in a table
//! the backend owns, and the slot's generation, never an address. A
//! completion is looked up by its key; one whose slot has been freed since,
//! or that names a slot the backend never filled, is refused rather than
//! followed, so a stale or forged completion cannot reach memory.
//!
//! The table is sized at `init` and never grows: a backend's operations in
//! flight are bounded already, and a full table is that bound reached.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// The slots of a table of `T`, each found by a `Key`.
pub fn Slab(comptime T: type, comptime Generation: type) type {
    return struct {
        const Self = @This();

        slots: []Slot,
        /// The free slots, linked through `next_free`.
        free: ?u32,
        /// Completions refused: their slot was free, or held a later
        /// generation.
        stale: u64 = 0,

        pub const Key = struct {
            index: u32,
            generation: Generation,
        };

        const Slot = struct {
            generation: Generation = 0,
            value: ?T = null,
            next_free: ?u32 = null,
        };

        pub fn init(gpa: Allocator, capacity: u32) Allocator.Error!Self {
            const slots = try gpa.alloc(Slot, capacity);
            for (slots, 0..) |*slot, i| slot.* = .{ .next_free = if (i + 1 < slots.len) @intCast(i + 1) else null };
            return .{ .slots = slots, .free = if (slots.len == 0) null else 0 };
        }

        pub fn deinit(s: *Self, gpa: Allocator) void {
            gpa.free(s.slots);
        }

        /// `value` in a free slot, and the key that finds it; null when
        /// every slot is taken.
        pub fn put(s: *Self, value: T) ?Key {
            const index = s.free orelse return null;
            const slot = &s.slots[index];
            s.free = slot.next_free;
            slot.* = .{ .generation = slot.generation, .value = value };
            return .{ .index = index, .generation = slot.generation };
        }

        /// What `key` names, while its slot holds it; null, counted as
        /// stale, for a key whose slot was freed since or never filled.
        pub fn get(s: *Self, key: Key) ?T {
            if (key.index >= s.slots.len) return s.refuse();
            const slot = &s.slots[key.index];
            if (slot.generation != key.generation) return s.refuse();
            return slot.value orelse s.refuse();
        }

        /// The slot `key` names freed: its generation moves on, so a later
        /// completion carrying the key is refused. False, counted as stale,
        /// when the key no longer names it.
        pub fn remove(s: *Self, key: Key) bool {
            _ = s.get(key) orelse return false;
            const slot = &s.slots[key.index];
            slot.* = .{ .generation = slot.generation +% 1, .next_free = s.free };
            s.free = key.index;
            return true;
        }

        /// Slots taken.
        pub fn count(s: *const Self) u32 {
            var n: u32 = 0;
            for (s.slots) |slot| {
                if (slot.value != null) n += 1;
            }
            return n;
        }

        fn refuse(s: *Self) ?T {
            s.stale += 1;
            return null;
        }
    };
}

const testing = std.testing;

test "a key finds its value until its slot is freed, and never after, though the slot is filled again" {
    var s: Slab(u32, u8) = try .init(testing.allocator, 2);
    defer s.deinit(testing.allocator);
    const a = s.put(10).?;
    const b = s.put(20).?;
    try testing.expect(s.put(30) == null);
    try testing.expectEqual(@as(?u32, 10), s.get(a));
    try testing.expect(s.remove(a));
    const c = s.put(30).?;
    try testing.expectEqual(a.index, c.index);
    try testing.expectEqual(@as(?u32, 30), s.get(c));
    // The old key names the reused slot by its old generation: refused.
    try testing.expect(s.get(a) == null);
    try testing.expect(!s.remove(a));
    try testing.expectEqual(@as(?u32, 20), s.get(b));
    try testing.expectEqual(@as(u64, 2), s.stale);
}

test "a key no slot has, or a slot never filled, is refused and counted" {
    var s: Slab(u32, u16) = try .init(testing.allocator, 4);
    defer s.deinit(testing.allocator);
    try testing.expect(s.get(.{ .index = 9, .generation = 0 }) == null);
    try testing.expect(s.get(.{ .index = 3, .generation = 0 }) == null);
    try testing.expectEqual(@as(u64, 2), s.stale);
    try testing.expectEqual(@as(u32, 0), s.count());
}
