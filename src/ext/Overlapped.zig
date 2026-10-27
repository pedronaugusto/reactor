//! One NT overlapped call a caller holds across waits, for a handle that
//! keeps a request outstanding (a directory's change notification, say):
//! started, waited on beside other members of a wait, and taken once it has
//! ended. Any `Io`: the call signals an event, which a runtime waits on with
//! a wait packet and any other `Io` on the calling thread. The event is the
//! call's own (`init`; a wait's `overlapped` member), or a `Wake`'s that
//! several calls signal (`signaling`; the wait is on the `Wake`, and `ended`
//! says which calls it was for), so a wait on any number of calls is a wait
//! on one member. Nothing is canceled at a wait's timeout, so nothing a read
//! brought in is lost to one; `cancel` asks the call to end, and it then
//! ends as any does, with what it completed with first if it did. Windows
//! only. Not moved while a call is outstanding: the kernel writes its status
//! block.
const Overlapped = @This();

const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;
const assert = std.debug.assert;
const win32 = @import("../sys/win32.zig");
const sys_windows = @import("../sys/windows.zig");

const is_windows = builtin.os.tag == .windows;

/// What an NT overlapped call is told to signal when it ends: pass
/// `event` as its `Event`, null as its APC routine, `context` as its APC
/// context, and `iosb` as its status block. On a runtime the context is
/// the runtime's and the event none, so its completion port hears of the
/// end; anywhere else the event is an `Overlapped`'s and the context
/// null, so no port does.
pub const Completion = struct {
    event: ?windows.HANDLE,
    context: ?*anyopaque,
};

/// What the call signals when it ends.
event: windows.HANDLE,
/// Whether `event` is this one's own, or a `Wake`'s.
owns_event: bool,
iosb: windows.IO_STATUS_BLOCK = undefined,
handle: windows.HANDLE = undefined,
outstanding: bool = false,

pub const InitError = error{SystemResources};

pub fn init() InitError!Overlapped {
    if (!is_windows) @compileError("an overlapped call is Windows'");
    const event = win32.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.SystemResources;
    return .{ .event = event, .owns_event = true };
}

/// One whose end signals `event`, as other calls' may: a `Wake`'s
/// (`Wake.handle`), so that a wait on the `Wake` reports that one or more
/// have ended, and clears it, after which `ended` says which. `event`
/// outlives it.
pub fn signaling(event: windows.HANDLE) Overlapped {
    if (!is_windows) @compileError("an overlapped call is Windows'");
    return .{ .event = event, .owns_event = false };
}

/// Once no call is outstanding.
pub fn deinit(o: *Overlapped) void {
    assert(!o.outstanding);
    if (o.owns_event) windows.CloseHandle(o.event);
    o.* = undefined;
}

/// Issues `start(context, &status block, completion)` on `handle`. The
/// status block when the call ended at once (it succeeded at once, or
/// failed); null while it is outstanding, until a wait reports it.
pub fn start(o: *Overlapped, comptime begin: anytype, handle: windows.HANDLE, context: anytype) ?windows.IO_STATUS_BLOCK {
    assert(!o.outstanding);
    // A `Wake`'s event is left as it is: other calls may have set it.
    if (o.owns_event) _ = win32.ResetEvent(o.event);
    o.iosb = .{ .u = .{ .Status = .PENDING }, .Information = 0 };
    o.handle = handle;
    const status: windows.NTSTATUS = begin(context, &o.iosb, Completion{ .event = o.event, .context = null });
    if (status == .PENDING) {
        o.outstanding = true;
        return null;
    }
    // An error: the call never started, and wrote no status block.
    if (@backingInt(status) >> 30 == 0b11) return .{ .u = .{ .Status = status }, .Information = 0 };
    // Success or a warning at once: the status block is written, and
    // the event set.
    return o.iosb;
}

/// Whether the outstanding call has ended, without waiting: the kernel
/// writes the status block before it signals the event.
pub fn ended(o: *const Overlapped) bool {
    if (!o.outstanding) return false;
    const status: *const u32 = @ptrCast(&o.iosb.u.Status); // aegis: boundary: an NTSTATUS is a u32, read whole as the kernel writes it
    // aegis: boundary: the kernel writes the status block as the call ends, so it is read atomically where it lies
    return @atomicLoad(u32, status, .acquire) != @backingInt(windows.NTSTATUS.PENDING);
}

/// What the call ended with, once `ended` says it has (a wait that reported
/// it says so). The handle may then take the next call.
pub fn take(o: *Overlapped) windows.IO_STATUS_BLOCK {
    assert(o.ended());
    o.outstanding = false;
    return o.iosb;
}

/// Asks the outstanding call to end. It then ends as any call does, soon:
/// with `CANCELLED`, or with what it completed with before the cancel
/// reached it, which `take` hands back. Until then it is outstanding, and
/// its buffers the kernel's.
pub fn cancel(o: *Overlapped) void {
    assert(o.outstanding);
    sys_windows.cancel(o.handle, &o.iosb);
}
