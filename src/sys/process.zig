//! A descriptor that becomes readable when a child process ends, without
//! reaping it: a pidfd on Linux, a kqueue holding one `EVFILT_PROC`
//! `NOTE_EXIT` registration on Darwin and the BSDs. Where there is
//! neither, or the kernel refuses a zombie (Darwin answers `ESRCH`),
//! `waitid` with `WNOWAIT` says whether the child has ended, leaving it
//! unreaped. Windows' process handles are waitable as they are.
const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const c = std.c;
const Io = std.Io;

const os = builtin.os.tag;

pub const Watch = union(enum) {
    /// Readable once the process has ended.
    descriptor: Io.File.Handle,
    /// It had ended when the watch was opened.
    ended,
    /// This system has no descriptor for it: ask `endedUnreaped`.
    asking,
};

pub const OpenError = error{ ProcessNotFound, SystemResources, Unexpected };

const is_bsd = switch (os) {
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos, .dragonfly, .freebsd, .netbsd, .openbsd => true,
    else => false,
};

/// A watch on `pid`, a child of this process that nobody has reaped yet.
pub fn open(pid: posix.pid_t) OpenError!Watch {
    if (os == .linux) {
        const linux = std.os.linux;
        const rc = linux.pidfd_open(pid, 0);
        return switch (linux.errno(rc)) {
            .SUCCESS => .{ .descriptor = @intCast(rc) },
            .SRCH => error.ProcessNotFound,
            .MFILE, .NFILE, .NOMEM, .NODEV => error.SystemResources,
            // Before 5.3.
            .NOSYS => asked(pid),
            else => |e| posix.unexpectedErrno(e),
        };
    }
    if (is_bsd) {
        const queue = c.kqueue();
        if (queue < 0) return error.SystemResources;
        var change = [_]c.Kevent{.{
            .ident = @intCast(pid),
            .filter = c.EVFILT.PROC,
            .flags = c.EV.ADD | c.EV.ENABLE | c.EV.ONESHOT,
            .fflags = c.NOTE.EXIT,
            .data = 0,
            .udata = 0,
        }};
        var nothing: [0]c.Kevent = undefined;
        const zero: c.timespec = .{ .sec = 0, .nsec = 0 };
        if (c.kevent(queue, &change, 1, &nothing, 0, &zero) < 0) {
            _ = c.close(queue);
            // A zombie is refused with ESRCH: ask whether it ended.
            return asked(pid);
        }
        return .{ .descriptor = queue };
    }
    return asked(pid);
}

fn asked(pid: posix.pid_t) OpenError!Watch {
    return switch (endedUnreaped(pid)) {
        .ended => .ended,
        .running => .asking,
        .unknown => error.ProcessNotFound,
    };
}

pub fn close(w: Watch, io: std.Io) void {
    switch (w) {
        .descriptor => |fd| {
            const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
            file.close(io);
        },
        .ended, .asking => {},
    }
}

/// Whether a child of this process has ended, asked without reaping it.
pub const Ended = enum { ended, running, unknown };

/// `waitid` with `WNOWAIT`, so the child stays unreaped and its pid stays
/// its own. Never blocks.
pub fn endedUnreaped(pid: posix.pid_t) Ended {
    if (os == .linux) {
        const linux = std.os.linux;
        while (true) {
            var info: linux.siginfo_t = std.mem.zeroes(linux.siginfo_t);
            const rc = linux.waitid(.PID, pid, &info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT, null);
            switch (linux.errno(rc)) {
                // With `WNOHANG` and nothing to report, the pid stays zero.
                .SUCCESS => return if (info.fields.common.first.piduid.pid == 0) .running else .ended,
                .INTR => continue,
                else => return .unknown,
            }
        }
    }
    if (!builtin.link_libc) return .unknown;
    const flags = waitid_flags orelse return .unknown;
    while (true) {
        var info = std.mem.zeroes(c.siginfo_t);
        if (waitid(p_pid, @intCast(pid), &info, flags) == 0) return if (infoPid(&info) == 0) .running else .ended;
        switch (posix.errno(@as(c_int, -1))) {
            .INTR => continue,
            else => return .unknown,
        }
    }
}

/// P_PID and id_t are ABI choices: FreeBSD and DragonFly use Solaris's
/// selector and a 64-bit id_t; OpenBSD puts P_PID after P_ALL and P_PGID.
const p_pid: c_uint = switch (os) {
    .freebsd, .dragonfly, .illumos => 0,
    .openbsd => 2,
    else => 1,
};
const WaitId = switch (os) {
    .freebsd, .dragonfly => i64,
    .illumos => i32,
    else => c_uint,
};

/// `WEXITED | WNOHANG | WNOWAIT`, spelled per system where it is known.
const waitid_flags: ?c_int = switch (os) {
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => 0x4 | 0x1 | 0x20,
    .freebsd, .netbsd, .dragonfly, .illumos => c.W.EXITED | c.W.NOHANG | c.W.NOWAIT,
    .openbsd => 0x4 | 0x1 | 0x10,
    else => null,
};

extern "c" fn waitid(idtype: c_uint, id: WaitId, info: *c.siginfo_t, options: c_int) c_int;

fn infoPid(info: *const c.siginfo_t) posix.pid_t {
    return switch (os) {
        .netbsd => info.info.reason.child.pid,
        .illumos => info.reason.proc.pid,
        .openbsd => info.data.proc.pid,
        else => info.pid,
    };
}
