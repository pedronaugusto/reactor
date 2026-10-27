//! The Windows calls a named pipe takes that std does not declare: the
//! client's open, a server instance's creation, a security descriptor
//! read from its SDDL text, and the control that waits for a client.
//! Every handle is opened for overlapped calls, so a runtime's port
//! finishes its reads and writes, and std's own calls wait on them.
const std = @import("std");
const windows = std.os.windows;

pub const generic_read: windows.DWORD = 0x8000_0000;
pub const generic_write: windows.DWORD = 0x4000_0000;
pub const open_existing: windows.DWORD = 3;
pub const file_flag_overlapped: windows.DWORD = 0x4000_0000;
pub const file_flag_first_pipe_instance: windows.DWORD = 0x0008_0000;
pub const pipe_access_duplex: windows.DWORD = 0x0000_0003;
pub const pipe_type_byte: windows.DWORD = 0x0000_0000;
pub const pipe_readmode_byte: windows.DWORD = 0x0000_0000;
pub const pipe_wait: windows.DWORD = 0x0000_0000;
/// Refuses clients from other machines: a named pipe is a local daemon's
/// door, as a Unix socket is.
pub const pipe_reject_remote_clients: windows.DWORD = 0x0000_0008;
pub const pipe_unlimited_instances: windows.DWORD = 255;
/// The SDDL revision `ConvertStringSecurityDescriptorToSecurityDescriptorW`
/// reads.
pub const sddl_revision_1: windows.DWORD = 1;

pub const error_file_not_found: windows.DWORD = 2;
pub const error_access_denied: windows.DWORD = 5;
pub const error_invalid_name: windows.DWORD = 123;
pub const error_pipe_busy: windows.DWORD = 231;
pub const error_bad_pathname: windows.DWORD = 161;
pub const error_invalid_parameter: windows.DWORD = 87;
pub const error_not_enough_memory: windows.DWORD = 8;

/// `FSCTL_PIPE_LISTEN`: a server instance waits for a client, overlapped
/// on a handle opened so; `PIPE_CONNECTED` when one came before the wait.
pub const fsctl_pipe_listen: windows.CTL_CODE = .{
    .DeviceType = .NAMED_PIPE,
    .Function = 2,
    .Method = .BUFFERED,
    .Access = .ANY,
};

/// `FSCTL_PIPE_DISCONNECT`: ends a server instance's client.
pub const fsctl_pipe_disconnect: windows.CTL_CODE = .{
    .DeviceType = .NAMED_PIPE,
    .Function = 1,
    .Method = .BUFFERED,
    .Access = .ANY,
};

// aegis: boundary: kernel32's CreateFileW, declared as Microsoft's Win32 documentation gives it
pub extern "kernel32" fn CreateFileW(
    lpFileName: windows.LPCWSTR,
    dwDesiredAccess: windows.DWORD,
    dwShareMode: windows.DWORD,
    lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES,
    dwCreationDisposition: windows.DWORD,
    dwFlagsAndAttributes: windows.DWORD,
    hTemplateFile: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;

// aegis: boundary: kernel32's CreateNamedPipeW, declared as Microsoft's Win32 documentation gives it
pub extern "kernel32" fn CreateNamedPipeW(
    lpName: windows.LPCWSTR,
    dwOpenMode: windows.DWORD,
    dwPipeMode: windows.DWORD,
    nMaxInstances: windows.DWORD,
    nOutBufferSize: windows.DWORD,
    nInBufferSize: windows.DWORD,
    nDefaultTimeOut: windows.DWORD,
    lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES,
) callconv(.winapi) windows.HANDLE;

// aegis: boundary: advapi32's ConvertStringSecurityDescriptorToSecurityDescriptorW, declared as Microsoft's Win32 documentation gives it
pub extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
    StringSecurityDescriptor: windows.LPCWSTR,
    StringSDRevision: windows.DWORD,
    SecurityDescriptor: *?*anyopaque,
    SecurityDescriptorSize: ?*windows.ULONG,
) callconv(.winapi) windows.BOOL;

// aegis: boundary: kernel32's LocalFree, declared as Microsoft's Win32 documentation gives it
pub extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
// aegis: boundary: kernel32's GetLastError, declared as Microsoft's Win32 documentation gives it
pub extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;
