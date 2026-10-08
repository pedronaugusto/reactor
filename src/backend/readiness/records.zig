//! A readiness backend's records: one per descriptor it has registered with
//! its kernel poller, holding who waits on it each way, found by descriptor
//! through an open-addressing table (linear probing, deletion by backward
//! shift). All of it is sized at `init`; a record is freed when its
//! descriptor closes or, idle, to make room.
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const posix = std.posix;

pub const none = std.math.maxInt(u32);

/// The directions a descriptor is registered for.
pub const Directions = packed struct(u2) {
    read: bool = false,
    write: bool = false,

    pub const both: Directions = .{ .read = true, .write = true };

    pub fn has(d: Directions, other: Directions) bool {
        return @as(u2, @bitCast(d)) & @as(u2, @bitCast(other)) == @as(u2, @bitCast(other));
    }

    pub fn with(d: Directions, other: Directions) Directions {
        return @bitCast(@as(u2, @bitCast(d)) | @as(u2, @bitCast(other)));
    }

    pub fn without(d: Directions, other: Directions) Directions {
        return @bitCast(@as(u2, @bitCast(d)) & ~@as(u2, @bitCast(other)));
    }
};

/// Waiters oldest first, linked through their `prev` and `next`.
pub fn List(comptime Waiter: type) type {
    return struct {
        const Self = @This();

        head: ?*Waiter = null,
        tail: ?*Waiter = null,

        pub fn append(l: *Self, w: *Waiter) void {
            w.prev = l.tail;
            w.next = null;
            if (l.tail) |t| t.next = w else l.head = w;
            l.tail = w;
        }

        pub fn remove(l: *Self, w: *Waiter) void {
            if (w.prev) |p| p.next = w.next else l.head = w.next;
            if (w.next) |n| n.prev = w.prev else l.tail = w.prev;
            w.prev = null;
            w.next = null;
        }

        pub fn pop(l: *Self) ?*Waiter {
            const w = l.head orelse return null;
            l.remove(w);
            return w;
        }

        pub fn isEmpty(l: *const Self) bool {
            return l.head == null;
        }
    };
}

pub fn Records(comptime Waiter: type) type {
    return struct {
        const Self = @This();

        pub const Record = struct {
            fd: posix.fd_t = -1,
            /// Moves each time the record is taken for a descriptor: events
            /// the kernel queued for an earlier one carry the old value.
            generation: u32 = 0,
            /// The descriptor's close epoch when it was registered.
            epoch: u32 = 0,
            registered: Directions = .{},
            /// The ways the descriptor may be ready: cleared when a call
            /// finds it is not (`EAGAIN`, or a short stream read or write,
            /// which drains it), set by the next readiness event. A call
            /// the way it is not ready waits for the event without trying.
            ready: Directions = .both,
            /// Bytes the poller last said were there to read (kqueue's
            /// event says), less what reads have taken since; null where
            /// the poller does not say.
            available: ?u64 = null,
            /// Whether the descriptor is a byte stream, once asked.
            stream: ?bool = null,
            /// A listening socket the backend switched to non-blocking mode.
            listener: bool = false,
            /// Events in a row that found nobody waiting: at two the record
            /// lets go of the descriptor, which is waited on elsewhere now.
            idle_events: u8 = 0,
            /// Who waits, by direction.
            waiters: [2]List(Waiter) = .{ .{}, .{} },
            next_free: u32 = none,
            in_use: bool = false,

            pub fn idle(r: *const Record) bool {
                return r.waiters[0].isEmpty() and r.waiters[1].isEmpty();
            }
        };

        records: []Record,
        /// Index + 1 of the record holding each slot's descriptor; 0: empty.
        slots: []u32,
        free: u32,
        /// Where the search for an idle record to reuse goes on from.
        hand: u32 = 0,

        pub fn init(gpa: Allocator, capacity: u32) Allocator.Error!Self {
            const n = @max(capacity, 16);
            const records = try gpa.alloc(Record, n);
            errdefer gpa.free(records);
            const slots = try gpa.alloc(u32, std.math.ceilPowerOfTwoAssert(u32, 2 * n));
            @memset(slots, 0);
            for (records, 0..) |*r, i| r.* = .{ .next_free = if (i + 1 < n) @intCast(i + 1) else none };
            return .{ .records = records, .slots = slots, .free = 0 };
        }

        pub fn deinit(t: *Self, gpa: Allocator) void {
            gpa.free(t.slots);
            gpa.free(t.records);
            t.* = undefined;
        }

        pub fn at(t: *Self, index: u32) *Record {
            return &t.records[index];
        }

        fn home(t: *const Self, fd: posix.fd_t) usize {
            const h = @as(u64, @as(u32, @bitCast(fd))) *% 0x9E3779B97F4A7C15;
            return @intCast(h >> 32 & (t.slots.len - 1));
        }

        /// The record of `fd`, if there is one.
        pub fn find(t: *const Self, fd: posix.fd_t) ?u32 {
            var i = t.home(fd);
            while (true) : (i = (i + 1) & (t.slots.len - 1)) {
                const s = t.slots[i];
                if (s == 0) return null;
                if (t.records[s - 1].fd == fd) return s - 1;
            }
        }

        /// A new record for `fd`, which has none; null when all are taken.
        pub fn insert(t: *Self, fd: posix.fd_t) ?u32 {
            assert(t.find(fd) == null);
            const index = t.free;
            if (index == none) return null;
            const r = &t.records[index];
            t.free = r.next_free;
            r.* = .{ .fd = fd, .generation = r.generation +% 1, .in_use = true };
            var i = t.home(fd);
            while (t.slots[i] != 0) i = (i + 1) & (t.slots.len - 1);
            t.slots[i] = index + 1;
            return index;
        }

        /// Frees record `index`, which has nobody waiting.
        pub fn remove(t: *Self, index: u32) void {
            const r = &t.records[index];
            assert(r.in_use and r.idle());
            const mask = t.slots.len - 1;
            var i = t.home(r.fd);
            while (t.slots[i] != index + 1) i = (i + 1) & mask;
            // Backward shift: pull later entries of the run into the hole.
            var hole = i;
            var j = (i + 1) & mask;
            while (t.slots[j] != 0) : (j = (j + 1) & mask) {
                const want = t.home(t.records[t.slots[j] - 1].fd);
                // It may move unless its home lies cyclically in (hole, j].
                const stays = if (hole <= j) (want > hole and want <= j) else (want > hole or want <= j);
                if (!stays) {
                    t.slots[hole] = t.slots[j];
                    hole = j;
                }
            }
            t.slots[hole] = 0;
            r.* = .{ .generation = r.generation, .next_free = t.free };
            t.free = index;
        }

        /// An idle record in use, searching on from where the last search
        /// stopped; null when none is idle.
        pub fn idleOne(t: *Self) ?u32 {
            const n: u32 = @intCast(t.records.len);
            for (0..n) |_| {
                const i = t.hand;
                t.hand = (t.hand + 1) % n;
                const r = &t.records[i];
                if (r.in_use and r.idle()) return i;
            }
            return null;
        }
    };
}
