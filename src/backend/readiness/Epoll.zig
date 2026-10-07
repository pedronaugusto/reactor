//! epoll as a readiness poller. A descriptor is registered once, for both
//! directions and edge-triggered (`EPOLLET`), when it is first waited on;
//! a regular file or directory refuses (`EPERM`), and is then called in
//! place. Waits with a timeout use `epoll_pwait2`, exact to the
//! nanosecond, where the kernel has it (5.11), else whole milliseconds,
//! rounded up. Wakes from other threads write an eventfd; `real` and
//! `boot` timers are one absolute timerfd each.
const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const linux = std.os.linux;

const readiness = @import("../readiness.zig");
const Wait = @import("../wait.zig").Wait;

const Epoll = @This();

pub const name = "epoll";
pub const max_events = 256;

/// Events of these keys are reactor's own, never a record's.
const wake_key: u64 = std.math.maxInt(u64);
const clock_keys = [2]u64{ std.math.maxInt(u64) - 1, std.math.maxInt(u64) - 2 };
const clock_ids = [2]linux.timerfd_clockid_t{ .REALTIME, .BOOTTIME };
const timer_abstime: u32 = 1;
/// A realtime timer whose clock is set reports it, so the timers are
/// looked at again.
const timer_cancel_on_set: u32 = 2;

epfd: linux.fd_t,
wake_fd: linux.fd_t,
wake_pending: std.atomic.Value(bool) = .init(false),
/// One timerfd per clock, made when the clock's first timer is armed.
clock_fds: [2]?linux.fd_t = .{ null, null },
/// `epoll_pwait2` works here; cleared the first time it does not.
precise: bool = true,
events: [max_events]linux.epoll_event = undefined,

fn errno(rc: usize) linux.E {
    return linux.errno(rc);
}

pub fn init() readiness.InitError!Epoll {
    const rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    switch (errno(rc)) {
        .SUCCESS => {},
        .MFILE, .NFILE, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
    const epfd: linux.fd_t = @intCast(rc);
    errdefer _ = linux.close(epfd);
    const efd = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (errno(efd) != .SUCCESS) return error.SystemResources;
    const wake_fd: linux.fd_t = @intCast(efd);
    errdefer _ = linux.close(wake_fd);
    var event: linux.epoll_event = .{ .events = linux.EPOLL.IN, .data = .{ .u64 = wake_key } };
    if (errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, wake_fd, &event)) != .SUCCESS) return error.SystemResources;
    return .{ .epfd = epfd, .wake_fd = wake_fd };
}

pub fn deinit(e: *Epoll) void {
    for (e.clock_fds) |fd| if (fd) |f| {
        _ = linux.close(f);
    };
    _ = linux.close(e.wake_fd);
    _ = linux.close(e.epfd);
    e.* = undefined;
}

/// epoll applies every change at once: never full.
pub fn full(e: *const Epoll) bool {
    _ = e;
    return false;
}

/// `fd` reports readiness both ways under `key`, from now on.
pub fn register(e: *Epoll, fd: linux.fd_t, key: u64, have: readiness.Directions, direction: readiness.Direction) readiness.RegisterError!readiness.Directions {
    _ = direction;
    var event: linux.epoll_event = .{
        .events = linux.EPOLL.IN | linux.EPOLL.OUT | linux.EPOLL.RDHUP | linux.EPOLL.ET,
        .data = .{ .u64 = key },
    };
    // Registered both ways already: only the key changes (a record taken
    // again for a descriptor whose earlier registration still stands).
    const first: u32 = if (@as(u2, @bitCast(have)) == 0) linux.EPOLL.CTL_ADD else linux.EPOLL.CTL_MOD;
    var ctl = first;
    while (true) {
        switch (errno(linux.epoll_ctl(e.epfd, ctl, fd, &event))) {
            .SUCCESS => return .both,
            .EXIST => ctl = linux.EPOLL.CTL_MOD,
            .NOENT => ctl = linux.EPOLL.CTL_ADD,
            .PERM => return error.Unpollable,
            .NOMEM, .NOSPC => return error.SystemResources,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

/// `fd` no longer reports readiness here. Removed even when it is about
/// to close: a duplicate of it would keep the registration alive.
pub fn deregister(e: *Epoll, fd: linux.fd_t, have: readiness.Directions, leaving: readiness.Leaving) void {
    _ = leaving;
    if (@as(u2, @bitCast(have)) == 0) return;
    _ = linux.epoll_ctl(e.epfd, linux.EPOLL.CTL_DEL, fd, null);
}

/// Takes the kernel's events, waiting as `wait` allows.
pub fn wait(e: *Epoll, timeout: Wait) readiness.PollError![]const linux.epoll_event {
    const events: []linux.epoll_event = &e.events;
    const max: u32 = @intCast(events.len);
    const rc = switch (timeout) {
        .nowait => linux.epoll_wait(e.epfd, events.ptr, max, 0),
        .forever => linux.epoll_wait(e.epfd, events.ptr, max, -1),
        .ns => |ns| if (e.precise) blk: {
            const ts: linux.kernel_timespec = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
            const r = linux.syscall6(.epoll_pwait2, @as(u32, @bitCast(e.epfd)), @intFromPtr(events.ptr), max, @intFromPtr(&ts), 0, 8); // safe: the kernel reads the timespec during the call
            switch (errno(r)) {
                // Older kernels, and filters that do not know the call.
                .NOSYS, .PERM => {
                    e.precise = false;
                    return e.wait(timeout);
                },
                else => break :blk r,
            }
        } else linux.epoll_wait(e.epfd, events.ptr, max, @intCast(@min(std.math.divCeil(u64, ns, std.time.ns_per_ms) catch unreachable, std.math.maxInt(i32)))), // unreachable: the divisor is a constant
    };
    return switch (errno(rc)) {
        .SUCCESS => events[0..rc],
        .INTR => events[0..0],
        .NOMEM => error.SystemResources,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub fn decode(event: *const linux.epoll_event) readiness.Decoded {
    const key = event.data.u64;
    if (key == wake_key) return .wake;
    if (key == clock_keys[0]) return .{ .clock = .real };
    if (key == clock_keys[1]) return .{ .clock = .boot };
    const bits = event.events;
    const failed = bits & (linux.EPOLL.ERR | linux.EPOLL.HUP) != 0;
    return .{ .record = .{
        .key = key,
        .read = failed or bits & (linux.EPOLL.IN | linux.EPOLL.RDHUP | linux.EPOLL.PRI) != 0,
        .write = failed or bits & linux.EPOLL.OUT != 0,
    } };
}

/// From any thread: the next (or a waiting) call returns a wake event.
pub fn wake(e: *Epoll) void {
    if (e.wake_pending.swap(true, .acq_rel)) return;
    const one: u64 = 1;
    _ = linux.write(e.wake_fd, @ptrCast(&one), 8); // safe: eight bytes, as an eventfd is written
}

/// After a wake event: the next wake writes again.
pub fn woken(e: *Epoll) void {
    var count: u64 = 0;
    _ = linux.read(e.wake_fd, @ptrCast(&count), 8); // safe: eight bytes, as an eventfd reads
    e.wake_pending.store(false, .release);
}

pub fn handle(e: *const Epoll) linux.fd_t {
    return e.epfd;
}

/// `clock`'s one timer, armed for `deadline` (nanoseconds on that clock),
/// or disarmed.
pub fn armClock(e: *Epoll, clock: readiness.Clock, deadline: ?i96) readiness.SubmitError!void {
    const i = @backingInt(clock);
    const fd = e.clock_fds[i] orelse blk: {
        if (deadline == null) return;
        const rc = linux.timerfd_create(clock_ids[i], .{ .CLOEXEC = true, .NONBLOCK = true });
        if (errno(rc) != .SUCCESS) return error.SystemResources;
        const fd: linux.fd_t = @intCast(rc);
        var event: linux.epoll_event = .{ .events = linux.EPOLL.IN, .data = .{ .u64 = clock_keys[i] } };
        if (errno(linux.epoll_ctl(e.epfd, linux.EPOLL.CTL_ADD, fd, &event)) != .SUCCESS) {
            _ = linux.close(fd);
            return error.SystemResources;
        }
        e.clock_fds[i] = fd;
        break :blk fd;
    };
    const at: i96 = @max(deadline orelse 0, 0);
    // A deadline of zero disarms: one already past fires at the first
    // nanosecond instead.
    const value: i96 = if (deadline == null) 0 else @max(at, 1);
    const spec: linux.itimerspec = .{
        .it_interval = .{ .sec = 0, .nsec = 0 },
        .it_value = .{ .sec = @intCast(@divFloor(value, std.time.ns_per_s)), .nsec = @intCast(@mod(value, std.time.ns_per_s)) },
    };
    const flags: u32 = timer_abstime | if (clock == .real) timer_cancel_on_set else 0;
    switch (errno(linux.timerfd_settime(fd, @bitCast(flags), &spec, null))) {
        .SUCCESS, .CANCELED => {},
        else => return error.Unexpected,
    }
}

/// A clock's timer fired or its clock was set: reading it lets it fire
/// again.
pub fn clockFired(e: *Epoll, clock: readiness.Clock) void {
    const fd = e.clock_fds[@backingInt(clock)] orelse return;
    var count: u64 = 0;
    _ = linux.read(fd, @ptrCast(&count), 8); // safe: eight bytes, as a timerfd reads
}
