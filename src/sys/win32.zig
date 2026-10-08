//! The Windows calls reactor's extensions make that std does not bind:
//! events, waits on several objects, a job object's completion port, the
//! console's control handler, and handle duplication.
const std = @import("std");
const windows = std.os.windows;

pub const wait_object_0: windows.DWORD = 0;
pub const wait_timeout: windows.DWORD = 258;
pub const wait_failed: windows.DWORD = 0xFFFF_FFFF;
pub const infinite: windows.DWORD = 0xFFFF_FFFF;
/// The most handles one `WaitForMultipleObjects` takes.
pub const maximum_wait_objects = 64;

pub extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*windows.SECURITY_ATTRIBUTES,
    bManualReset: windows.BOOL,
    bInitialState: windows.BOOL,
    lpName: ?windows.LPCWSTR,
) callconv(.winapi) ?windows.HANDLE;
pub extern "kernel32" fn SetEvent(hEvent: windows.HANDLE) callconv(.winapi) windows.BOOL;
pub extern "kernel32" fn ResetEvent(hEvent: windows.HANDLE) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn WaitForSingleObject(hHandle: windows.HANDLE, dwMilliseconds: windows.DWORD) callconv(.winapi) windows.DWORD;
pub extern "kernel32" fn WaitForMultipleObjects(
    nCount: windows.DWORD,
    lpHandles: [*]const windows.HANDLE,
    bWaitAll: windows.BOOL,
    dwMilliseconds: windows.DWORD,
) callconv(.winapi) windows.DWORD;

pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) windows.HANDLE;
pub const synchronize: windows.DWORD = 0x0010_0000;
pub extern "kernel32" fn DuplicateHandle(
    hSourceProcessHandle: windows.HANDLE,
    hSourceHandle: windows.HANDLE,
    hTargetProcessHandle: windows.HANDLE,
    lpTargetHandle: *windows.HANDLE,
    dwDesiredAccess: windows.DWORD,
    bInheritHandle: windows.BOOL,
    dwOptions: windows.DWORD,
) callconv(.winapi) windows.BOOL;

/// A port not attached to a file: `FileHandle` is `INVALID_HANDLE_VALUE`.
pub extern "kernel32" fn CreateIoCompletionPort(
    FileHandle: windows.HANDLE,
    ExistingCompletionPort: ?windows.HANDLE,
    CompletionKey: usize,
    NumberOfConcurrentThreads: windows.DWORD,
) callconv(.winapi) ?windows.HANDLE;

/// For a job's message, the byte count is the message, the key the one
/// the job was associated with, and the overlapped pointer a process id.
pub extern "kernel32" fn GetQueuedCompletionStatus(
    CompletionPort: windows.HANDLE,
    lpNumberOfBytesTransferred: *windows.DWORD,
    lpCompletionKey: *usize,
    lpOverlapped: *?*anyopaque,
    dwMilliseconds: windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn SetInformationJobObject(
    hJob: windows.HANDLE,
    JobObjectInformationClass: c_int,
    lpJobObjectInformation: *const anyopaque,
    cbJobObjectInformationLength: windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub const job_object_associate_completion_port_information: c_int = 7;

pub const JobObjectAssociateCompletionPort = extern struct {
    CompletionKey: ?*anyopaque,
    CompletionPort: ?windows.HANDLE,
};

/// `JOB_OBJECT_MSG_*`.
pub const job_msg = struct {
    pub const end_of_job_time: windows.DWORD = 1;
    pub const end_of_process_time: windows.DWORD = 2;
    pub const active_process_limit: windows.DWORD = 3;
    pub const active_process_zero: windows.DWORD = 4;
    pub const new_process: windows.DWORD = 6;
    pub const exit_process: windows.DWORD = 7;
    pub const abnormal_exit_process: windows.DWORD = 8;
    pub const process_memory_limit: windows.DWORD = 9;
    pub const job_memory_limit: windows.DWORD = 10;
};

pub extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;
pub const error_invalid_parameter: windows.DWORD = 87;
pub const error_access_denied: windows.DWORD = 5;

pub const HandlerRoutine = *const fn (dwCtrlType: windows.DWORD) callconv(.winapi) windows.BOOL;
pub extern "kernel32" fn SetConsoleCtrlHandler(HandlerRoutine: ?HandlerRoutine, Add: windows.BOOL) callconv(.winapi) windows.BOOL;

/// `CTRL_*_EVENT`.
pub const ctrl = struct {
    pub const c: windows.DWORD = 0;
    pub const @"break": windows.DWORD = 1;
    pub const close: windows.DWORD = 2;
    pub const logoff: windows.DWORD = 5;
    pub const shutdown: windows.DWORD = 6;
};

/// `IOCTL_AFD_POLL`'s argument, with one handle.
pub const AfdPollInfo = extern struct {
    Timeout: windows.LARGE_INTEGER,
    NumberOfHandles: windows.ULONG = 1,
    Exclusive: windows.ULONG = 0,
    Handles: [1]extern struct {
        Handle: windows.HANDLE,
        Events: windows.ULONG,
        Status: windows.NTSTATUS,
    },
};

/// `AFD_POLL_*` events.
pub const afd_poll = struct {
    pub const receive: windows.ULONG = 0x0001;
    pub const receive_expedited: windows.ULONG = 0x0002;
    pub const send: windows.ULONG = 0x0004;
    pub const disconnect: windows.ULONG = 0x0008;
    pub const abort: windows.ULONG = 0x0010;
    pub const local_close: windows.ULONG = 0x0020;
    pub const accept: windows.ULONG = 0x0080;
    pub const connect_fail: windows.ULONG = 0x0100;
};
