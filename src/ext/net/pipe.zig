//! Windows named pipes, a local daemon's door as a Unix socket is
//! elsewhere (Docker's `\\.\pipe\docker_engine`): a client's connect and a
//! server's listener, on any `Io`. Every handle is opened for overlapped
//! calls, an `Io.File` with `nonblocking` set: a runtime finishes its reads
//! and writes on its port, and std waits on them itself. Go's winio
//! (`DialPipe`, `ListenPipe`) is the model. Off Windows each call says
//! `NamedPipeUnsupported`.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const windows = std.os.windows;

const native = @import("../native.zig");
const pipe_windows = @import("../../sys/pipe_windows.zig");

/// Whether this system has named pipes.
pub const supported = builtin.os.tag == .windows;

/// The longest pipe path taken, in UTF-16 code units: the system's limit
/// on a pipe's name is 256 after its `\\.\pipe\`.
pub const max_path = 268;

/// How long a connect waits before it tries a busy pipe again: every
/// instance was taken, and a free one is made when the server accepts.
const busy_retry: Io.Duration = .fromMilliseconds(10);

pub const ConnectOptions = struct {
    /// How long a busy pipe is waited for; `.none` waits until an instance
    /// is free or the task is canceled.
    timeout: Io.Timeout = .none,
};

pub const ConnectError = Io.Cancelable || error{
    /// Not Windows.
    NamedPipeUnsupported,
    /// Not `\\<host>\pipe\<name>`, or longer than `max_path`.
    InvalidPipeName,
    /// No server has made the pipe.
    FileNotFound,
    /// The pipe's security descriptor refuses this process.
    AccessDenied,
    /// Every instance stayed busy until the timeout.
    Timeout,
    Unexpected,
};

/// A client's end of the pipe at `path`, `\\.\pipe\<name>`: an `Io.File`
/// opened for overlapped reads and writes, the caller's to close. A busy
/// pipe is tried again until `options.timeout`.
pub fn connectPipe(io: Io, path: []const u8, options: ConnectOptions) ConnectError!Io.File {
    return if (supported) connectWindows(io, path, options) else error.NamedPipeUnsupported;
}

fn connectWindows(io: Io, path: []const u8, options: ConnectOptions) ConnectError!Io.File {
    var buffer: [max_path:0]u16 = undefined;
    const name = try pipeName(path, &buffer);
    const deadline = options.timeout.toTimestamp(io);
    while (true) {
        try io.checkCancel();
        const handle = pipe_windows.CreateFileW(name, pipe_windows.generic_read | pipe_windows.generic_write, 0, null, pipe_windows.open_existing, pipe_windows.file_flag_overlapped, null);
        if (handle != windows.INVALID_HANDLE_VALUE) return .{ .handle = handle, .flags = .{ .nonblocking = true } };
        switch (pipe_windows.GetLastError()) {
            pipe_windows.error_pipe_busy => {
                var wait = busy_retry;
                if (deadline) |d| {
                    const left = Io.Clock.Timestamp.now(io, d.clock).durationTo(d);
                    if (left.raw.nanoseconds <= 0) return error.Timeout;
                    wait = .fromNanoseconds(@min(wait.nanoseconds, left.raw.nanoseconds));
                }
                try io.sleep(wait, .awake);
            },
            pipe_windows.error_file_not_found => return error.FileNotFound,
            pipe_windows.error_access_denied => return error.AccessDenied,
            pipe_windows.error_invalid_name, pipe_windows.error_bad_pathname => return error.InvalidPipeName,
            else => return error.Unexpected,
        }
    }
}

/// Who may open a pipe a server makes. There is no default: a pipe is a
/// door into the server, and the caller says who it is for.
pub const Security = union(enum) {
    /// A security descriptor in SDDL, as Docker's daemon gives its pipe
    /// (`D:P(A;;GA;;;BA)(A;;GA;;;SY)`: administrators and the system).
    sddl: []const u8,
    /// The creating token's default DACL, the system's choice when none
    /// is named: said out loud here.
    token_default,
};

pub const ListenOptions = struct {
    security: Security,
    /// Each instance's buffers, in and out: what a write may hand over
    /// before the other end reads.
    buffer_size: u32 = 64 * 1024,
};

pub const ListenError = error{
    NamedPipeUnsupported,
    InvalidPipeName,
    /// SDDL the system does not read.
    InvalidSecurityDescriptor,
    /// Another server has made the pipe.
    AddressInUse,
    AccessDenied,
    SystemResources,
    Unexpected,
};

pub const AcceptError = Io.Cancelable || error{
    SystemResources,
    Unexpected,
};

/// A server's pipe: one instance waiting for a client at a time, a fresh
/// one made as each client is accepted, so a client that comes between
/// accepts finds one. Not moved while an accept is under way.
pub const PipeListener = struct {
    name: [max_path:0]u16,
    name_len: usize,
    /// The security descriptor `LocalAlloc` made from the SDDL, freed at
    /// `deinit`; null for the token's default.
    descriptor: ?*anyopaque,
    buffer_size: u32,
    /// The instance the next client connects to; null when making it
    /// failed after the last accept, and the next accept makes it.
    next: ?Io.File,

    /// The next client: its instance, connected, an `Io.File` the caller
    /// closes. A canceled accept leaves the instance waiting for the next.
    pub fn accept(l: *PipeListener, io: Io) AcceptError!Io.File {
        if (supported) return l.acceptWindows(io) else unreachable; // unreachable: a listener is made on Windows alone
    }

    fn acceptWindows(l: *PipeListener, io: Io) AcceptError!Io.File {
        const waiting = l.next orelse l.instance(false) catch |err| return switch (err) {
            error.SystemResources => error.SystemResources,
            else => error.Unexpected,
        };
        l.next = waiting;
        const result = try io.operate(.{ .device_io_control = .{ .file = waiting, .code = pipe_windows.fsctl_pipe_listen } });
        switch (result.device_io_control.u.Status) {
            // A client came during the wait, or before it.
            .SUCCESS, .PIPE_CONNECTED => {},
            .INSUFFICIENT_RESOURCES, .NO_MEMORY => return error.SystemResources,
            else => return error.Unexpected,
        }
        // The next client's instance; one not made now is made by the
        // next accept, and this client is served regardless.
        l.next = l.instance(false) catch null;
        return waiting;
    }

    pub fn deinit(l: *PipeListener, io: Io) void {
        if (l.next) |file| file.close(io);
        if (supported) if (l.descriptor) |d| {
            _ = pipe_windows.LocalFree(d);
        };
        l.* = undefined;
    }

    fn instance(l: *PipeListener, first: bool) ListenError!Io.File {
        var attributes: windows.SECURITY_ATTRIBUTES = .{
            .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = l.descriptor,
            .bInheritHandle = .FALSE,
        };
        const open_mode = pipe_windows.pipe_access_duplex | pipe_windows.file_flag_overlapped |
            (if (first) pipe_windows.file_flag_first_pipe_instance else 0);
        const pipe_mode = pipe_windows.pipe_type_byte | pipe_windows.pipe_readmode_byte | pipe_windows.pipe_wait | pipe_windows.pipe_reject_remote_clients;
        const handle = pipe_windows.CreateNamedPipeW(l.name[0..l.name_len :0], open_mode, pipe_mode, pipe_windows.pipe_unlimited_instances, l.buffer_size, l.buffer_size, 0, if (l.descriptor != null) &attributes else null);
        if (handle != windows.INVALID_HANDLE_VALUE) return .{ .handle = handle, .flags = .{ .nonblocking = true } };
        return switch (pipe_windows.GetLastError()) {
            pipe_windows.error_access_denied => if (first) error.AddressInUse else error.AccessDenied,
            pipe_windows.error_invalid_name, pipe_windows.error_bad_pathname => error.InvalidPipeName,
            pipe_windows.error_not_enough_memory => error.SystemResources,
            else => error.Unexpected,
        };
    }
};

/// A server's pipe at `path`, `\\.\pipe\<name>`, its first instance made
/// at once, so a second server for the same name is `AddressInUse`.
/// Clients of other machines are refused.
pub fn listenPipe(path: []const u8, options: ListenOptions) ListenError!PipeListener {
    return if (supported) listenWindows(path, options) else error.NamedPipeUnsupported;
}

fn listenWindows(path: []const u8, options: ListenOptions) ListenError!PipeListener {
    var l: PipeListener = .{ .name = undefined, .name_len = 0, .descriptor = null, .buffer_size = options.buffer_size, .next = null };
    const name = pipeName(path, &l.name) catch return error.InvalidPipeName;
    l.name_len = name.len;
    switch (options.security) {
        .token_default => {},
        .sddl => |text| {
            var wide: [1024:0]u16 = undefined;
            const n = std.unicode.utf8ToUtf16Le(&wide, text) catch return error.InvalidSecurityDescriptor;
            if (n >= wide.len) return error.InvalidSecurityDescriptor;
            wide[n] = 0;
            if (pipe_windows.ConvertStringSecurityDescriptorToSecurityDescriptorW(wide[0..n :0], pipe_windows.sddl_revision_1, &l.descriptor, null) == .FALSE)
                return error.InvalidSecurityDescriptor;
        },
    }
    errdefer if (l.descriptor) |d| {
        _ = pipe_windows.LocalFree(d);
    };
    l.next = try l.instance(true);
    return l;
}

/// What `readPipeWithin` found.
pub const Readiness = union(enum) {
    /// Bytes came, this many into the buffer; 0 is the pipe's end.
    ready: usize,
    /// Nothing came within the time; nothing was taken.
    timed_out,
    /// This `Io` cannot bound a read on a pipe: read it unbounded.
    unbounded,
};

/// A read of `pipe` into `buffer` that waits up to `timeout` for bytes,
/// and ends nothing when none come: on a runtime the read carries its own
/// deadline into the port, and what it took before that is the caller's.
/// Any other `Io` waits on an overlapped call only until it ends, so it
/// says `unbounded`.
pub fn readPipeWithin(io: Io, pipe: Io.File, buffer: []u8, timeout: Io.Duration) (Io.Cancelable || Io.Operation.FileReadStreaming.Error)!Readiness {
    if (!supported) return .unbounded;
    return readWindows(io, pipe, buffer, timeout);
}

fn readWindows(io: Io, pipe: Io.File, buffer: []u8, timeout: Io.Duration) (Io.Cancelable || Io.Operation.FileReadStreaming.Error)!Readiness {
    if (native.runtimeOf(io) == null) return .unbounded;
    const data: [1][]u8 = .{buffer};
    const result = io.operateTimeout(.{ .file_read_streaming = .{ .file = pipe, .data = &data } }, .{ .duration = .{ .raw = timeout, .clock = .awake } }) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        error.Timeout => .timed_out,
        error.ConcurrencyUnavailable => .unbounded,
    };
    const n = result.file_read_streaming catch |err| switch (err) {
        error.EndOfStream => return .{ .ready = 0 },
        else => |e| return e,
    };
    return .{ .ready = n };
}

/// `path` as the system's wide string, in `out`: `\\<host>\pipe\<name>`.
fn pipeName(path: []const u8, out: *[max_path:0]u16) error{InvalidPipeName}![:0]const u16 {
    // A UTF-16 name is never longer than its UTF-8 bytes.
    if (path.len > max_path) return error.InvalidPipeName;
    if (!std.mem.startsWith(u8, path, "\\\\")) return error.InvalidPipeName;
    const host_end = std.mem.findScalarPos(u8, path, 2, '\\') orelse return error.InvalidPipeName;
    if (host_end == 2 or !std.ascii.startsWithIgnoreCase(path[host_end..], "\\pipe\\")) return error.InvalidPipeName;
    if (path.len == host_end + "\\pipe\\".len) return error.InvalidPipeName;
    const n = std.unicode.utf8ToUtf16Le(out, path) catch return error.InvalidPipeName;
    if (n >= out.len) return error.InvalidPipeName;
    out[n] = 0;
    return out[0..n :0];
}

test "a pipe's path names a host and the pipe namespace" {
    var buffer: [max_path:0]u16 = undefined;
    for ([_][]const u8{ "\\\\.\\pipe\\docker_engine", "\\\\server\\PIPE\\x" }) |good| _ = try pipeName(good, &buffer);
    for ([_][]const u8{ "pipe\\x", "\\\\.\\pipe\\", "\\\\\\pipe\\x", "\\\\.\\pip\\x", "//./pipe/x" }) |bad| {
        try std.testing.expectError(error.InvalidPipeName, pipeName(bad, &buffer));
    }
}
