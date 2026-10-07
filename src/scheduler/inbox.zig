//! A processor's inbox: any thread pushes, the owner takes everything at
//! once. A Treiber stack whose consumer swaps the head out, so there is no
//! ABA to guard against; `takeAll` returns the items oldest first.
const std = @import("std");

/// An inbox of `*T`, linked through `T.<field>`, a `?*T`.
pub fn Inbox(comptime T: type, comptime field: []const u8) type {
    return struct {
        const Self = @This();

        head: std.atomic.Value(?*T) = .init(null),

        /// From any thread. True when the inbox was empty: the caller then
        /// wakes the owner if it may be waiting.
        pub fn push(b: *Self, item: *T) bool {
            var head = b.head.load(.monotonic);
            while (true) {
                @field(item, field) = head;
                head = b.head.cmpxchgWeak(head, item, .acq_rel, .monotonic) orelse return head == null;
            }
        }

        pub fn isEmpty(b: *const Self) bool {
            return b.head.load(.acquire) == null;
        }

        /// Owner only: every item pushed so far, oldest first, linked
        /// through the same field.
        pub fn takeAll(b: *Self) ?*T {
            var newest = b.head.swap(null, .acq_rel) orelse return null;
            var oldest: ?*T = null;
            while (true) {
                const older = @field(newest, field);
                @field(newest, field) = oldest;
                oldest = newest;
                newest = older orelse return oldest;
            }
        }
    };
}
