//! The Windows calls reactor makes that std does not declare, and thin
//! wrappers over the ones it does: completion ports, a handle's binding to
//! a port, wait completion packets (a kernel object's signal delivered as
//! a port entry), waitable timers (high resolution where the system has
//! them), and cancelling a handle's I/O. The thread information block's
//! stack fields the fiber switch keeps are here too.
const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;
const Handle = windows.HANDLE;
const Status = windows.NTSTATUS;
const Boolean = windows.BOOLEAN;

/// One completion taken from a port: `FILE_IO_COMPLETION_INFORMATION`,
/// laid out as Win32's `OVERLAPPED_ENTRY`, so a host's
/// `GetQueuedCompletionStatusEx` entries are these.
pub const Entry = extern struct {
    /// The binding's or the poster's completion key.
    key: usize,
    /// The call's context: what reactor passes as the APC context.
    context: usize,
    iosb: windows.IO_STATUS_BLOCK,
};

const io_completion_all_access: u32 = 0x1f0003;
const timer_all_access: u32 = 0x1f0003;
const wait_packet_all_access: u32 = 0x1f0003;

const TimerType = enum(c_int) { notification = 0, synchronization = 1 };

extern "ntdll" fn NtCreateIoCompletion(handle: *Handle, access: u32, attributes: ?*anyopaque, threads: u32) callconv(.winapi) Status;
extern "ntdll" fn NtSetIoCompletion(port: Handle, key: usize, context: usize, status: Status, information: usize) callconv(.winapi) Status;
extern "ntdll" fn NtRemoveIoCompletionEx(port: Handle, entries: [*]Entry, count: u32, removed: *u32, timeout: ?*const i64, alertable: Boolean) callconv(.winapi) Status;
extern "ntdll" fn NtCreateWaitCompletionPacket(handle: *Handle, access: u32, attributes: ?*anyopaque) callconv(.winapi) Status;
extern "ntdll" fn NtAssociateWaitCompletionPacket(packet: Handle, port: Handle, target: Handle, key: usize, context: usize, status: Status, information: usize, already_signaled: ?*Boolean) callconv(.winapi) Status;
extern "ntdll" fn NtCancelWaitCompletionPacket(packet: Handle, remove_signaled: Boolean) callconv(.winapi) Status;
extern "ntdll" fn NtCreateTimer(handle: *Handle, access: u32, attributes: ?*anyopaque, kind: TimerType) callconv(.winapi) Status;
extern "ntdll" fn NtSetTimer(timer: Handle, due: *const i64, apc: ?*anyopaque, context: ?*anyopaque, resume_system: Boolean, period: i32, previous: ?*Boolean) callconv(.winapi) Status;
/// Windows 10 1803 and later: `flags` may ask for a high-resolution timer.
extern "kernel32" fn CreateWaitableTimerExW(attributes: ?*anyopaque, name: ?[*:0]const u16, flags: u32, access: u32) callconv(.winapi) ?Handle;

const create_waitable_timer_high_resolution: u32 = 0x2;

/// `NtCancelIoFileEx` with no request named: every request on the handle,
/// from any thread of the process. std declares the request non-null.
const cancel_all = @extern(*const fn (file: Handle, request: ?*const windows.IO_STATUS_BLOCK, iosb: *windows.IO_STATUS_BLOCK) callconv(.winapi) Status, .{ .name = "NtCancelIoFileEx", .library_name = "ntdll" });

pub const PortError = error{ SystemResources, Unexpected };

/// A completion port any number of threads may wait on.
pub fn createPort() PortError!Handle {
    var port: Handle = undefined;
    return switch (NtCreateIoCompletion(&port, io_completion_all_access, null, 0)) {
        .SUCCESS => port,
        .INSUFFICIENT_RESOURCES, .NO_MEMORY => error.SystemResources,
        else => |status| windows.unexpectedStatus(status),
    };
}

/// Queues an entry on `port`, from any thread.
pub fn post(port: Handle, key: usize, context: usize, status: Status, information: usize) PortError!void {
    return switch (NtSetIoCompletion(port, key, context, status, information)) {
        .SUCCESS => {},
        .INSUFFICIENT_RESOURCES, .NO_MEMORY => error.SystemResources,
        else => |s| windows.unexpectedStatus(s),
    };
}

/// How long `remove` waits: null for no limit, 0 for not at all, else a
/// relative time in 100 ns units (the system's timer resolution applies).
pub fn remove(port: Handle, entries: []Entry, wait_100ns: ?u64) PortError![]Entry {
    var removed: u32 = 0;
    const timeout: i64 = if (wait_100ns) |w| -@as(i64, @intCast(@min(w, std.math.maxInt(i63)))) else 0;
    const status = NtRemoveIoCompletionEx(port, entries.ptr, @intCast(@min(entries.len, std.math.maxInt(u32))), &removed, if (wait_100ns == null) null else &timeout, .FALSE);
    return switch (status) {
        .SUCCESS => entries[0..removed],
        .TIMEOUT, .USER_APC, .ALERTED => entries[0..0],
        .INSUFFICIENT_RESOURCES, .NO_MEMORY => error.SystemResources,
        else => windows.unexpectedStatus(status),
    };
}

/// A file's binding to a completion port (`FileCompletionInformation`).
const CompletionInformation = extern struct {
    port: ?Handle,
    key: usize,
};

pub const BindResult = enum {
    /// Bound now to the port given.
    bound,
    /// Bound to a port already: each handle is bound once, for its life.
    already,
    /// Not a handle opened for overlapped calls, or one that cannot skip
    /// the port on success.
    refused,
};

/// Binds `handle`'s completions to `port` under `key`, and has the system
/// queue no entry for a call that completes at once (nor signal the
/// handle). A handle bound already gets the same modes: a call that
/// completes at once is then finished by its caller, never by an entry.
pub fn bind(handle: Handle, port: Handle, key: usize) BindResult {
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    var info: CompletionInformation = .{ .port = port, .key = key };
    const result: BindResult = switch (windows.ntdll.NtSetInformationFile(handle, &iosb, &info, @sizeOf(CompletionInformation), .Completion)) {
        .SUCCESS => .bound,
        .INVALID_PARAMETER => .already,
        else => return .refused,
    };
    var modes: u32 = skip_completion_port_on_success | skip_set_event_on_handle;
    return switch (windows.ntdll.NtSetInformationFile(handle, &iosb, &modes, @sizeOf(u32), .IoCompletionNotification)) {
        .SUCCESS => result,
        else => .refused,
    };
}

/// `FILE_IO_COMPLETION_NOTIFICATION_INFORMATION`'s flags (a 32-bit word).
const skip_completion_port_on_success: u32 = 0x1;
const skip_set_event_on_handle: u32 = 0x2;

/// Asks the system to end the request whose status block is `iosb`, or
/// every request on `handle` when null. Requests end with
/// `STATUS_CANCELLED`, unless they completed first; either way their
/// entries still arrive.
pub fn cancel(handle: Handle, iosb: ?*const windows.IO_STATUS_BLOCK) void {
    var result: windows.IO_STATUS_BLOCK = undefined;
    // NOT_FOUND: nothing left to end, its entry is on the way.
    _ = cancel_all(handle, iosb, &result);
}

/// Closes `handle`, forgetting its binding first: the next handle to get
/// its number starts unbound.
pub fn close(handle: Handle) void {
    forget(handle);
    _ = windows.ntdll.NtClose(handle);
}

// What reactor knows of the process's bindings.

/// Handles bound to a port, as far as reactor knows: a cache in front of
/// `bind`, so a handle costs one bind call for its life. A binding is the
/// process's (the kernel keeps one per handle, whatever thread made it),
/// so this is too. Direct-mapped: a handle another displaced is bound
/// again, and finds itself bound already. An entry goes when reactor
/// closes the handle (`close`, `forget`); a handle reactor bound must be
/// closed through reactor, or its number, reused, would look bound.
var bound: [1 << 14]std.atomic.Value(usize) = @splat(.init(0));

fn slotOf(handle: Handle) *std.atomic.Value(usize) {
    const value = @intFromPtr(handle); // safe: a handle's number, hashed
    return &bound[(value >> 2) & (bound.len - 1)];
}

/// `bind` once per handle: whether `handle` is bound to a port (this one,
/// or one bound before), with the port skipped on success.
pub fn bindOnce(handle: Handle, port: Handle, key: usize) bool {
    const slot = slotOf(handle);
    const value = @intFromPtr(handle); // safe: a handle's number, compared
    if (slot.load(.acquire) == value) return true;
    switch (bind(handle, port, key)) {
        .bound, .already => {
            slot.store(value, .release);
            return true;
        },
        .refused => return false,
    }
}

/// `handle` is going away: drops what reactor knew of its binding.
pub fn forget(handle: Handle) void {
    const value = @intFromPtr(handle); // safe: a handle's number, compared
    _ = slotOf(handle).cmpxchgStrong(value, 0, .acq_rel, .monotonic);
}

// Wait completion packets.

/// A packet that turns a kernel object's signal into a port entry.
pub fn createWaitPacket() PortError!Handle {
    var packet: Handle = undefined;
    return switch (NtCreateWaitCompletionPacket(&packet, wait_packet_all_access, null)) {
        .SUCCESS => packet,
        .INSUFFICIENT_RESOURCES, .NO_MEMORY => error.SystemResources,
        else => |status| windows.unexpectedStatus(status),
    };
}

pub const ArmError = error{ SystemResources, Unexpected };

/// Queues `context` on `port` under `key` once `target` is signaled; at
/// once when it already is. One entry per association.
pub fn armWaitPacket(packet: Handle, port: Handle, target: Handle, key: usize, context: usize) ArmError!void {
    return switch (NtAssociateWaitCompletionPacket(packet, port, target, key, context, .SUCCESS, 0, null)) {
        .SUCCESS => {},
        .INSUFFICIENT_RESOURCES, .NO_MEMORY => error.SystemResources,
        else => |status| windows.unexpectedStatus(status),
    };
}

pub const Disarmed = enum {
    /// No entry will arrive: the wait was pending, or its entry was taken
    /// back from the port.
    removed,
    /// The association ended with its entry taken from the port already.
    delivered,
    /// The entry is being queued, and arrives.
    arriving,
};

pub fn disarmWaitPacket(packet: Handle) Disarmed {
    return switch (NtCancelWaitCompletionPacket(packet, .TRUE)) {
        .SUCCESS => .removed,
        .PENDING => .arriving,
        else => .delivered,
    };
}

// Waitable timers.

pub const TimerError = error{ SystemResources, Unexpected };

/// A timer that resets as a wait takes its signal. High resolution where
/// the system has them (Windows 10 1803 and later); else the system tick's.
pub fn createTimer() TimerError!struct { Handle, bool } {
    if (CreateWaitableTimerExW(null, null, create_waitable_timer_high_resolution, timer_all_access)) |timer| return .{ timer, true };
    var timer: Handle = undefined;
    return switch (NtCreateTimer(&timer, timer_all_access, null, .synchronization)) {
        .SUCCESS => .{ timer, false },
        .INSUFFICIENT_RESOURCES, .NO_MEMORY => error.SystemResources,
        else => |status| windows.unexpectedStatus(status),
    };
}

/// Arms `timer` for `due`: a negative count of 100 ns units from now, or a
/// positive system time (100 ns since 1601), which follows clock changes.
pub fn setTimer(timer: Handle, due: i64) TimerError!void {
    return switch (NtSetTimer(timer, &due, null, null, .FALSE, 0, null)) {
        .SUCCESS, .TIMER_RESUME_IGNORED => {},
        .INSUFFICIENT_RESOURCES, .NO_MEMORY => error.SystemResources,
        else => |status| windows.unexpectedStatus(status),
    };
}

// The thread information block.

/// The stack fields of the thread information block a fiber switch keeps
/// right: Windows grows a stack by its guard page only inside these bounds,
/// and stack walks stop at them.
pub const StackBounds = extern struct {
    /// One past the highest byte.
    base: usize,
    /// The lowest committed byte.
    limit: usize,
    /// The lowest reserved byte (`DeallocationStack`).
    deallocation: usize,
};

/// `DeallocationStack`'s offset in a 64-bit TEB (x86-64 and AArch64).
const deallocation_stack_offset = 0x1478;

pub fn stackBounds() StackBounds {
    const teb = windows.teb();
    const deallocation: *usize = @ptrFromInt(@intFromPtr(teb) + deallocation_stack_offset); // safe: a field of the TEB std does not name
    return .{ .base = @intFromPtr(teb.NtTib.StackBase), .limit = @intFromPtr(teb.NtTib.StackLimit), .deallocation = deallocation.* }; // safe: addresses, kept as integers
}

pub fn setStackBounds(b: StackBounds) void {
    const teb = windows.teb();
    const deallocation: *usize = @ptrFromInt(@intFromPtr(teb) + deallocation_stack_offset); // safe: a field of the TEB std does not name
    teb.NtTib.StackBase = @ptrFromInt(b.base);
    teb.NtTib.StackLimit = @ptrFromInt(b.limit);
    deallocation.* = b.deallocation;
}

comptime {
    if (builtin.os.tag == .windows) std.debug.assert(@sizeOf(Entry) == 32);
}
