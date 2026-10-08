//! File opens and metadata use native ring requests. Std keeps its error
//! vocabulary and flag semantics; a missing opcode takes the file route.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const Core = @import("Core.zig");
const Loop = @import("../Loop.zig");
const Scheduler = @import("../Scheduler.zig");
const perform = @import("../ops/perform.zig");

fn Return(comptime name: []const u8) type {
    return @typeInfo(@typeInfo(@FieldType(Io.VTable, name)).pointer.child).@"fn".return_type.?;
}

pub fn call(comptime name: []const u8, core: *Core, args: anytype) ?Return(name) {
    if (comptime builtin.os.tag != .linux) return null;
    const opening = comptime std.mem.eql(u8, name, "dirOpenFile") or std.mem.eql(u8, name, "dirCreateFile") or std.mem.eql(u8, name, "dirOpenDir");
    const metadata = comptime std.mem.eql(u8, name, "dirStat") or std.mem.eql(u8, name, "dirStatFile") or std.mem.eql(u8, name, "fileStat");
    if (comptime !opening and !metadata) return null;
    if (core.options.files == .pool) return null;
    const p = Scheduler.processor() orelse return null;
    if (p.scheduler != &core.scheduler or p.loop.backend != .io_uring) return null;
    const ring = &p.loop.backend.io_uring;
    if (!ring.has(if (opening) .OPENAT else .STATX) or !ring.has(.STATX)) return null;
    if (comptime std.mem.eql(u8, name, "dirOpenFile")) return openFile(core, args[0], args[1], args[2]);
    if (comptime std.mem.eql(u8, name, "dirCreateFile")) return createFile(core, args[0], args[1], args[2]);
    if (comptime std.mem.eql(u8, name, "dirOpenDir")) return openDir(core, args[0], args[1], args[2]);
    if (comptime std.mem.eql(u8, name, "dirStatFile")) return statPath(core, args[0], args[1], args[2]);
    if (comptime metadata) return statHandle(core, args[0].handle);
}

const RequestError = error{ Canceled, SystemResources };
fn request(core: *Core, prepared: *linux.io_uring_sqe) RequestError!linux.io_uring_cqe {
    const Prep = struct {
        fn copy(raw: *anyopaque, sqe: *linux.io_uring_sqe) void {
            const from: *const linux.io_uring_sqe = @ptrCast(@alignCast(raw)); // safe: this request retains prepared
            sqe.* = from.*;
        }
    };
    while (true) {
        var op: Loop.Op = .{ .kind = .{ .raw = .{ .uring = .{ .context = prepared, .prepare = Prep.copy } } } };
        perform.run(&core.scheduler, &op, .{}) catch |err| return switch (err) {
            error.Timeout => unreachable,
            error.Canceled => error.Canceled,
            error.SystemResources => error.SystemResources,
        }; // unreachable: no deadline
        const cqe: linux.io_uring_cqe = .{ .res = (try op.result.raw).uring, .flags = 0, .user_data = 0 };
        if (cqe.err() != .INTR) return cqe;
    }
}

fn failure(comptime E: type, err: linux.E) E {
    const name: []const u8 = switch (err) {
        .ACCES => "AccessDenied",
        .PERM => "PermissionDenied",
        .FBIG, .OVERFLOW => "FileTooBig",
        .ISDIR => "IsDir",
        .LOOP => "SymLinkLoop",
        .MFILE => "ProcessFdQuotaExceeded",
        .NFILE => "SystemFdQuotaExceeded",
        .NODEV, .NXIO => "NoDevice",
        .NOENT, .SRCH => "FileNotFound",
        .NOMEM => "SystemResources",
        .NOSPC => "NoSpaceLeft",
        .NOTDIR => "NotDir",
        .EXIST => "PathAlreadyExists",
        .BUSY => "DeviceBusy",
        .AGAIN => "WouldBlock",
        .TXTBSY => "FileBusy",
        .ROFS => "ReadOnlyFileSystem",
        .ILSEQ, .INVAL => "BadPathName",
        else => "Unexpected",
    };
    inline for (@typeInfo(E).error_set.error_names.?) |known| if (std.mem.eql(u8, name, known)) return @field(E, known);
    return error.Unexpected;
}

fn open(core: *Core, dir: Io.Dir, path: []const u8, flags: linux.O, mode: linux.mode_t) Io.File.OpenError!Io.File {
    var path_buffer: [std.posix.PATH_MAX]u8 = undefined;
    const terminated = try Io.Threaded.pathToPosix(path, &path_buffer);
    var actual = flags;
    if (@hasField(linux.O, "LARGEFILE")) actual.LARGEFILE = true;
    var sqe = std.mem.zeroInit(linux.io_uring_sqe, .{});
    sqe.prep_openat(dir.handle, terminated, actual, mode);
    const cqe = try request(core, &sqe);
    if (cqe.err() != .SUCCESS) return failure(Io.File.OpenError, cqe.err());
    return .{ .handle = cqe.res, .flags = .{ .nonblocking = false } };
}

fn lock(core: *Core, file: Io.File, selected: Io.File.Lock, nonblocking: bool) Io.File.OpenError!void {
    if (selected == .none) return;
    if (nonblocking) {
        if (!try file.tryLock(core.io(), selected)) return error.WouldBlock;
    } else try file.lock(core.io(), selected);
}

fn openFile(core: *Core, dir: Io.Dir, path: []const u8, options: Io.Dir.OpenFileOptions) Io.File.OpenError!Io.File {
    const file = try open(core, dir, path, .{ .ACCMODE = switch (options.mode) {
        .read_only => .RDONLY,
        .write_only => .WRONLY,
        .read_write => .RDWR,
    }, .NOCTTY = !options.allow_ctty, .NOFOLLOW = !options.follow_symlinks, .CLOEXEC = true, .PATH = options.path_only }, 0);
    errdefer file.close(core.io());
    if (!options.allow_directory) {
        const is_dir = if (statHandle(core, file.handle)) |info| info.kind == .directory else |err| switch (err) {
            error.Streaming => false,
            else => return narrow(Io.File.OpenError, err),
        };
        if (is_dir) return error.IsDir;
    }
    try lock(core, file, options.lock, options.lock_nonblocking);
    return file;
}

fn createFile(core: *Core, dir: Io.Dir, path: []const u8, options: Io.Dir.CreateFileOptions) Io.File.OpenError!Io.File {
    const file = try open(core, dir, path, .{ .ACCMODE = if (options.read) .RDWR else .WRONLY, .CREAT = true, .TRUNC = options.truncate, .EXCL = options.exclusive, .CLOEXEC = true }, options.permissions.toMode());
    errdefer file.close(core.io());
    try lock(core, file, options.lock, options.lock_nonblocking);
    return file;
}

fn openDir(core: *Core, dir: Io.Dir, path: []const u8, options: Io.Dir.OpenOptions) Io.Dir.OpenError!Io.Dir {
    const file = open(core, dir, path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = !options.follow_symlinks, .CLOEXEC = true, .PATH = !options.iterate }, 0) catch |err| {
        return narrow(Io.Dir.OpenError, err);
    };
    return .{ .handle = file.handle };
}

const StatError = Io.Dir.StatFileError;
fn stat(core: *Core, fd: linux.fd_t, path: [*:0]const u8, flags: u32) StatError!Io.File.Stat {
    var output = std.mem.zeroes(linux.Statx);
    var sqe = std.mem.zeroInit(linux.io_uring_sqe, .{});
    sqe.opcode = .STATX;
    sqe.fd = fd;
    sqe.addr = @intFromPtr(path); // safe: path stays in the waiting caller's frame
    sqe.off = @intFromPtr(&output); // safe: output stays pinned through cancellation and completion
    sqe.len = @bitCast(Io.Threaded.linux_statx_request);
    sqe.rw_flags = flags;
    const cqe = try request(core, &sqe);
    if (cqe.err() != .SUCCESS) return failure(StatError, cqe.err());
    return Io.Threaded.statFromLinux(&output);
}

fn statHandle(core: *Core, fd: linux.fd_t) Io.File.StatError!Io.File.Stat {
    return stat(core, fd, "", linux.AT.EMPTY_PATH) catch |err| {
        return narrow(Io.File.StatError, err);
    };
}

fn statPath(core: *Core, dir: Io.Dir, path: []const u8, options: Io.Dir.StatFileOptions) StatError!Io.File.Stat {
    var buffer: [std.posix.PATH_MAX]u8 = undefined;
    const terminated = try Io.Threaded.pathToPosix(path, &buffer);
    return stat(core, dir.handle, terminated, linux.AT.NO_AUTOMOUNT | @as(u32, if (options.follow_symlinks) 0 else linux.AT.SYMLINK_NOFOLLOW));
}

fn narrow(comptime E: type, err: anytype) E {
    inline for (@typeInfo(E).error_set.error_names.?) |name| if (std.mem.eql(u8, @errorName(err), name)) return @field(E, name);
    return error.Unexpected;
}
