//! Switching between stacks: std's `Io.fiber.contextSwitch`, which saves
//! the stack pointer, frame pointer and resume address and lets the
//! compiler spill the callee-saved registers, and the first frame of a new
//! stack. On Windows a switch also carries the stack's bounds in the thread
//! information block, which Windows reads to grow a stack by its guard page
//! and to walk it: the old stack's bounds are saved with its registers and
//! the new one's loaded before the jump.
const builtin = @import("builtin");
const std = @import("std");
const sys_windows = @import("sys/windows.zig");

const is_windows = builtin.os.tag == .windows;

/// Whether this target can run reactor's tasks.
pub const supported = std.Io.fiber.supported and switch (builtin.os.tag) {
    .linux, .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    .windows => builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64,
    else => false,
};

/// A stack's saved registers, and on Windows its bounds. std's switch reads
/// and writes the registers, which come first.
pub const Context = if (is_windows) extern struct {
    registers: std.Io.fiber.Context,
    bounds: sys_windows.StackBounds,
} else std.Io.fiber.Context;

/// What a switch carries: the two contexts, and whatever the switcher
/// wants the resumed side to do once the old stack is no longer running.
pub const Switch = if (is_windows) extern struct { old: *Context, new: *Context } else std.Io.fiber.Switch;

/// A new stack's first function. `message` is the switch that started it.
pub const Entry = *const fn (arg: *anyopaque, message: *const Switch) callconv(.c) noreturn;

/// Saves the running context into `s.old`, runs `s.new`, and returns the
/// switch that resumed this context later.
pub inline fn switchTo(s: *const Switch) *const Switch {
    if (is_windows) {
        s.old.bounds = sys_windows.stackBounds();
        sys_windows.setStackBounds(s.new.bounds);
        // The registers lead both contexts: std's switch sees its own.
        return @ptrCast(std.Io.fiber.contextSwitch(@ptrCast(s))); // safe: the same layout with the bounds after the registers
    }
    if (builtin.cpu.arch == .aarch64) return switchAarch64(s);
    return std.Io.fiber.contextSwitch(s);
}

/// std's aarch64 switch, with the link register named as LLVM knows it:
/// std's `.x30` clobber is dropped, so an optimized build keeps a value in
/// the link register across the switch and finds the other stack's there
/// (Zig 0.17.0; a Debug build happens not to).
inline fn switchAarch64(s: *const Switch) *const Switch {
    return asm volatile (
        \\ ldp x0, x2, [x1]
        \\ ldr x3, [x2, #16]
        \\ mov x4, sp
        \\ stp x4, fp, [x0]
        \\ adr x5, 0f
        \\ ldp x4, fp, [x2]
        \\ str x5, [x0, #16]
        \\ mov sp, x4
        \\ br x3
        \\0:
        : [received_message] "={x1}" (-> *const Switch),
        : [message_to_send] "{x1}" (s),
        : .{
          .x0 = true,
          .x1 = true,
          .x2 = true,
          .x3 = true,
          .x4 = true,
          .x5 = true,
          .x6 = true,
          .x7 = true,
          .x8 = true,
          .x9 = true,
          .x10 = true,
          .x11 = true,
          .x12 = true,
          .x13 = true,
          .x14 = true,
          .x15 = true,
          .x16 = true,
          .x17 = true,
          .x19 = true,
          .x20 = true,
          .x21 = true,
          .x22 = true,
          .x23 = true,
          .x24 = true,
          .x25 = true,
          .x26 = true,
          .x27 = true,
          .x28 = true,
          .lr = true,
          .z0 = true,
          .z1 = true,
          .z2 = true,
          .z3 = true,
          .z4 = true,
          .z5 = true,
          .z6 = true,
          .z7 = true,
          .z8 = true,
          .z9 = true,
          .z10 = true,
          .z11 = true,
          .z12 = true,
          .z13 = true,
          .z14 = true,
          .z15 = true,
          .z16 = true,
          .z17 = true,
          .z18 = true,
          .z19 = true,
          .z20 = true,
          .z21 = true,
          .z22 = true,
          .z23 = true,
          .z24 = true,
          .z25 = true,
          .z26 = true,
          .z27 = true,
          .z28 = true,
          .z29 = true,
          .z30 = true,
          .z31 = true,
          .p0 = true,
          .p1 = true,
          .p2 = true,
          .p3 = true,
          .p4 = true,
          .p5 = true,
          .p6 = true,
          .p7 = true,
          .p8 = true,
          .p9 = true,
          .p10 = true,
          .p11 = true,
          .p12 = true,
          .p13 = true,
          .p14 = true,
          .p15 = true,
          .fpcr = true,
          .fpsr = true,
          .ffr = true,
          .memory = true,
        });
}

/// A stack a context can start on.
pub const Stack = struct {
    /// One past the highest usable byte; 16-aligned.
    top: usize,
    /// Windows: the lowest committed byte.
    limit: usize,
    /// Windows: the lowest reserved byte, its guard included.
    bottom: usize,
};

/// The context that starts `entry(arg, message)` on `stack` when first
/// switched to. `top` is where the first frame goes (16-aligned, at or
/// below the stack's own top); it uses the 48 bytes below it.
pub fn initial(stack: Stack, top: usize, entry: Entry, arg: *anyopaque) Context {
    std.debug.assert(top % 16 == 0);
    const base = top - 48;
    const registers: std.Io.fiber.Context = switch (builtin.cpu.arch) {
        .x86_64 => registers: {
            // Entered by a jump: rsp is 8 mod 16, as after a call, with
            // [rsp] the (zero) return address, then the argument and entry.
            // On Windows the 32 bytes above the return address are the
            // callee's shadow space: the argument and entry are read first.
            const sp = base + 8;
            const slots: [*]usize = @ptrFromInt(sp);
            slots[0] = 0;
            slots[1] = @intFromPtr(arg); // safe: read back as a pointer by the trampoline
            slots[2] = @intFromPtr(entry); // safe: the function the trampoline jumps to
            break :registers .{ .rsp = sp, .rbp = 0, .rip = @intFromPtr(&trampoline) }; // safe: the naked entry's address
        },
        .aarch64, .riscv64 => registers: {
            const slots: [*]usize = @ptrFromInt(base);
            slots[0] = 0;
            slots[1] = @intFromPtr(arg); // safe: read back as a pointer by the trampoline
            slots[2] = @intFromPtr(entry); // safe: the function the trampoline jumps to
            slots[3] = 0;
            break :registers .{ .sp = base, .fp = 0, .pc = @intFromPtr(&trampoline) }; // safe: the naked entry's address
        },
        else => @compileError("no fiber switch for this architecture"),
    };
    if (is_windows) return .{ .registers = registers, .bounds = .{ .base = stack.top, .limit = stack.limit, .deallocation = stack.bottom } };
    return registers;
}

/// Windows: the lowest committed byte of the stack `c` last ran on, as the
/// system had grown it when `c` switched away.
pub fn committedLimit(c: *const Context) usize {
    if (is_windows) return c.bounds.limit;
    return 0;
}

/// The first instructions of a stack: the argument and the entry from the
/// top of the stack, the switch message already in the second argument
/// register (where `contextSwitch` leaves it; Windows x86-64 passes the
/// second argument elsewhere, so it is moved), then a jump. Frame pointer
/// and return address are zero, so a stack walk ends here.
fn trampoline() callconv(.naked) noreturn {
    switch (builtin.cpu.arch) {
        .x86_64 => if (is_windows) asm volatile (
            \\ movq %%rsi, %%rdx
            \\ movq 8(%%rsp), %%rcx
            \\ jmpq *16(%%rsp)
        ) else asm volatile (
            \\ movq 8(%%rsp), %%rdi
            \\ jmpq *16(%%rsp)
        ),
        .aarch64 => asm volatile (
            \\ ldr x0, [sp, #8]
            \\ ldr x9, [sp, #16]
            \\ mov x30, xzr
            \\ br x9
        ),
        .riscv64 => asm volatile (
            \\ ld a0, 8(sp)
            \\ ld t0, 16(sp)
            \\ li ra, 0
            \\ jr t0
        ),
        else => @compileError("no fiber switch for this architecture"),
    }
}
