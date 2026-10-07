//! kqueue (macOS and the BSDs) as a readiness poller. Registrations are
//! `EV_CLEAR` (edge-triggered), one filter per direction as it is first
//! waited on, and ride the next `kevent` call in its changelist: they cost
//! no system call of their own. A refused registration comes back as an
//! `EV_ERROR` event, which the changelist's size never lets the event list
//! run out of room for. Wakes from other threads trigger an `EVFILT_USER`
//! event (a pipe where the system has none); `real` and `boot` timers are
//! one `EVFILT_TIMER` each, absolute where the system has absolute timers.
const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const c = std.c;

const readiness = @import("../readiness.zig");
const Wait = @import("../wait.zig").Wait;

const Kqueue = @This();

pub const name = "kqueue";
pub const max_events = 256;
/// Changes queued for the next call, never more than the event list holds,
/// so a refused one always has room to come back in.
const max_changes = max_events;

const has_user = @hasDecl(c.EVFILT, "USER");
/// c.Kevents of these keys are reactor's own, never a record's.
const ignore_key: usize = std.math.maxInt(usize);
const wake_key: usize = std.math.maxInt(usize) - 1;
/// `EVFILT_TIMER` identifiers of the two clocks.
const clock_ident = [2]usize{ 1, 2 };
const absolute: ?u32 = if (@hasDecl(c.NOTE, "ABSOLUTE")) c.NOTE.ABSOLUTE else if (@hasDecl(c.NOTE, "ABSTIME")) c.NOTE.ABSTIME else null;
const continuous: u32 = if (@hasDecl(c.NOTE, "MACH_CONTINUOUS_TIME")) c.NOTE.MACH_CONTINUOUS_TIME else 0;

kq: posix.fd_t,
changes: [max_changes]c.Kevent = undefined,
change_count: usize = 0,
wake_pending: std.atomic.Value(bool) = .init(false),
/// Where the system has no `EVFILT_USER`: a pipe the waker writes.
wake_pipe: if (has_user) void else [2]posix.fd_t,
clock_armed: [2]bool = .{ false, false },
events: [max_events]c.Kevent = undefined,

fn change(ident: usize, filter: anytype, flags: anytype, fflags: u32, data: i64, udata: usize) c.Kevent {
    var e = std.mem.zeroes(c.Kevent);
    e.ident = ident;
    e.filter = @intCast(filter);
    e.flags = @intCast(flags);
    e.fflags = fflags;
    e.data = @intCast(data);
    e.udata = udata;
    return e;
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
        const add = [1]c.Kevent{change(0, c.EVFILT.USER, c.EV.ADD | c.EV.CLEAR, 0, 0, wake_key)};
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
        const add = [1]c.Kevent{change(@intCast(fds[0]), c.EVFILT.READ, c.EV.ADD | c.EV.CLEAR, 0, 0, wake_key)};
        try k.apply(&add);
    }
    return k;
}

/// Makes `list` take effect now.
fn apply(k: *Kqueue, list: []const c.Kevent) readiness.InitError!void {
    const zero: posix.timespec = .{ .sec = 0, .nsec = 0 };
    var none: [0]c.Kevent = undefined;
    while (true) {
        const rc = c.kevent(k.kq, list.ptr, @intCast(list.len), &none, 0, &zero);
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

fn queue(k: *Kqueue, e: c.Kevent) void {
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
    k.queue(change(@intCast(fd), filterOf(direction), c.EV.ADD | c.EV.CLEAR, 0, 0, @intCast(key)));
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
pub fn wait(k: *Kqueue, timeout: Wait) readiness.PollError![]const c.Kevent {
    const events: []c.Kevent = &k.events;
    assert(events.len >= k.change_count);
    var ts: posix.timespec = .{ .sec = 0, .nsec = 0 };
    const ptr: ?*const posix.timespec = switch (timeout) {
        .nowait => &ts,
        .forever => null,
        .ns => |ns| blk: {
            ts = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
            break :blk &ts;
        },
    };
    const count = k.change_count;
    const rc = c.kevent(k.kq, &k.changes, @intCast(count), events.ptr, @intCast(events.len), ptr);
    // The changes are applied before any wait, so even an interrupted call
    // has taken them.
    k.change_count = 0;
    return switch (posix.errno(rc)) {
        .SUCCESS => events[0..@intCast(rc)],
        .INTR => events[0..0],
        .NOMEM => error.SystemResources,
        else => |e| posix.unexpectedErrno(e),
    };
}

pub fn decode(e: *const c.Kevent) readiness.Decoded {
    if (e.udata == ignore_key) return .ignore;
    if (e.udata == wake_key) return .wake;
    if (e.filter == c.EVFILT.TIMER) return .{ .clock = if (e.ident == clock_ident[0]) .real else .boot };
    const direction: readiness.Direction = if (e.filter == c.EVFILT.WRITE) .write else .read;
    if (e.flags & c.EV.ERROR != 0) {
        if (e.data == 0) return .ignore;
        return .{ .record = .{ .key = e.udata, .refused = direction } };
    }
    return .{ .record = .{ .key = e.udata, .read = direction == .read, .write = direction == .write } };
}

/// From any thread: the next (or a waiting) call returns a wake event.
pub fn wake(k: *Kqueue) void {
    if (k.wake_pending.swap(true, .acq_rel)) return;
    if (has_user) {
        const trigger = [1]c.Kevent{change(0, c.EVFILT.USER, 0, c.NOTE.TRIGGER, 0, wake_key)};
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
        .real => if (absolute) |flag| .{ c.NOTE.NSECONDS | flag, at } else .{ c.NOTE.NSECONDS, at - now(.real) },
        // Relative, on a clock that counts across sleep where the system
        // has one: the boot clock's meaning.
        .boot => .{ c.NOTE.NSECONDS | continuous, at - now(.boot) },
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
