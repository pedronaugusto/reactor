//! A hierarchical timing wheel: 7 levels of 64 slots, level 0 one tick per
//! slot, level k 64^k ticks per slot, so 2^42 ticks before the overflow
//! list. A loop's tick is one microsecond.
//!
//! Arming and disarming are O(1). A 64-bit occupancy mask per level finds
//! the next deadline with one count of trailing zeros per level, so moving
//! time forward costs per level, never per tick. A timer is placed by the
//! highest bit in which its deadline differs from the current tick; it
//! moves down at most six times before it fires, and one disarmed first
//! never moves. Timers due at the same tick fire in the order they were
//! armed.
//!
//! Single-threaded: the wheel belongs to its loop's thread.
const Wheel = @This();

const std = @import("std");
const assert = std.debug.assert;

pub const levels = 7;
pub const slots_per_level = 64;
const slot_bits = 6;
const slot_mask: u64 = slots_per_level - 1;
/// Deadlines this far past the current tick wait on the overflow list.
pub const horizon_bits = levels * slot_bits;

/// One timer. Owned by its user, linked into the wheel between `arm` and
/// its firing or `disarm`; it must not move while linked.
pub const Node = struct {
    /// The tick it fires at, set by `arm`.
    deadline: u64 = 0,
    next: ?*Node = null,
    prev: ?*Node = null,
    place: Place = .unlinked,

    pub fn armed(n: *const Node) bool {
        return n.place != .unlinked;
    }
};

/// Where a node is linked: a level and slot, the overflow list, or nowhere.
const Place = enum(u16) {
    unlinked = std.math.maxInt(u16),
    overflow = std.math.maxInt(u16) - 1,
    due = std.math.maxInt(u16) - 2,
    _,

    fn at(l: usize, s: usize) Place {
        return @fromBackingInt(@intCast(l * slots_per_level + s));
    }

    fn level(p: Place) usize {
        return @backingInt(p) / slots_per_level;
    }

    fn slot(p: Place) usize {
        return @backingInt(p) % slots_per_level;
    }
};

const List = struct {
    head: ?*Node = null,
    tail: ?*Node = null,

    fn append(l: *List, n: *Node) void {
        n.next = null;
        n.prev = l.tail;
        if (l.tail) |t| t.next = n else l.head = n;
        l.tail = n;
    }

    fn remove(l: *List, n: *Node) void {
        if (n.prev) |p| p.next = n.next else l.head = n.next;
        if (n.next) |x| x.prev = n.prev else l.tail = n.prev;
        n.next = null;
        n.prev = null;
    }

    fn empty(l: List) bool {
        return l.head == null;
    }
};

/// The current tick: every timer left has a later deadline.
elapsed: u64,
occupied: [levels]u64 = @splat(0),
lists: [levels][slots_per_level]List = @splat(@splat(.{})),
overflow: List = .{},
/// Timers due at or before `elapsed` when armed: they fire at the next
/// `advance`, in arming order, before anything later.
due: List = .{},
count: u32 = 0,

pub fn init(now: u64) Wheel {
    return .{ .elapsed = now };
}

/// Links `n` to fire at `deadline`. A deadline already passed fires at the
/// next `advance`.
pub fn arm(w: *Wheel, n: *Node, deadline: u64) void {
    assert(!n.armed());
    n.deadline = deadline;
    w.count += 1;
    w.place(n);
}

/// Unlinks `n` if it is armed; a disarmed node may be armed again at once.
pub fn disarm(w: *Wheel, n: *Node) void {
    switch (n.place) {
        .unlinked => return,
        .overflow => w.overflow.remove(n),
        .due => w.due.remove(n),
        else => {
            const level = n.place.level();
            const slot = n.place.slot();
            const list = &w.lists[level][slot];
            list.remove(n);
            if (list.empty()) w.occupied[level] &= ~(@as(u64, 1) << @intCast(slot));
        },
    }
    n.place = .unlinked;
    w.count -= 1;
}

/// The earliest tick at which a timer may fire, or null when none is
/// armed. A slot above level 0 reports its start: `advance` there moves
/// its timers down, and the next call reports the exact tick.
pub fn next(w: *const Wheel) ?u64 {
    if (!w.due.empty()) return w.elapsed;
    for (0..levels) |level| {
        if (w.firstSlot(level)) |slot| return w.slotStart(level, slot);
    }
    if (!w.overflow.empty()) return (w.epoch() + 1) << horizon_bits;
    return null;
}

/// Moves time to `now` and calls `sink.fire(node)` for every timer whose
/// deadline is at or before it, earliest first, unlinked before the call;
/// a fired node may be armed again from the callback.
pub fn advance(w: *Wheel, now: u64, sink: anytype) void {
    w.fireList(&w.due, sink);
    if (now < w.elapsed) return;
    while (true) {
        const level, const slot, const start = w.nextSlot() orelse break;
        if (start > now) break;
        var list = w.lists[level][slot];
        w.lists[level][slot] = .{};
        w.occupied[level] &= ~(@as(u64, 1) << @intCast(slot));
        w.elapsed = @max(w.elapsed, start);
        // A level-0 slot is one tick: everything in it is due now. Above,
        // the slot's timers move down, so that they still fire earliest
        // first however far `now` is.
        while (list.head) |n| {
            list.remove(n);
            if (level == 0) {
                n.place = .unlinked;
                w.count -= 1;
                sink.fire(n);
            } else {
                w.place(n);
            }
        }
        // Those that moved down onto the current tick, and timers armed
        // from a callback for a time already passed.
        w.fireList(&w.due, sink);
    }
    const crossed = now >> horizon_bits != w.epoch();
    w.elapsed = now;
    if (crossed) {
        w.reinsertOverflow();
        w.fireList(&w.due, sink);
    }
}

fn fireList(w: *Wheel, list: *List, sink: anytype) void {
    while (list.head) |n| {
        list.remove(n);
        n.place = .unlinked;
        w.count -= 1;
        sink.fire(n);
    }
}

fn place(w: *Wheel, n: *Node) void {
    if (n.deadline <= w.elapsed) {
        w.due.append(n);
        n.place = .due;
        return;
    }
    const masked = (w.elapsed ^ n.deadline) | slot_mask;
    const significant = 63 - @clz(masked);
    const level = significant / slot_bits;
    if (level >= levels) {
        w.overflow.append(n);
        n.place = .overflow;
        return;
    }
    const slot: usize = @intCast((n.deadline >> @intCast(level * slot_bits)) & slot_mask);
    w.lists[level][slot].append(n);
    w.occupied[level] |= @as(u64, 1) << @intCast(slot);
    n.place = .at(level, slot);
}

fn firstSlot(w: *const Wheel, level: usize) ?usize {
    const position: u6 = @intCast((w.elapsed >> @intCast(level * slot_bits)) & slot_mask);
    const ahead = w.occupied[level] & (~@as(u64, 0) << position);
    if (ahead == 0) return null;
    return @ctz(ahead);
}

fn nextSlot(w: *const Wheel) ?struct { usize, usize, u64 } {
    for (0..levels) |level| {
        if (w.firstSlot(level)) |slot| return .{ level, slot, w.slotStart(level, slot) };
    }
    return null;
}

fn slotStart(w: *const Wheel, level: usize, slot: usize) u64 {
    const shift: u6 = @intCast(level * slot_bits);
    const block_shift: u7 = @as(u7, shift) + slot_bits;
    const block = if (block_shift >= 64) 0 else (w.elapsed >> @intCast(block_shift)) << @intCast(block_shift);
    return block + (@as(u64, slot) << shift);
}

fn epoch(w: *const Wheel) u64 {
    return w.elapsed >> horizon_bits;
}

/// Places the overflow list again once time has entered a new horizon
/// block: a timer that now fits a level moves there, one already due fires
/// at the caller's `fireList`.
fn reinsertOverflow(w: *Wheel) void {
    var list = w.overflow;
    w.overflow = .{};
    while (list.head) |n| {
        list.remove(n);
        w.place(n);
    }
}
