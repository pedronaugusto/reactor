//! Positional reads and writes of a file, made in place: a regular file has
//! no readiness to wait for, so a readiness backend's loop and a worker's
//! blocking bracket both make these calls directly. Errors are std's, as
//! `Io.Threaded` maps them for the same calls.
const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const Io = std.Io;
const Threaded = Io.Threaded;

const preadv = if (posix.lfs64_abi) posix.system.preadv64 else posix.system.preadv;
const pread = if (posix.lfs64_abi) posix.system.pread64 else posix.system.pread;
const pwrite = if (posix.lfs64_abi) posix.system.pwrite64 else posix.system.pwrite;

/// The most one read or write moves: Linux's own cap.
const max_rw = 0x7ffff000;

/// Into `data`'s buffers from `offset` on; fewer bytes than asked is no
/// error. Windows positional calls use IOCP or borrowed std calls.
pub fn readAt(fd: posix.fd_t, data: []const []u8, offset: u64) (Io.File.ReadPositionalError || Io.Cancelable)!usize {
    if (comptime builtin.os.tag == .windows) unreachable; // unreachable: this POSIX helper is not used on Windows
    var iovecs: [Threaded.max_iovecs_len]posix.iovec = undefined;
    var n: usize = 0;
    for (data) |d| {
        if (n == iovecs.len) break;
        if (d.len == 0) continue;
        iovecs[n] = .{ .base = d.ptr, .len = @min(d.len, max_rw) };
        n += 1;
    }
    if (n == 0) return 0;
    while (true) {
        const rc = if (n == 1)
            pread(fd, iovecs[0].base, iovecs[0].len, @bitCast(offset))
        else
            preadv(fd, &iovecs, @intCast(n), @bitCast(offset));
        return switch (posix.errno(rc)) {
            .SUCCESS => @as(usize, @intCast(rc)),
            .INTR, .TIMEDOUT => continue,
            .NXIO, .SPIPE, .OVERFLOW => error.Unseekable,
            .NOBUFS, .NOMEM => error.SystemResources,
            .AGAIN => error.WouldBlock,
            .IO => error.InputOutput,
            .ISDIR => error.IsDir,
            .BADF => error.NotOpenForReading,
            .NOTCONN, .CONNRESET, .INVAL, .FAULT => |e| Threaded.errnoBug(e),
            else => |e| posix.unexpectedErrno(e),
        };
    }
}

/// `bytes` at `offset`; fewer bytes than given is no error.
pub fn writeAt(fd: posix.fd_t, bytes: []const u8, offset: u64) (Io.File.WritePositionalError || Io.Cancelable)!usize {
    if (comptime builtin.os.tag == .windows) unreachable; // unreachable: this POSIX helper is not used on Windows
    while (true) {
        const rc = pwrite(fd, bytes.ptr, @min(bytes.len, max_rw), @bitCast(offset));
        return switch (posix.errno(rc)) {
            .SUCCESS => @as(usize, @intCast(rc)),
            .INTR => continue,
            .BADF => error.NotOpenForWriting,
            .DQUOT => error.DiskQuota,
            .FBIG => error.FileTooBig,
            .IO => error.InputOutput,
            .NOSPC => error.NoSpaceLeft,
            .PERM => error.PermissionDenied,
            .PIPE => error.BrokenPipe,
            .NXIO, .SPIPE, .OVERFLOW => error.Unseekable,
            .INVAL, .FAULT, .AGAIN, .DESTADDRREQ => |e| Threaded.errnoBug(e),
            else => |e| posix.unexpectedErrno(e),
        };
    }
}
