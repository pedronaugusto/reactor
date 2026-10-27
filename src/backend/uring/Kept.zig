//! The descriptors an io_uring fixed-file slot may stand for: those whose
//! owner records them here when it opens them and forgets them when it
//! closes them. A runtime records every file it opens and forgets it at its
//! own close; a bare `Loop`'s caller records what it passes.
//!
//! A slot is a file the kernel holds by its number, so it must not outlive
//! the descriptor it was made for. Only an owner that sees both the open and
//! the close can say so: a descriptor opened or closed past it (airlock's
//! temps, made by a raw `openat` and closed by a raw `close` for close's
//! EIO, then written through the `Io`) is used by its plain number, which
//! the kernel always resolves to the file that has it now. A slot kept by
//! number alone wrote one file's bytes into another file once the number
//! was reused.
//!
//! One bit per descriptor number, up to the process's open-file limit when
//! the record is made; a number above it is used plainly.

const Kept = @This();
const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;

const Word = usize;
const word_bits = @bitSizeOf(Word);

words: []std.atomic.Value(Word),

/// The most descriptor numbers kept: past a million the bits cost more
/// than the slots save.
const max_numbers = 1 << 20;

pub fn init(gpa: Allocator) Allocator.Error!Kept {
    const words = try gpa.alloc(std.atomic.Value(Word), (numbers() + word_bits - 1) / word_bits);
    for (words) |*w| w.* = .init(0);
    return .{ .words = words };
}

pub fn deinit(k: *Kept, gpa: Allocator) void {
    gpa.free(k.words);
    k.* = undefined;
}

/// How many descriptor numbers to keep: the open-file limit's soft value,
/// within `max_numbers`.
fn numbers() usize {
    const limit = std.posix.getrlimit(.NOFILE) catch return 1024;
    return @intCast(@max(64, @min(limit.cur, max_numbers)));
}

/// `fd` is open, and its owner closes it through the owner's own close.
pub fn record(k: *Kept, fd: std.posix.fd_t) void {
    const at = k.place(fd) orelse return;
    _ = k.words[at.word].fetchOr(at.bit, .release);
}

/// `fd` is being closed by its owner: no slot may stand for it after.
pub fn forget(k: *Kept, fd: std.posix.fd_t) void {
    const at = k.place(fd) orelse return;
    _ = k.words[at.word].fetchAnd(~at.bit, .release);
}

pub fn contains(k: *const Kept, fd: std.posix.fd_t) bool {
    const at = k.place(fd) orelse return false;
    return k.words[at.word].load(.acquire) & at.bit != 0;
}

fn place(k: *const Kept, fd: std.posix.fd_t) ?struct { word: usize, bit: Word } {
    if (fd < 0) return null;
    const n: usize = @intCast(fd);
    const word = n / word_bits;
    if (word >= k.words.len) return null;
    return .{ .word = word, .bit = @as(Word, 1) << @intCast(n % word_bits) };
}

test "a number is kept between its record and its forgetting, and none past the limit" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var k = try Kept.init(std.testing.allocator);
    defer k.deinit(std.testing.allocator);
    try std.testing.expect(!k.contains(5));
    k.record(5);
    k.record(70);
    try std.testing.expect(k.contains(5) and k.contains(70) and !k.contains(6));
    k.forget(5);
    try std.testing.expect(!k.contains(5) and k.contains(70));
    k.record(-1);
    try std.testing.expect(!k.contains(-1));
    const past: std.posix.fd_t = @intCast(k.words.len * word_bits);
    k.record(past);
    try std.testing.expect(!k.contains(past));
}
