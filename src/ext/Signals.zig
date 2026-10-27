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
const aegis = @import("aegis");
const posix = std.posix;
const Io = std.Io;
const windows = std.os.windows;

const Notify = @import("../sys/Notify.zig");
const win32 = @import("../sys/win32.zig");
const wait = @import("wait.zig");
const Wake = wait.Wake;

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
    var held = registry.acquireUncancelable(system());
    defer held.deinit(system());
    const l = for (&listeners) |*l| {
        if (!l.used) break l;
    } else return error.TooManyListeners;
    var set: Set = .empty;
    for (which) |s| set.insert(s);
    // Room in every signal's table before anything changes.
    var it = set.iterator();
    while (it.next()) |s| if (freeSlot(s) == null) return error.TooManyListeners;
    l.* = .{ .used = true, .notify = try .open(), .wanted = set };
    l.wake = .{ .notify = l.notify };
    it = set.iterator();
    while (it.next()) |s| {
        const first = count(s) == 0;
        table[@backingInt(s)][freeSlot(s).?].store(.of(l), .release);
        if (first) install(held.value(), s);
    }
    return .{ .listener = l };
}

/// Stops listening; a signal no listener wants any more gets its previous
/// handler back.
pub fn stop(s: *Signals, io: Io) void {
    const l = s.listener;
    {
        var held = registry.acquireUncancelable(system());
        defer held.deinit(system());
        var it = l.wanted.iterator();
        while (it.next()) |sig| {
            for (&table[@backingInt(sig)]) |*slot| if (slot.load(.acquire) == Slot.of(l)) slot.store(.none, .seq_cst);
            if (count(sig) == 0) uninstall(held.value(), sig);
        }
        // A handler running now may still hold `l`: wait for it to leave.
        // Sequentially consistent with the handler's count and load, so that
        // either it saw the slot empty or this sees it counted.
        while (!in_handler.load(.seq_cst).eql(.fromRaw(0))) std.atomic.spinLoopHint();
    }
    // Keep the record reserved while the close may yield.
    l.notify.close(io);
    var held = registry.acquireUncancelable(system());
    defer held.deinit(system());
    l.used = false;
    s.* = undefined;
}

/// The wake this listener's deliveries set, to wait on beside other members
/// of a `waitAny` set (`.wake`): when it reports, `next` with a zero timeout
/// takes what was delivered. Valid until `stop`.
pub fn wake(s: *const Signals) *Wake {
    return &s.listener.wake;
}

pub const NextError = error{ Timeout, Unexpected } || Io.Cancelable;

/// The next signal delivered since the last `next`, lowest first when
/// several were; waits until `timeout` for one.
pub fn next(s: *Signals, io: Io, timeout: Io.Timeout) NextError!Signal {
    const l = s.listener;
    const deadline = timeout.toDeadline(io);
    while (true) {
        if (l.take()) |sig| return sig;
        wait.wait(io, .{ .wake = &l.wake }, deadline) catch |err| return switch (err) {
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
    /// The same kernel object as a member of a wait; see `wake`.
    wake: Wake = undefined,
    wanted: Set = .empty,
    delivered: aegis.Atomic(Delivered) = .init(.none),

    fn take(l: *Listener) ?Signal {
        var bits = l.delivered.load(.acquire);
        while (bits.lowest()) |sig| {
            bits = l.delivered.cmpxchgWeak(bits, bits.without(sig), .acq_rel, .acquire) orelse return sig;
        }
        return null;
    }
};

/// The signals delivered to a listener and not yet taken, one bit each.
const Delivered = enum(u16) {
    none = 0,
    _,

    fn bit(s: Signal) u16 {
        return @as(u16, 1) << @backingInt(s);
    }

    fn with(d: Delivered, s: Signal) Delivered {
        return @fromBackingInt(@backingInt(d) | bit(s));
    }

    fn without(d: Delivered, s: Signal) Delivered {
        return @fromBackingInt(@backingInt(d) & ~bit(s));
    }

    fn lowest(d: Delivered) ?Signal {
        if (d == .none) return null;
        return @fromBackingInt(@as(u4, @intCast(@ctz(@backingInt(d)))));
    }
};

/// A slot of a signal's table: the listener's place in `listeners`, or none.
const Slot = enum(u8) {
    none = std.math.maxInt(u8),
    _,

    fn of(l: *const Listener) Slot {
        return @fromBackingInt(@intCast(l - &listeners[0]));
    }

    fn listener(s: Slot) ?*Listener {
        if (s == .none) return null;
        return &listeners[@backingInt(s)];
    }
};

/// Handlers running now.
const Running = aegis.units.Count(Listener, u32);

/// What only `start` and `stop` change, under the registry's lock.
const Registry = struct {
    console_handler: bool = false,
    previous: [signal_count]if (is_windows) void else posix.Sigaction = undefined,
};

// The process-wide table: written under the registry's lock, read by the
// handlers.

// aegis: boundary: the listeners a signal handler reaches, which may take no lock: each is reserved and released under the registry's lock, and a handler reads only its notifier and its delivered bits
var listeners: [max_listeners]Listener = @splat(.{});
// aegis: boundary: what a signal handler reads to find its listeners, which may take no lock: atomic slots, written under the registry's lock
var table: [signal_count][max_per_signal]aegis.Atomic(Slot) = @splat(@splat(.init(.none)));
var in_handler: aegis.Atomic(Running) = .init(.fromRaw(0));
var registry: aegis.BlockingGuarded(Registry) = .init(.{});

fn system() Io {
    return Io.Threaded.global_single_threaded.io();
}

fn freeSlot(s: Signal) ?usize {
    for (&table[@backingInt(s)], 0..) |*slot, i| if (slot.load(.acquire) == .none) return i;
    return null;
}

fn count(s: Signal) usize {
    var n: usize = 0;
    for (&table[@backingInt(s)]) |*slot| {
        if (slot.load(.acquire) != .none) n += 1;
    }
    return n;
}

/// Tells every listener of `s`. Runs in a signal handler or the console's
/// handler thread: atomics and one `write` per listener, nothing else.
fn deliver(s: Signal) bool {
    _ = in_handler.fetchAddWrapping(.fromRaw(1), .seq_cst);
    defer _ = in_handler.fetchSubWrapping(.fromRaw(1), .release);
    var told = false;
    for (&table[@backingInt(s)]) |*slot| if (slot.load(.seq_cst).listener()) |l| {
        var bits = l.delivered.load(.acquire);
        while (l.delivered.cmpxchgWeak(bits, bits.with(s), .acq_rel, .acquire)) |found| bits = found;
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

fn install(r: *Registry, s: Signal) void {
    if (is_windows) {
        if (!r.console_handler) {
            _ = win32.SetConsoleCtrlHandler(consoleHandler, .TRUE);
            r.console_handler = true;
        }
        return;
    }
    const action: posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(number(s).?, &action, &r.previous[@backingInt(s)]);
}

fn uninstall(r: *Registry, s: Signal) void {
    if (is_windows) {
        for (std.enums.values(Signal)) |other| if (count(other) != 0) return;
        _ = win32.SetConsoleCtrlHandler(consoleHandler, .FALSE);
        r.console_handler = false;
        return;
    }
    posix.sigaction(number(s).?, &r.previous[@backingInt(s)], null);
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
