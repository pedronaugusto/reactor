//! kqueue (macOS and the BSDs) as a readiness poller. Registrations are
//! `EV_CLEAR` (edge-triggered), one filter per direction as it is first
//! waited on, and ride the next `kevent` call in its changelist: they cost
//! no system call of their own. A refused registration comes back as an
//! `EV_ERROR` event, which the changelist's size never lets the event list
//! run out of room for. Wakes from other threads trigger an `EVFILT_USER`
//! event (a pipe where the system has none); `real` and `boot` timers are
//! one `EVFILT_TIMER` each, absolute where the system has absolute timers.
//!
//! Darwin gets `kevent64`: asked not to wait, `kevent` there still goes
//! through a timer and costs ~12 µs, where `KEVENT_FLAG_IMMEDIATE` costs
//! ~0.2 µs; and its timeouts are coalesced (~130 µs late for 1 ms), where
//! an `EVFILT_TIMER` marked `NOTE_CRITICAL` fires ~35 µs late. So a wait
//! with a timeout arms that timer and waits without one.
const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const c = std.c;

const readiness = @import("../readiness.zig");
const Wait = @import("../wait.zig").Wait;

const Kqueue = @This();

pub const name = "kqueue";
pub const max_events = 256;
/// Changes queued for the next call, never more than the event list holds
/// (one is kept for the wait's own timer), so a refused one always has room
/// to come back in.
const max_changes = max_events - 1;

const darwin = builtin.os.tag.isDarwin();
const Event = if (darwin) c.kevent64_s else c.Kevent;
const has_user = @hasDecl(c.EVFILT, "USER");
/// Events of these keys are reactor's own, never a record's.
const ignore_key: u64 = std.math.maxInt(u64);
const wake_key: u64 = std.math.maxInt(u64) - 1;
/// `EVFILT_TIMER` identifiers of the two clocks, and of a wait's timeout.
const clock_ident = [2]usize{ 1, 2 };
const wait_ident: usize = 3;
const absolute: ?u32 = if (@hasDecl(c.NOTE, "ABSOLUTE")) c.NOTE.ABSOLUTE else if (@hasDecl(c.NOTE, "ABSTIME")) c.NOTE.ABSTIME else null;
const continuous: u32 = if (@hasDecl(c.NOTE, "MACH_CONTINUOUS_TIME")) c.NOTE.MACH_CONTINUOUS_TIME else 0;
/// Darwin: a timer the system fires on time rather than coalesced.
const critical: u32 = if (@hasDecl(c.NOTE, "CRITICAL")) c.NOTE.CRITICAL else 0;

kq: posix.fd_t,
changes: [max_events]Event = undefined,
change_count: usize = 0,
wake_pending: std.atomic.Value(bool) = .init(false),
/// Where the system has no `EVFILT_USER`: a pipe the waker writes.
wake_pipe: if (has_user) void else [2]posix.fd_t,
clock_armed: [2]bool = .{ false, false },
/// Darwin: the wait timer is armed (it may fire after the wait it was for).
wait_armed: bool = false,
events: [max_events]Event = undefined,

fn change(ident: usize, filter: anytype, flags: anytype, fflags: u32, data: i64, udata: u64) Event {
    var e = std.mem.zeroes(Event);
    e.ident = ident;
    e.filter = @intCast(filter);
    e.flags = @intCast(flags);
    e.fflags = fflags;
    e.data = @intCast(data);
    e.udata = @intCast(udata);
    return e;
}

/// One call: `list` applied, events into `out`, waiting until `timeout`
/// (null: until an event); `immediate`: not at all.
fn call(kq: posix.fd_t, list: []const Event, out: []Event, immediate: bool, timeout: ?*const posix.timespec) isize {
    if (darwin) return c.kevent64(kq, list.ptr, @intCast(list.len), out.ptr, @intCast(out.len), .{ .IMMEDIATE = immediate }, timeout);
    const zero: posix.timespec = .{ .sec = 0, .nsec = 0 };
    return c.kevent(kq, list.ptr, @intCast(list.len), out.ptr, @intCast(out.len), if (immediate) &zero else timeout);
}

pub fn init() readiness.InitError!Kqueue {
    const rc = c.kqueue();
    if (posix.errno(rc) != .SUCCESS) return switch (posix.errno(rc)) {
        .MFILE, .NFILE, .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
    const kq: posix.fd_t = rc;
    errdefer _ = c.close(kq);
    // Not inherited across exec.
    if (posix.errno(c.fcntl(kq, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC))) != .SUCCESS) return error.Unexpected;
    var k: Kqueue = .{ .kq = kq, .wake_pipe = undefined };
    if (has_user) {
        const add = [1]Event{change(0, c.EVFILT.USER, c.EV.ADD | c.EV.CLEAR, 0, 0, wake_key)};
        try k.apply(&add);
    } else {
        var fds: [2]posix.fd_t = undefined;
        if (posix.errno(c.pipe(&fds)) != .SUCCESS) return error.SystemResources;
        for (fds) |fd| {
            const flags = c.fcntl(fd, posix.F.GETFL, @as(c_int, 0));
            _ = c.fcntl(fd, posix.F.SETFL, flags | @as(c_int, 1 << @bitOffsetOf(posix.O, "NONBLOCK")));
            _ = c.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
        }
        k.wake_pipe = fds;
        const add = [1]Event{change(@intCast(fds[0]), c.EVFILT.READ, c.EV.ADD | c.EV.CLEAR, 0, 0, wake_key)};
        try k.apply(&add);
    }
    return k;
}

/// Makes `list` take effect now.
fn apply(k: *Kqueue, list: []const Event) readiness.InitError!void {
    var none: [0]Event = undefined;
    while (true) {
        const rc = call(k.kq, list, &none, true, null);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
}

pub fn deinit(k: *Kqueue) void {
    if (!has_user) for (k.wake_pipe) |fd| {
        _ = c.close(fd);
    };
    _ = c.close(k.kq);
    k.* = undefined;
}

fn queue(k: *Kqueue, e: Event) void {
    assert(k.change_count < max_changes);
    k.changes[k.change_count] = e;
    k.change_count += 1;
}

/// Whether the changelist lacks room for the changes one call may queue.
pub fn full(k: *const Kqueue) bool {
    return k.change_count + 2 > max_changes;
}

fn filterOf(direction: readiness.Direction) i32 {
    return switch (direction) {
        .read => c.EVFILT.READ,
        .write => c.EVFILT.WRITE,
    };
}

/// `fd` reports readiness `direction`'s way under `key`, from the next call.
pub fn register(k: *Kqueue, fd: posix.fd_t, key: u64, have: readiness.Directions, direction: readiness.Direction) readiness.RegisterError!readiness.Directions {
    k.queue(change(@intCast(fd), filterOf(direction), c.EV.ADD | c.EV.CLEAR, 0, 0, key));
    return have.with(switch (direction) {
        .read => .{ .read = true },
        .write => .{ .write = true },
    });
}

/// `fd` no longer reports readiness here. A descriptor about to close
/// leaves the kernel's lists by itself; only changes still queued for it
/// must go, lest the next call apply them to whatever takes its number.
pub fn deregister(k: *Kqueue, fd: posix.fd_t, have: readiness.Directions, leaving: readiness.Leaving) void {
    var kept: usize = 0;
    for (k.changes[0..k.change_count]) |e| {
        const ours = e.ident == @as(usize, @intCast(fd)) and (e.filter == c.EVFILT.READ or e.filter == c.EVFILT.WRITE) and e.udata != wake_key;
        if (ours) continue;
        k.changes[kept] = e;
        kept += 1;
    }
    k.change_count = kept;
    if (leaving == .closing) return;
    if (have.read) k.queue(change(@intCast(fd), c.EVFILT.READ, c.EV.DELETE, 0, 0, ignore_key));
    if (have.write) k.queue(change(@intCast(fd), c.EVFILT.WRITE, c.EV.DELETE, 0, 0, ignore_key));
}

/// Hands the kernel the queued changes and takes its events, waiting as
/// `wait` allows.
pub fn wait(k: *Kqueue, timeout: Wait) readiness.PollError![]const Event {
    var ts: posix.timespec = .{ .sec = 0, .nsec = 0 };
    var immediate = false;
    var limit: ?*const posix.timespec = null;
    switch (timeout) {
        .nowait => immediate = true,
        .forever => {},
        .ns => |ns| if (darwin) {
            // A timer that fires on time, instead of a coalesced timeout.
            k.changes[k.change_count] = change(wait_ident, c.EVFILT.TIMER, c.EV.ADD | c.EV.ONESHOT, c.NOTE.NSECONDS | critical, @intCast(@min(ns, std.math.maxInt(i64))), ignore_key);
            k.change_count += 1;
            k.wait_armed = true;
        } else {
            ts = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
            limit = &ts;
        },
    }
    if (darwin and k.wait_armed and timeout != .ns) {
        // An earlier wait's timer would wake a later wait for nothing.
        k.changes[k.change_count] = change(wait_ident, c.EVFILT.TIMER, c.EV.DELETE, 0, 0, ignore_key);
        k.change_count += 1;
        k.wait_armed = false;
    }
    const rc = call(k.kq, k.changes[0..k.change_count], &k.events, immediate, limit);
    // The changes are applied before any wait, so even an interrupted call
    // has taken them.
    k.change_count = 0;
    return switch (posix.errno(rc)) {
        .SUCCESS => k.events[0..@intCast(rc)],
        .INTR => k.events[0..0],
        .NOMEM => error.SystemResources,
        else => |e| posix.unexpectedErrno(e),
    };
}

pub fn decode(e: *const Event) readiness.Decoded {
    if (e.udata == ignore_key) return .ignore;
    if (e.udata == wake_key) return .wake;
    if (e.filter == c.EVFILT.TIMER) return .{ .clock = if (e.ident == clock_ident[0]) .real else .boot };
    const direction: readiness.Direction = if (e.filter == c.EVFILT.WRITE) .write else .read;
    if (e.flags & c.EV.ERROR != 0) {
        if (e.data == 0) return .ignore;
        return .{ .record = .{ .key = e.udata, .refused = direction } };
    }
    return .{
        .record = .{
            .key = e.udata,
            .read = direction == .read,
            .write = direction == .write,
            // A socket's or a pipe's read filter counts the bytes there; at
            // its end the count says nothing of what a read returns.
            .available = if (direction == .read and e.flags & c.EV.EOF == 0 and e.data > 0) @intCast(e.data) else null,
        },
    };
}

/// From any thread: the next (or a waiting) call returns a wake event.
pub fn wake(k: *Kqueue) void {
    if (k.wake_pending.swap(true, .acq_rel)) return;
    if (has_user) {
        const trigger = [1]Event{change(0, c.EVFILT.USER, 0, c.NOTE.TRIGGER, 0, wake_key)};
        // A kqueue that cannot take the trigger has no room left: the
        // waiter wakes at its next event or deadline instead.
        k.apply(&trigger) catch |err| switch (err) {
            error.SystemResources, error.Unexpected, error.OutOfMemory, error.BackendUnavailable => {},
        };
    } else {
        const one = [1]u8{1};
        _ = c.write(k.wake_pipe[1], &one, 1);
    }
}

/// After a wake event: the next wake triggers again.
pub fn woken(k: *Kqueue) void {
    if (!has_user) {
        var buffer: [64]u8 = undefined;
        while (c.read(k.wake_pipe[0], &buffer, buffer.len) > 0) {}
    }
    k.wake_pending.store(false, .release);
}

pub fn handle(k: *const Kqueue) posix.fd_t {
    return k.kq;
}

/// `clock`'s one timer, armed for `deadline` (nanoseconds on that clock),
/// or disarmed.
pub fn armClock(k: *Kqueue, clock: readiness.Clock, deadline: ?i96) readiness.SubmitError!void {
    const i = @backingInt(clock);
    const ident = clock_ident[i];
    const at = deadline orelse {
        if (k.clock_armed[i]) k.queue(change(ident, c.EVFILT.TIMER, c.EV.DELETE, 0, 0, ignore_key));
        k.clock_armed[i] = false;
        return;
    };
    const fflags: u32, const data: i96 = switch (clock) {
        .real => if (absolute) |flag| .{ c.NOTE.NSECONDS | flag | critical, at } else .{ c.NOTE.NSECONDS | critical, at - now(.real) },
        // Relative, on a clock that counts across sleep where the system
        // has one: the boot clock's meaning.
        .boot => .{ c.NOTE.NSECONDS | continuous | critical, at - now(.boot) },
    };
    const clamped: i64 = @intCast(std.math.clamp(data, 0, std.math.maxInt(i64)));
    k.queue(change(ident, c.EVFILT.TIMER, c.EV.ADD | c.EV.ONESHOT, fflags, clamped, 0));
    k.clock_armed[i] = true;
}

/// A one-shot clock timer fired, and is gone.
pub fn clockFired(k: *Kqueue, clock: readiness.Clock) void {
    k.clock_armed[@backingInt(clock)] = false;
}

fn now(clock: readiness.Clock) i96 {
    const io_clock: std.Io.Clock = switch (clock) {
        .real => .real,
        .boot => .boot,
    };
    return io_clock.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
}
