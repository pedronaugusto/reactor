//! Signals and console control events, delivered to every listener that
//! asked for them. What a signal means stays with its owner: `child` is
//! conduit's reaper's, `window_change` visor's.
//!
//! reactor installs a handler for a signal when its first listener starts
//! and puts the previous one back when its last stops. The handler marks
//! the signal in each listener's set and sets the listener's `Notify` (one
//! `write`, safe in a handler); `next` waits on that like any other
//! descriptor, so on a runtime it is a cancelation point that holds no
//! thread. On Windows the console's control handler does the same for
//! Ctrl+C, Ctrl+Break, closing the console, logoff and shutdown.
const Signals = @This();

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const Io = std.Io;
const windows = std.os.windows;

const Notify = @import("../sys/Notify.zig");
const win32 = @import("../sys/win32.zig");
const wait = @import("wait.zig");
const Wake = @import("Wake.zig");

const is_windows = builtin.os.tag == .windows;

pub const Signal = enum(u4) {
    /// SIGINT; Ctrl+C on Windows.
    interrupt,
    /// SIGTERM.
    terminate,
    /// SIGHUP.
    hangup,
    /// SIGQUIT; Ctrl+Break on Windows.
    quit,
    /// SIGUSR1.
    user1,
    /// SIGUSR2.
    user2,
    /// SIGWINCH.
    window_change,
    /// SIGCHLD.
    child,
    /// Windows: the console is closing.
    close,
    /// Windows: the user is logging off.
    logoff,
    /// Windows: the system is shutting down.
    shutdown,
};

const signal_count = @typeInfo(Signal).@"enum".field_names.len;

/// Listeners one signal tells at most.
pub const max_per_signal = 8;
/// Listeners alive at once, process-wide.
pub const max_listeners = 32;

/// The listener's place in the process-wide table; not to be touched.
listener: *Listener,

pub const StartError = error{ TooManyListeners, Unsupported } || Notify.OpenError;

/// A listener told of every delivery of each of `which`. Installs the
/// process-wide handlers on first use.
pub fn start(io: Io, which: []const Signal) StartError!Signals {
    _ = io;
    for (which) |s| if (number(s) == null) return error.Unsupported;
    lock();
    defer unlock();
    const l = for (&listeners) |*l| {
        if (!l.used) break l;
    } else return error.TooManyListeners;
    var set: Set = .empty;
    for (which) |s| set.insert(s);
    // Room in every signal's table before anything changes.
    var it = set.iterator();
    while (it.next()) |s| if (freeSlot(s) == null) return error.TooManyListeners;
    l.* = .{ .used = true, .notify = try .open(), .wanted = set };
    it = set.iterator();
    while (it.next()) |s| {
        const first = count(s) == 0;
        table[@backingInt(s)][freeSlot(s).?].store(l, .release);
        if (first) install(s);
    }
    return .{ .listener = l };
}

/// Stops listening; a signal no listener wants any more gets its previous
/// handler back.
pub fn stop(s: *Signals, io: Io) void {
    const l = s.listener;
    lock();
    var it = l.wanted.iterator();
    while (it.next()) |sig| {
        for (&table[@backingInt(sig)]) |*slot| if (slot.load(.acquire) == l) slot.store(null, .seq_cst);
        if (count(sig) == 0) uninstall(sig);
    }
    // A handler running now may still hold `l`: wait for it to leave.
    // Sequentially consistent with the handler's count and load, so that
    // either it saw the slot empty or this sees it counted.
    while (in_handler.load(.seq_cst) != 0) std.atomic.spinLoopHint();
    // Keep the record reserved while the close may yield.
    unlock();
    l.notify.close(io);
    lock();
    l.used = false;
    unlock();
    s.* = undefined;
}

pub const NextError = error{ Timeout, Unexpected } || Io.Cancelable;

/// The next signal delivered since the last `next`, lowest first when
/// several were; waits until `timeout` for one.
pub fn next(s: *Signals, io: Io, timeout: Io.Timeout) NextError!Signal {
    const l = s.listener;
    const deadline = timeout.toDeadline(io);
    while (true) {
        if (l.take()) |sig| return sig;
        var wake: Wake = .{ .notify = l.notify };
        wait.wait(io, .{ .wake = &wake }, deadline) catch |err| return switch (err) {
            error.Timeout => error.Timeout,
            error.Canceled => error.Canceled,
            error.Unsupported, error.Unexpected => error.Unexpected,
        };
    }
}

const Set = std.EnumSet(Signal);

/// One listener: the signals delivered and not yet taken, and the
/// `Notify` the handler sets.
const Listener = struct {
    used: bool = false,
    notify: Notify = undefined,
    wanted: Set = .empty,
    delivered: std.atomic.Value(u16) = .init(0),

    fn take(l: *Listener) ?Signal {
        var bits = l.delivered.load(.acquire);
        while (bits != 0) {
            const bit: u4 = @intCast(@ctz(bits));
            bits = l.delivered.cmpxchgWeak(bits, bits & ~(@as(u16, 1) << bit), .acq_rel, .acquire) orelse return @fromBackingInt(bit);
        }
        return null;
    }
};

// The process-wide table: written under `mutex`, read by the handlers.

var listeners: [max_listeners]Listener = @splat(.{});
var table: [signal_count][max_per_signal]std.atomic.Value(?*Listener) = @splat(@splat(.init(null)));
var previous: [signal_count]if (is_windows) void else posix.Sigaction = undefined;
var in_handler: std.atomic.Value(u32) = .init(0);
var console_handler = false;
var mutex: Io.Mutex = .init;

fn lock() void {
    mutex.lockUncancelable(Io.Threaded.global_single_threaded.io());
}

fn unlock() void {
    mutex.unlock(Io.Threaded.global_single_threaded.io());
}

fn freeSlot(s: Signal) ?usize {
    for (&table[@backingInt(s)], 0..) |*slot, i| if (slot.load(.acquire) == null) return i;
    return null;
}

fn count(s: Signal) usize {
    var n: usize = 0;
    for (&table[@backingInt(s)]) |*slot| {
        if (slot.load(.acquire) != null) n += 1;
    }
    return n;
}

/// Tells every listener of `s`. Runs in a signal handler or the console's
/// handler thread: atomics and one `write` per listener, nothing else.
fn deliver(s: Signal) bool {
    _ = in_handler.fetchAdd(1, .seq_cst);
    defer _ = in_handler.fetchSub(1, .release);
    var told = false;
    for (&table[@backingInt(s)]) |*slot| if (slot.load(.seq_cst)) |l| {
        _ = l.delivered.fetchOr(@as(u16, 1) << @backingInt(s), .acq_rel);
        l.notify.set();
        told = true;
    };
    return told;
}

// POSIX.

fn number(s: Signal) ?if (is_windows) windows.DWORD else posix.SIG {
    if (is_windows) return switch (s) {
        .interrupt => win32.ctrl.c,
        .quit => win32.ctrl.@"break",
        .close => win32.ctrl.close,
        .logoff => win32.ctrl.logoff,
        .shutdown => win32.ctrl.shutdown,
        else => null,
    };
    return switch (s) {
        .interrupt => .INT,
        .terminate => .TERM,
        .hangup => .HUP,
        .quit => .QUIT,
        .user1 => .USR1,
        .user2 => .USR2,
        .window_change => .WINCH,
        .child => .CHLD,
        .close, .logoff, .shutdown => null,
    };
}

fn install(s: Signal) void {
    if (is_windows) {
        if (!console_handler) {
            _ = win32.SetConsoleCtrlHandler(consoleHandler, .TRUE);
            console_handler = true;
        }
        return;
    }
    const action: posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(number(s).?, &action, &previous[@backingInt(s)]);
}

fn uninstall(s: Signal) void {
    if (is_windows) {
        for (std.enums.values(Signal)) |other| if (count(other) != 0) return;
        _ = win32.SetConsoleCtrlHandler(consoleHandler, .FALSE);
        console_handler = false;
        return;
    }
    posix.sigaction(number(s).?, &previous[@backingInt(s)], null);
}

fn handler(sig: posix.SIG) callconv(.c) void {
    // A `write` that fails sets errno, which the code the signal
    // interrupted may be about to read.
    const saved = if (builtin.link_libc) std.c._errno().* else 0;
    defer if (builtin.link_libc) {
        std.c._errno().* = saved;
    };
    const s: Signal = switch (sig) {
        .INT => .interrupt,
        .TERM => .terminate,
        .HUP => .hangup,
        .QUIT => .quit,
        .USR1 => .user1,
        .USR2 => .user2,
        .WINCH => .window_change,
        .CHLD => .child,
        else => return,
    };
    _ = deliver(s);
}

fn consoleHandler(kind: windows.DWORD) callconv(.winapi) windows.BOOL {
    const s: Signal = switch (kind) {
        win32.ctrl.c => .interrupt,
        win32.ctrl.@"break" => .quit,
        win32.ctrl.close => .close,
        win32.ctrl.logoff => .logoff,
        win32.ctrl.shutdown => .shutdown,
        else => return .FALSE,
    };
    // Handled when someone listened; else the next handler (the default
    // ends the process).
    return if (deliver(s)) .TRUE else .FALSE;
}
