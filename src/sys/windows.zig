//! The Windows calls reactor makes that std does not declare: completion
//! ports, wait completion packets that tie a kernel object's signal to a
//! port, waitable timers (high resolution where the system has them), a
//! file's port binding, and AFD's readiness poll. The thread information
//! block's stack fields the fiber switch keeps are here too.
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

pub const io_completion_all_access: u32 = 0x1f0003;
pub const timer_all_access: u32 = 0x1f0003;
pub const generic_all: u32 = 0x10000000;

pub const TimerType = enum(c_int) { notification = 0, synchronization = 1 };

pub extern "ntdll" fn NtCreateIoCompletion(handle: *Handle, access: u32, attributes: ?*anyopaque, threads: u32) callconv(.winapi) Status;
pub extern "ntdll" fn NtSetIoCompletion(port: Handle, key: usize, context: usize, status: Status, information: usize) callconv(.winapi) Status;
pub extern "ntdll" fn NtRemoveIoCompletionEx(port: Handle, entries: [*]Entry, count: u32, removed: *u32, timeout: ?*const i64, alertable: Boolean) callconv(.winapi) Status;
pub extern "ntdll" fn NtCreateWaitCompletionPacket(handle: *Handle, access: u32, attributes: ?*anyopaque) callconv(.winapi) Status;
pub extern "ntdll" fn NtAssociateWaitCompletionPacket(packet: Handle, port: Handle, target: Handle, key: usize, context: usize, status: Status, information: usize, already_signaled: ?*Boolean) callconv(.winapi) Status;
pub extern "ntdll" fn NtCancelWaitCompletionPacket(packet: Handle, remove_signaled: Boolean) callconv(.winapi) Status;
pub extern "ntdll" fn NtCreateTimer(handle: *Handle, access: u32, attributes: ?*anyopaque, kind: TimerType) callconv(.winapi) Status;
pub extern "ntdll" fn NtSetTimer(timer: Handle, due: *const i64, apc: ?*anyopaque, context: ?*anyopaque, resume_system: Boolean, period: i32, previous: ?*Boolean) callconv(.winapi) Status;
/// Windows 10 1803 and later: `flags` may ask for a high-resolution timer.
pub extern "kernel32" fn CreateWaitableTimerExW(attributes: ?*anyopaque, name: ?[*:0]const u16, flags: u32, access: u32) callconv(.winapi) ?Handle;

pub const create_waitable_timer_high_resolution: u32 = 0x2;

/// A file's binding to a completion port (`FileCompletionInformation`,
/// `FileReplaceCompletionInformation`).
pub const CompletionInformation = extern struct {
    port: ?Handle,
    key: usize,
};

/// `FileIoCompletionNotificationInformation`'s flags.
pub const skip_completion_port_on_success: u32 = 0x1;
pub const skip_set_event_on_handle: u32 = 0x2;

/// AFD's readiness events.
pub const poll = struct {
    pub const receive: u32 = 0x0001;
    pub const receive_expedited: u32 = 0x0002;
    pub const send: u32 = 0x0004;
    pub const disconnect: u32 = 0x0008;
    pub const abort: u32 = 0x0010;
    pub const local_close: u32 = 0x0020;
    pub const accept: u32 = 0x0080;
    pub const connect_fail: u32 = 0x0100;
};

pub const PollHandle = extern struct {
    handle: Handle,
    events: u32,
    status: Status,
};

/// `AFD_POLL_INFO` for one socket.
pub const PollInfo = extern struct {
    timeout: i64,
    count: u32,
    exclusive: u32,
    handles: [1]PollHandle,
};

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
