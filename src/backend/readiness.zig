//! What epoll and kqueue share: a backend that is told when a descriptor is
//! ready, and makes the call itself.
//!
//! An operation is tried at once (a socket's call never waits: it passes
//! `MSG_DONTWAIT`); only when it would wait does it join the waiters of its
//! descriptor's record, which registers the descriptor with the poller,
//! edge-triggered and for good: no system call per wait, one per
//! descriptor's life. Each readiness event makes the waiting calls, oldest
//! first, until one would wait again. A descriptor in blocking mode (a pipe
//! or a terminal std opened) is called only once `poll(2)` says it is ready.
//!
//! Records outlive their waits, so a record is checked against the
//! descriptor's close epoch (closes.zig) before it is trusted, and lets go
//! of a descriptor that keeps reporting readiness with nobody waiting
//! (it moved to another processor's poller). Completions made outside a
//! poll (a cancel, a close ending other operations, a batch operation done
//! at once) wait in `done` for the next poll, which then does not wait.
//!
//! `real` and `boot` timers are kept per clock, the poller arming one kernel
//! timer per clock for the earliest.
//!
//! A poller provides: `name` (its field in an operation's scratch),
//! `max_events`, `init`, `deinit`, `register`, `deregister`, `full`,
//! `wait` (its own events), `decode`, `wake`, `woken`, `handle`,
//! `armClock` and `clockFired`.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const posix = std.posix;

const op = @import("op.zig");
const pending = @import("pending.zig");
const Wait = @import("wait.zig").Wait;
const calls = @import("readiness/calls.zig");
const socket = @import("../sys/socket.zig");
const closes = @import("readiness/closes.zig");
const records_ = @import("readiness/records.zig");

pub const Direction = calls.Direction;
pub const Directions = records_.Directions;
pub const How = calls.How;

/// The clocks with a kernel timer of their own.
pub const Clock = enum(u1) { real, boot };

/// What a poller's event says.
pub const Decoded = union(enum) {
    ignore,
    wake,
    clock: Clock,
    record: struct {
        key: u64,
        read: bool = false,
        write: bool = false,
        /// A priority condition, or a failure.
        priority: bool = false,
        /// The poller refused the registration of this direction.
        refused: ?Direction = null,
        /// Bytes there to read, where the poller says (kqueue).
        available: ?u64 = null,
        /// The read side ended: queued bytes are followed by EOF.
        read_ended: bool = false,
    },
};

/// Why a poller's `deregister` is called.
pub const Leaving = enum {
    /// The descriptor stays open: the registration is removed.
    open,
    /// The descriptor is about to close, which removes it anyway.
    closing,
};

pub const InitError = error{ BackendUnavailable, SystemResources, Unexpected } || Allocator.Error;
pub const RegisterError = error{ Unpollable, SystemResources, Unexpected };
pub const SubmitError = error{ SystemResources, Unexpected };
pub const PollError = error{ SystemResources, Unexpected };

/// Before `fd` is closed other than through a loop: every loop's record of
/// it becomes stale.
pub const forget = closes.bump;

/// What a waiting operation's action came to.
const Outcome = union(enum) {
    /// It would wait.
    wait,
    /// Done; what it says of what is left (`calls.progress`).
    done: calls.Progress,
};

/// What a waiting operation is asked to do, by `Waiter.act`.
const Action = enum {
    /// Make the call; false when it would wait.
    attempt,
    /// Make the call, which may not wait: the descriptor cannot be waited
    /// on (not pollable, or its registration was refused).
    attempt_unwaitable,
    /// The descriptor was closed or aborted under it.
    closed,
    /// Its timer is due.
    fired,
};

/// Who waits: an operation (this lives in its scratch) or a batch entry.
pub const Waiter = struct {
    prev: ?*Waiter = null,
    next: ?*Waiter = null,
    /// The operation's address; 0 for a batch entry.
    op: usize = 0,
    /// Acts on the operation, typed for it (operations only).
    act: ?*const fn (w: *Waiter, fd: posix.fd_t, action: Action) Outcome = null,
    record: u32 = records_.none,
    place: Place = .none,
    direction: Direction = .read,
    how: How = .call,
    /// A connect that put its socket in non-blocking mode puts it back.
    restore: bool = false,
    clock: Clock = .real,
    /// A timer's deadline on its clock, in nanoseconds.
    deadline: i96 = 0,

    pub const Place = enum(u2) { none, record, timer, done };
};

/// The actions on an operation of type `OpPtr`'s pointee.
fn Acts(comptime OpPtr: type) type {
    return struct {
        fn act(w: *Waiter, fd: posix.fd_t, action: Action) Outcome {
            const o: OpPtr = @ptrFromInt(w.op); // safe: `submit` stored this operation's address
            switch (action) {
                .closed => o.result = closedUnder(o),
                .fired => o.result = .{ .timer = {} },
                .attempt, .attempt_unwaitable => {
                    const may_wait = action == .attempt;
                    switch (o.kind) {
                        .raw => unreachable, // unreachable: raw requests require io_uring or IOCP

                        .io => |operation| {
                            const result = calls.make(operation) orelse if (may_wait) return .wait else failure(operation);
                            o.result = .{ .io = result };
                            return .{ .done = calls.progress(operation, result) };
                        },
                        .accept => o.result = .{ .accept = calls.accept(fd) orelse if (may_wait) return .wait else error.SystemResources },
                        .connect => {
                            o.result = .{ .connect = if (may_wait) calls.connected(fd) else error.Unexpected };
                            if (w.restore) calls.makeBlocking(fd);
                        },
                        .wait => o.result = .{ .wait = if (may_wait) {} else error.Unsupported },
                        else => unreachable, // unreachable: only these wait on a descriptor
                    }
                },
            }
            return .{ .done = .other };
        }
    };
}

pub fn Readiness(comptime Poller: type) type {
    return struct {
        const Self = @This();
        const Records = records_.Records(Waiter);
        const List = records_.List(Waiter);

        pub const Scratch = Waiter;

        /// A batch operation waiting, from a pool sized at `init`.
        const Entry = struct {
            waiter: Waiter = .{},
            token: pending.Token = undefined,
            outcome: pending.Outcome = undefined,

            fn of(w: *Waiter) *Entry {
                assert(w.op == 0);
                return @alignCast(@fieldParentPtr("waiter", w)); // safe: a waiter with no operation is an entry's
            }
        };

        const Fifo = struct {
            head: ?*Waiter = null,
            tail: ?*Waiter = null,

            fn push(f: *Fifo, w: *Waiter) void {
                w.next = null;
                if (f.tail) |t| t.next = w else f.head = w;
                f.tail = w;
            }

            fn pop(f: *Fifo) ?*Waiter {
                const w = f.head orelse return null;
                f.head = w.next;
                if (f.head == null) f.tail = null;
                w.next = null;
                return w;
            }
        };

        gpa: Allocator,
        poller: Poller,
        records: Records,
        entries: []Entry,
        free_entries: ?*Waiter = null,
        /// Completions made outside a poll, delivered by the next.
        done: Fifo = .{},
        timers: [2]List = .{ .{}, .{} },
        /// The deadline each clock's kernel timer is armed for.
        armed: [2]?i96 = .{ null, null },

        /// Tables for `max_ops` operations in flight.
        pub fn init(gpa: Allocator, max_ops: u32) InitError!Self {
            var poller = try Poller.init();
            errdefer poller.deinit();
            var records = try Records.init(gpa, max_ops);
            errdefer records.deinit(gpa);
            const entries = try gpa.alloc(Entry, @max(max_ops, 1));
            var self: Self = .{ .gpa = gpa, .poller = poller, .records = records, .entries = entries };
            for (entries) |*e| {
                e.* = .{};
                e.waiter.next = self.free_entries;
                self.free_entries = &e.waiter;
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.poller.deinit();
            self.records.deinit(self.gpa);
            self.gpa.free(self.entries);
            self.* = undefined;
        }

        // Operations.

        fn waiterOf(o: anytype) *Waiter {
            return &@field(o.state.storage.scratch, Poller.name);
        }

        /// Starts `o`; true when it completed at once (its result is set).
        pub fn submit(self: *Self, o: anytype) SubmitError!bool {
            o.state.storage.scratch = @unionInit(@TypeOf(o.state.storage.scratch), Poller.name, .{
                .op = @intFromPtr(o), // safe: read back as this operation by its actions
                .act = Acts(@TypeOf(o)).act,
            });
            const w = waiterOf(o);
            switch (o.kind) {
                .raw => unreachable, // unreachable: raw requests require io_uring or IOCP
                .io => |operation| {
                    const fd, const direction = calls.subject(operation);
                    const how = calls.howOf(operation);
                    self.nonblockingToSend(operation, fd);
                    // Known not ready: wait for the event without a call.
                    if (how == .call and self.notReady(fd, direction)) return self.park(w, fd, direction, how);
                    if (now(operation, fd, direction, how)) |result| {
                        o.result = .{ .io = result };
                        switch (calls.progress(operation, result)) {
                            .other => {},
                            else => |p| if (self.records.find(fd)) |index| {
                                _ = self.advance(self.records.at(index), direction, p);
                            },
                        }
                        return true;
                    }
                    return self.park(w, fd, direction, how);
                },
                .accept => |fd| {
                    const index = try self.recordFor(fd);
                    const r = self.records.at(index);
                    if (!r.nonblocking) {
                        _ = calls.makeNonblocking(fd) catch |err| {
                            o.result = .{ .accept = err };
                            return true;
                        };
                        r.nonblocking = true;
                    }
                    if (calls.accept(fd)) |result| {
                        o.result = .{ .accept = result };
                        return true;
                    }
                    return self.park(w, fd, .read, .call);
                },
                .connect => |c| {
                    w.restore = !c.nonblocking and calls.makeNonblocking(c.socket) catch |err| {
                        o.result = .{ .connect = err };
                        return true;
                    };
                    if (calls.connect(c.socket, c.address)) |result| {
                        if (w.restore) calls.makeBlocking(c.socket);
                        o.result = .{ .connect = result };
                        return true;
                    }
                    return self.park(w, c.socket, .write, .connect);
                },
                .read_at => |r| {
                    o.result = .{ .read_at = calls.readAt(r.file, r.buffer, r.offset) };
                    return true;
                },
                .write_at => |r| {
                    o.result = .{ .write_at = calls.writeAt(r.file, r.bytes, r.offset) };
                    return true;
                },
                .sync => |fd| {
                    o.result = .{ .sync = calls.sync(fd) };
                    return true;
                },
                .close => |fd| {
                    self.close(fd);
                    o.result = .{ .close = {} };
                    return true;
                },
                .abort => |fd| {
                    o.result = .{ .abort = if (self.records.find(fd)) |index| self.endAll(index) else 0 };
                    return true;
                },
                .timer => |deadline| {
                    const clock: Clock = switch (deadline.clock) {
                        .real => .real,
                        .boot => .boot,
                        else => unreachable, // unreachable: the loop keeps every other clock on its wheel
                    };
                    w.clock = clock;
                    w.deadline = deadline.raw.nanoseconds;
                    w.place = .timer;
                    self.timers[@backingInt(clock)].append(w);
                    const armed = self.armed[@backingInt(clock)];
                    if (armed == null or w.deadline < armed.?) self.arm(clock, w.deadline) catch |err| {
                        self.timers[@backingInt(clock)].remove(w);
                        w.place = .none;
                        return err;
                    };
                    return false;
                },
                .wait => |what| {
                    const fd, const direction: Direction = switch (what) {
                        .readable => |fd| .{ fd, .read },
                        .writable => |fd| .{ fd, .write },
                        .priority => |fd| .{ fd, .priority },
                        .object => unreachable, // unreachable: Windows objects never reach a POSIX backend
                    };
                    if (calls.ready(fd, direction)) {
                        o.result = .{ .wait = {} };
                        return true;
                    }
                    return self.park(w, fd, direction, .readiness);
                },
            }
        }

        /// Whether `fd` is known not to be ready `direction`'s way: a call
        /// found it so, and no event has said otherwise since.
        fn notReady(self: *Self, fd: posix.fd_t, direction: Direction) bool {
            const index = self.records.find(fd) orelse return false;
            const r = self.records.at(index);
            return r.epoch == closes.epoch(fd) and r.registered.has(directions(direction)) and !r.ready.has(directions(direction));
        }

        /// What a completed call on `r`'s descriptor says of what is left;
        /// true when it drained it.
        fn advance(self: *Self, r: *Records.Record, direction: Direction, p: calls.Progress) bool {
            _ = self;
            // A terminal edge covers the remaining bytes and every later
            // EOF read. Clearing it after a short read would wait forever.
            if (direction == .read and r.read_ended) return false;
            const drained = switch (p) {
                .other => false,
                .short_write => true,
                .read => |read| drained: {
                    if (r.available) |available| {
                        if (read.got >= available) break :drained true;
                        r.available = available - read.got;
                        break :drained false;
                    }
                    // Without a count, a short read drains a byte stream
                    // alone: a datagram or a sequenced packet leaves the
                    // next one queued.
                    if (read.got >= read.asked) break :drained false;
                    if (r.stream == null) r.stream = calls.isStream(r.fd);
                    break :drained r.stream.?;
                },
            };
            if (drained) {
                r.ready = r.ready.without(directions(direction));
                if (direction == .read) r.available = 0;
            }
            return drained;
        }

        /// A socket about to be written is in non-blocking mode where its
        /// send would otherwise wait for room (`socket.send_honors_dontwait`).
        /// Once for the record; a descriptor that cannot be switched is left
        /// to the call, which reports it.
        fn nonblockingToSend(self: *Self, operation: Io.Operation, fd: posix.fd_t) void {
            if (comptime socket.send_honors_dontwait) return;
            switch (operation) {
                .net_write, .net_send => {},
                else => return,
            }
            const index = self.recordFor(fd) catch return;
            const r = self.records.at(index);
            if (r.nonblocking) return;
            _ = calls.makeNonblocking(fd) catch return;
            r.nonblocking = true;
        }

        /// `operation` made now if it can be without waiting.
        fn now(operation: Io.Operation, fd: posix.fd_t, direction: Direction, how: How) ?Io.Operation.Result {
            return switch (how) {
                .call => calls.make(operation),
                else => if (calls.ready(fd, direction)) calls.make(operation) else null,
            };
        }

        /// Asks for `o` to end; its completion arrives at the next poll,
        /// unless it completed already (then that result stands).
        pub fn cancel(self: *Self, o: anytype) void {
            const w = waiterOf(o);
            switch (w.place) {
                .none, .done => return,
                .record => {
                    const r = self.records.at(w.record);
                    r.waiters[@backingInt(w.direction)].remove(w);
                    if (w.restore) calls.makeBlocking(r.fd);
                },
                .timer => self.timers[@backingInt(w.clock)].remove(w),
            }
            o.result = canceled(o);
            self.finish(w);
        }

        /// A batch's operation, kept in its storage under `token`.
        pub fn submitPending(self: *Self, token: pending.Token, operation: Io.Operation) SubmitError!void {
            const w = self.free_entries orelse return error.SystemResources;
            self.free_entries = w.next;
            const e = Entry.of(w);
            e.* = .{ .token = token };
            const fd, const direction = calls.subject(operation);
            const how = calls.howOf(operation);
            self.nonblockingToSend(operation, fd);
            if (now(operation, fd, direction, how)) |result| {
                e.outcome = .{ .result = result };
                return self.finish(&e.waiter);
            }
            _ = self.park(&e.waiter, fd, direction, how) catch |err| {
                e.waiter.next = self.free_entries;
                self.free_entries = &e.waiter;
                return err;
            };
        }

        pub fn cancelPending(self: *Self, token: pending.Token) void {
            const fd, const direction = calls.subject(pending.unpack(token.pending()));
            const index = self.records.find(fd) orelse return;
            const list = &self.records.at(index).waiters[@backingInt(direction)];
            var it = list.head;
            while (it) |w| : (it = w.next) {
                if (w.op != 0 or Entry.of(w).token != token) continue;
                list.remove(w);
                Entry.of(w).outcome = .canceled;
                return self.finish(w);
            }
        }

        /// From any thread: ends a waiting `poll`.
        pub fn wake(self: *Self) void {
            self.poller.wake();
        }

        /// Readable when a poll has work: the poller's own descriptor.
        pub fn handle(self: *Self) Io.File.Handle {
            return self.poller.handle();
        }

        /// Completions waiting for the next poll.
        pub fn hasCompletions(self: *const Self) bool {
            return self.done.head != null;
        }

        /// Delivers completions to `sink`, waiting as `wait` allows.
        pub fn poll(self: *Self, wait: Wait, sink: anytype) PollError!void {
            const Sink = @typeInfo(@TypeOf(sink)).pointer.child;
            const OpPtr = @typeInfo(@TypeOf(Sink.complete)).@"fn".param_types[1].?;
            var timeout = if (self.done.head != null) Wait.nowait else wait;
            while (try self.pump(timeout) == Poller.max_events) timeout = .nowait;
            while (self.done.pop()) |w| {
                w.place = .none;
                if (w.op != 0) {
                    sink.complete(@as(OpPtr, @ptrFromInt(w.op))); // safe: `submit` stored this operation's address
                } else {
                    const e = Entry.of(w);
                    const token = e.token;
                    const outcome = e.outcome;
                    w.next = self.free_entries;
                    self.free_entries = w;
                    sink.completePending(token, outcome);
                }
            }
        }

        // Waiting.

        /// `w` waits for `fd` to be ready `direction`'s way. True when an
        /// operation cannot (its descriptor cannot be polled) and was made
        /// in place, its result set.
        fn park(self: *Self, w: *Waiter, fd: posix.fd_t, direction: Direction, how: How) SubmitError!bool {
            const index = try self.recordFor(fd);
            const r = self.records.at(index);
            if (!r.registered.has(directions(direction))) {
                try self.room();
                const key = @as(u64, r.generation) << 32 | index;
                r.registered = self.poller.register(fd, key, r.registered, direction) catch |err| switch (err) {
                    error.Unpollable => {
                        // Always ready (a regular file): made in place.
                        // An operation's result is taken at once; a batch
                        // entry's goes out with the next poll.
                        _ = self.act(w, fd, .attempt_unwaitable);
                        if (w.op != 0) return true;
                        self.finish(w);
                        return false;
                    },
                    error.SystemResources => return error.SystemResources,
                    error.Unexpected => return error.Unexpected,
                };
            }
            w.how = how;
            w.direction = direction;
            w.record = index;
            w.place = .record;
            r.idle_events = 0;
            // It waits because the descriptor is not ready this way.
            r.ready = r.ready.without(directions(direction));
            if (direction == .read) r.available = 0;
            r.waiters[@backingInt(direction)].append(w);
            return false;
        }

        fn act(self: *Self, w: *Waiter, fd: posix.fd_t, action: Action) Outcome {
            _ = self;
            if (w.act) |f| return f(w, fd, action);
            const e = Entry.of(w);
            switch (action) {
                .closed => e.outcome = .canceled,
                .fired => unreachable, // unreachable: a batch has no timers here
                .attempt, .attempt_unwaitable => {
                    const operation = pending.unpack(e.token.pending());
                    const result = calls.make(operation) orelse if (action == .attempt) return .wait else failure(operation);
                    e.outcome = .{ .result = result };
                    return .{ .done = calls.progress(operation, result) };
                },
            }
            return .{ .done = .other };
        }

        /// The record of `fd`, made if there is none, and checked against
        /// the descriptor's close epoch.
        fn recordFor(self: *Self, fd: posix.fd_t) SubmitError!u32 {
            const epoch = closes.epoch(fd);
            if (self.records.find(fd)) |index| {
                const r = self.records.at(index);
                if (r.epoch != epoch) {
                    // Closed and opened again since it was registered: the
                    // kernel has dropped that registration.
                    _ = self.endAll(index);
                    r.registered = .{};
                    r.nonblocking = false;
                    r.ready = .both;
                    r.available = null;
                    r.stream = null;
                    r.read_ended = false;
                    r.generation +%= 1;
                    r.epoch = epoch;
                }
                return index;
            }
            const index = self.records.insert(fd) orelse blk: {
                const idle = self.records.idleOne() orelse return error.SystemResources;
                try self.letGo(idle);
                break :blk self.records.insert(fd).?;
            };
            self.records.at(index).epoch = epoch;
            return index;
        }

        /// Frees an idle record, deregistering its descriptor.
        fn letGo(self: *Self, index: u32) SubmitError!void {
            const r = self.records.at(index);
            assert(r.idle());
            if (r.epoch == closes.epoch(r.fd) and !r.registered.none()) {
                try self.room();
                self.poller.deregister(r.fd, r.registered, .open);
            }
            self.records.remove(index);
        }

        /// Room for a change in the poller's next call: a kqueue changelist
        /// that is full goes to the kernel now.
        fn room(self: *Self) SubmitError!void {
            if (!self.poller.full()) return;
            _ = try self.pump(.nowait);
        }

        fn arm(self: *Self, clock: Clock, deadline: ?i96) SubmitError!void {
            try self.room();
            try self.poller.armClock(clock, deadline);
            self.armed[@backingInt(clock)] = deadline;
        }

        fn finish(self: *Self, w: *Waiter) void {
            w.place = .done;
            w.record = records_.none;
            self.done.push(w);
        }

        // Closing.

        /// Ends what waits on `fd`, lets go of its record, and closes it.
        fn close(self: *Self, fd: posix.fd_t) void {
            if (self.records.find(fd)) |index| {
                _ = self.endAll(index);
                self.poller.deregister(fd, self.records.at(index).registered, .closing);
                self.records.remove(index);
            }
            closes.bump(fd);
            calls.close(fd);
        }

        /// Ends everything waiting on record `index` as if its descriptor
        /// had been closed under it; how many.
        fn endAll(self: *Self, index: u32) usize {
            const r = self.records.at(index);
            var n: usize = 0;
            for (&r.waiters) |*list| while (list.pop()) |w| {
                _ = self.act(w, r.fd, .closed);
                self.finish(w);
                n += 1;
            };
            return n;
        }

        // Events.

        /// Asks the poller for events (handing it its queued changes), and
        /// acts on each; how many it returned.
        fn pump(self: *Self, timeout: Wait) PollError!usize {
            const events = try self.poller.wait(timeout);
            for (events) |*event| self.handleEvent(Poller.decode(event));
            return events.len;
        }

        fn handleEvent(self: *Self, decoded: Decoded) void {
            switch (decoded) {
                .ignore => {},
                .wake => self.poller.woken(),
                .clock => |clock| self.expire(clock),
                .record => |e| {
                    const index: u32 = @truncate(e.key);
                    if (index >= self.records.records.len) return;
                    const r = self.records.at(index);
                    if (!r.in_use or r.generation != @as(u32, @intCast(e.key >> 32))) return;
                    if (e.refused) |direction| {
                        r.registered = r.registered.without(directions(direction));
                        return self.serve(index, direction, .attempt_unwaitable);
                    }
                    // Ready again, waited on or not: the next call tries.
                    if (e.read) {
                        r.ready = r.ready.with(.{ .read = true });
                        r.available = e.available;
                        r.read_ended = r.read_ended or e.read_ended;
                    }
                    if (e.write) r.ready = r.ready.with(.{ .write = true });
                    if (e.priority) r.ready = r.ready.with(.{ .priority = true });
                    if (r.idle()) {
                        r.idle_events += 1;
                        // No room to deregister now: the next event tries again.
                        if (r.idle_events >= 2) self.letGo(index) catch |err| switch (err) {
                            error.SystemResources, error.Unexpected => {},
                        };
                        return;
                    }
                    r.idle_events = 0;
                    if (e.read) self.serve(index, .read, .attempt);
                    if (e.write) self.serve(index, .write, .attempt);
                    if (e.priority) self.serve(index, .priority, .attempt);
                },
            }
        }

        /// The descriptor of record `index` became ready `direction`'s way
        /// (or can no longer be waited on): its waiters' calls, oldest
        /// first, until one would wait.
        fn serve(self: *Self, index: u32, direction: Direction, action: Action) void {
            const r = self.records.at(index);
            const list = &r.waiters[@backingInt(direction)];
            var first = true;
            var it = list.head;
            while (it) |w| {
                const next = w.next;
                // A descriptor in blocking mode is called again only while
                // it is still ready.
                if (w.how == .ready_then_call and !first and action == .attempt and !calls.ready(r.fd, direction)) return;
                switch (self.act(w, r.fd, action)) {
                    .done => |p| {
                        list.remove(w);
                        self.finish(w);
                        // Nothing left for the next: it waits for an event.
                        if (self.advance(r, direction, p)) return;
                    },
                    .wait => if (w.how == .call) {
                        r.ready = r.ready.without(directions(direction));
                        if (direction == .read) r.available = 0;
                        return;
                    },
                }
                first = false;
                it = next;
            }
        }

        /// The kernel timer of `clock` fired (or the clock was set): every
        /// timer due fires, and the kernel timer is armed for the next.
        fn expire(self: *Self, clock: Clock) void {
            self.poller.clockFired(clock);
            const io_clock: Io.Clock = switch (clock) {
                .real => .real,
                .boot => .boot,
            };
            const time = io_clock.now(Io.Threaded.global_single_threaded.io()).nanoseconds;
            const list = &self.timers[@backingInt(clock)];
            var earliest: ?i96 = null;
            var it = list.head;
            while (it) |w| {
                it = w.next;
                if (w.deadline <= time) {
                    list.remove(w);
                    _ = self.act(w, -1, .fired);
                    self.finish(w);
                } else if (earliest == null or w.deadline < earliest.?) earliest = w.deadline;
            }
            self.arm(clock, earliest) catch {
                // No room for the kernel timer now: the next poll's events
                // bring another chance, as the clock fires again unarmed.
                self.armed[@backingInt(clock)] = null;
            };
        }
    };
}

fn directions(d: Direction) Directions {
    return switch (d) {
        .read => .{ .read = true },
        .write => .{ .write = true },
        .priority => .{ .priority = true },
    };
}

// Results.

/// The result of an operation cancelled before it completed.
fn canceled(o: anytype) op.Result {
    return switch (o.kind) {
        .raw => unreachable, // unreachable: raw requests never enter a readiness backend

        .io => .{ .io = error.Canceled },
        .accept => .{ .accept = error.Canceled },
        .connect => .{ .connect = error.Canceled },
        .read_at => .{ .read_at = error.Canceled },
        .write_at => .{ .write_at = error.Canceled },
        .sync => .{ .sync = error.Canceled },
        .close => .{ .close = {} },
        .abort => .{ .abort = 0 },
        .timer => .{ .timer = error.Canceled },
        .wait => .{ .wait = error.Canceled },
    };
}

/// The result of an operation whose descriptor was closed (or aborted)
/// under it, as io_uring reports a cancel nobody here asked for.
fn closedUnder(o: anytype) op.Result {
    return switch (o.kind) {
        .raw => unreachable, // unreachable: raw requests never enter a readiness backend

        .io => |operation| .{
            .io = switch (operation) {
                .file_read_streaming => .{ .file_read_streaming = error.SocketUnconnected },
                .file_write_streaming => .{ .file_write_streaming = error.BrokenPipe },
                .net_read => .{ .net_read = error.SocketUnconnected },
                .net_write => .{ .net_write = error.SocketUnconnected },
                .net_receive => .{ .net_receive = .{ error.SocketUnconnected, 0 } },
                .net_send => .{ .net_send = .{ error.SocketUnconnected, 0 } },
                .device_io_control => unreachable, // unreachable: never waits on a loop
            },
        },
        .accept => .{ .accept = error.SocketNotListening },
        .connect => .{ .connect = error.ConnectionResetByPeer },
        .wait => .{ .wait = error.Canceled },
        else => unreachable, // unreachable: only these wait on a descriptor
    };
}

/// The result of an operation that could neither complete nor wait.
fn failure(operation: Io.Operation) Io.Operation.Result {
    return switch (operation) {
        .file_read_streaming => .{ .file_read_streaming = error.SystemResources },
        .file_write_streaming => .{ .file_write_streaming = error.SystemResources },
        .net_read => .{ .net_read = error.SystemResources },
        .net_write => .{ .net_write = error.SystemResources },
        .net_receive => .{ .net_receive = .{ error.SystemResources, 0 } },
        .net_send => .{ .net_send = .{ error.SystemResources, 0 } },
        .device_io_control => unreachable, // unreachable: never waits on a loop
    };
}
