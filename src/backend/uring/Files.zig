//! A bounded per-ring regular-file cache. Registering sockets or pipes can
//! defer EOF until unrelated requests release a retired resource node.
//! Entries are published for close
//! routing; only the ring's owner updates the kernel table.
const Files = @This();
const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

slots: []std.atomic.Value(linux.fd_t),
registered: []bool,
enabled: bool,

pub fn init(gpa: Allocator, ring: *linux.IoUring, count: u32, wanted: bool) Allocator.Error!Files {
    const slots = try gpa.alloc(std.atomic.Value(linux.fd_t), count);
    errdefer gpa.free(slots);
    const registered = try gpa.alloc(bool, count);
    @memset(registered, false);
    for (slots) |*slot| slot.* = .init(-1);
    var enabled = wanted;
    if (wanted) ring.register_files_sparse(count) catch {
        enabled = false;
    };
    return .{ .slots = slots, .registered = registered, .enabled = enabled };
}

pub fn deinit(f: *Files, gpa: Allocator) void {
    gpa.free(f.registered);
    gpa.free(f.slots);
    f.* = undefined;
}

pub fn contains(f: *const Files, fd: linux.fd_t) bool {
    const start = @as(u32, @bitCast(fd)) % f.slots.len;
    for (0..@min(8, f.slots.len)) |offset| if (f.slots[(start + offset) % f.slots.len].load(.acquire) == fd) return true;
    return false;
}

/// Full or unsupported tables use the ordinary descriptor.
pub fn use(f: *Files, ring: *linux.IoUring, sqe: *linux.io_uring_sqe) void {
    if (!f.enabled or sqe.fd < 0) return;
    var vacant: ?u32 = null;
    const start = @as(u32, @bitCast(sqe.fd)) % f.slots.len;
    for (0..@min(8, f.slots.len)) |offset| {
        const i = (start + offset) % f.slots.len;
        const slot = &f.slots[i];
        const fd = slot.load(.monotonic);
        if (fd == sqe.fd) {
            if (!f.registered[i]) return;
            sqe.fd = @intCast(i);
            sqe.flags |= linux.IOSQE_FIXED_FILE;
            return;
        }
        if (fd == -1 and vacant == null) vacant = @intCast(i);
    }
    const index = vacant orelse return;
    const fd = sqe.fd;
    if (!regular(fd)) {
        f.registered[index] = false;
        f.slots[index].store(fd, .release);
        return;
    }
    ring.register_files_update(index, &.{fd}) catch return;
    f.registered[index] = true;
    f.slots[index].store(fd, .release);
    sqe.fd = @intCast(index);
    sqe.flags |= linux.IOSQE_FIXED_FILE;
}

/// Accepted requests retain their file references. Unsubmitted requests
/// revert to the ordinary descriptor before its slot is removed; only
/// this thread submits, so the kernel cannot consume them during the edit.
pub fn remove(f: *Files, u: anytype, fd: linux.fd_t) void {
    const start = @as(u32, @bitCast(fd)) % f.slots.len;
    for (0..@min(8, f.slots.len)) |offset| {
        const i = (start + offset) % f.slots.len;
        const slot = &f.slots[i];
        if (slot.load(.monotonic) != fd) continue;
        if (!f.registered[i]) {
            slot.store(-1, .release);
            return;
        }
        var head = @atomicLoad(u32, u.ring.sq.head, .acquire);
        while (head != u.ring.sq.sqe_tail) : (head +%= 1) {
            const sqe = &u.ring.sq.sqes[head & u.ring.sq.mask];
            if (sqe.flags & linux.IOSQE_FIXED_FILE == 0 or sqe.fd != i) continue;
            sqe.fd = fd;
            sqe.flags &= ~@as(u8, linux.IOSQE_FIXED_FILE);
        }
        u.ring.register_files_update(@intCast(i), &.{-1}) catch |err| std.debug.panic("reactor: removing a fixed file failed: {t}", .{err});
        slot.store(-1, .release);
        return;
    }
}

fn regular(fd: linux.fd_t) bool {
    var stat: linux.Statx = undefined;
    while (true) switch (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &stat))) {
        .SUCCESS => return linux.S.ISREG(stat.mode),
        .INTR => continue,
        else => return false,
    };
}
