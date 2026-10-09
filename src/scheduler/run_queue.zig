//! A processor's bounded run queue: its owner pushes and pops without
//! contention; idle processors steal half of it at once.
//!
//! The head packs two indices: `real`, where the owner pops, and `steal`,
//! where a steal in progress began. They differ only while a stealer copies
//! tasks out, and a second stealer waits for that to finish. The tail is
//! written by the owner alone.
//!
//! Head, tail and slots each start on a cache line of their own. Thieves read
//! a victim's queues while it runs, so a line they share with anything the
//! owner writes on every task switch would bounce between cores; the fields
//! the owner writes stay off every line a thief reads.
const std = @import("std");
const assert = std.debug.assert;

pub const capacity = 256;
const mask = capacity - 1;

const Head = packed struct(u64) { real: u32, steal: u32 };

fn unpack(raw: u64) Head {
    return @bitCast(raw);
}

fn pack(h: Head) u64 {
    return @bitCast(h);
}

/// A queue of `*T`.
pub fn RunQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        head: std.atomic.Value(u64) align(std.atomic.cache_line) = .init(0),
        tail: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),
        buffer: [capacity]std.atomic.Value(?*T) align(std.atomic.cache_line) = @splat(.init(null)),

        /// The tasks queued, as the owner sees them.
        pub fn len(q: *const Self) u32 {
            const h = unpack(q.head.load(.acquire));
            return q.tail.load(.monotonic) -% h.steal;
        }

        pub fn isEmpty(q: *const Self) bool {
            const h = unpack(q.head.load(.acquire));
            return q.tail.load(.monotonic) == h.real;
        }

        /// Owner only. False when full: the caller moves work to the global
        /// queue (`takeHalf`) and pushes again.
        pub fn push(q: *Self, item: *T) bool {
            const tail = q.tail.raw;
            const h = unpack(q.head.load(.acquire));
            if (tail -% h.steal >= capacity) return false;
            q.buffer[tail & mask].store(item, .monotonic);
            q.tail.store(tail +% 1, .release);
            return true;
        }

        /// Owner only: the oldest task.
        pub fn pop(q: *Self) ?*T {
            var raw = q.head.load(.acquire);
            while (true) {
                const h = unpack(raw);
                if (h.real == q.tail.raw) return null;
                const real = h.real +% 1;
                const next: Head = if (h.steal == h.real) .{ .real = real, .steal = real } else .{ .real = real, .steal = h.steal };
                if (q.head.cmpxchgWeak(raw, pack(next), .acq_rel, .acquire)) |actual| {
                    raw = actual;
                    continue;
                }
                return q.buffer[h.real & mask].load(.monotonic);
            }
        }

        /// Owner only, when `push` fails: claims the older half so the caller
        /// can move it to the global queue. Null when a stealer is busy (the
        /// caller then finds room after it) or the queue holds less than half.
        pub fn takeHalf(q: *Self, out: *[capacity / 2]*T) bool {
            const half = capacity / 2;
            const raw = q.head.load(.acquire);
            const h = unpack(raw);
            if (h.steal != h.real) return false;
            if (q.tail.raw -% h.real < half) return false;
            const next: Head = .{ .real = h.real +% half, .steal = h.real +% half };
            if (q.head.cmpxchgStrong(raw, pack(next), .acq_rel, .acquire) != null) return false;
            for (out, 0..) |*slot, i| slot.* = q.buffer[(h.real +% @as(u32, @intCast(i))) & mask].load(.monotonic).?;
            return true;
        }

        /// Called by another processor: moves half of `q`'s tasks into
        /// `into`, the caller's own queue, and returns one more to run.
        pub fn stealInto(q: *Self, into: *Self) ?*T {
            const into_tail = into.tail.raw;
            const into_head = unpack(into.head.load(.acquire));
            if (into_tail -% into_head.steal > capacity / 2) return null;

            // Claim: move `real` ahead, leave `steal` where the copy starts.
            var raw = q.head.load(.acquire);
            var count: u32 = 0;
            var start: u32 = 0;
            while (true) {
                const h = unpack(raw);
                if (h.steal != h.real) return null; // another stealer is copying
                const tail = q.tail.load(.acquire);
                const available = tail -% h.real;
                if (available > capacity) return null; // a torn read of a moving queue
                count = available - available / 2;
                if (count == 0) return null;
                start = h.real;
                const next: Head = .{ .real = h.real +% count, .steal = h.steal };
                if (q.head.cmpxchgWeak(raw, pack(next), .acq_rel, .acquire)) |actual| {
                    raw = actual;
                    continue;
                }
                break;
            }
            // Copy, then release the claim.
            for (0..count) |i| {
                const item = q.buffer[(start +% @as(u32, @intCast(i))) & mask].load(.monotonic);
                into.buffer[(into_tail +% @as(u32, @intCast(i))) & mask].store(item, .monotonic);
            }
            raw = q.head.load(.acquire);
            while (true) {
                const h = unpack(raw);
                const next: Head = .{ .real = h.real, .steal = h.real };
                if (q.head.cmpxchgWeak(raw, pack(next), .acq_rel, .acquire)) |actual| {
                    raw = actual;
                    continue;
                }
                break;
            }
            // The last one copied runs now; the rest are published to `into`.
            const last = into.buffer[(into_tail +% count -% 1) & mask].load(.monotonic).?;
            if (count > 1) into.tail.store(into_tail +% count -% 1, .release);
            return last;
        }
    };
}
