//! Switching between stacks: std's `Io.fiber.contextSwitch`, which saves
//! the stack pointer, frame pointer and resume address and lets the
//! compiler spill the callee-saved registers, and the first frame of a new
//! stack. Windows needs a switch that also keeps the thread information
//! block's stack bounds right; until reactor has one, Windows has no fibers.
const builtin = @import("builtin");
const std = @import("std");

/// Whether this target can run reactor's tasks.
pub const supported = std.Io.fiber.supported and switch (builtin.os.tag) {
    .linux, .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

pub const Context = std.Io.fiber.Context;

/// What a switch carries: the two contexts, and whatever the switcher
/// wants the resumed side to do once the old stack is no longer running.
pub const Switch = std.Io.fiber.Switch;

/// A new stack's first function. `message` is the switch that started it.
pub const Entry = *const fn (arg: *anyopaque, message: *const Switch) callconv(.c) noreturn;

/// Saves the running context into `s.old`, runs `s.new`, and returns the
/// switch that resumed this context later.
pub inline fn switchTo(s: *const Switch) *const Switch {
    return std.Io.fiber.contextSwitch(s);
}

/// The context that starts `entry(arg, message)` on the stack ending at
/// `top` (16-aligned) when first switched to. Uses the top 48 bytes.
pub fn initial(top: usize, entry: Entry, arg: *anyopaque) Context {
    std.debug.assert(top % 16 == 0);
    const base = top - 48;
    switch (builtin.cpu.arch) {
        .x86_64 => {
            // Entered by a jump: rsp is 8 mod 16, as after a call, with
            // [rsp] the (zero) return address, then the argument and entry.
            const sp = base + 8;
            const slots: [*]usize = @ptrFromInt(sp);
            slots[0] = 0;
            slots[1] = @intFromPtr(arg); // safe: read back as a pointer by the trampoline
            slots[2] = @intFromPtr(entry); // safe: the function the trampoline jumps to
            return .{ .rsp = sp, .rbp = 0, .rip = @intFromPtr(&trampoline) }; // safe: the naked entry's address
        },
        .aarch64, .riscv64 => {
            const slots: [*]usize = @ptrFromInt(base);
            slots[0] = 0;
            slots[1] = @intFromPtr(arg); // safe: read back as a pointer by the trampoline
            slots[2] = @intFromPtr(entry); // safe: the function the trampoline jumps to
            slots[3] = 0;
            return .{ .sp = base, .fp = 0, .pc = @intFromPtr(&trampoline) }; // safe: the naked entry's address
        },
        else => @compileError("no fiber switch for this architecture"),
    }
}

/// The first instructions of a stack: the argument and the entry from the
/// top of the stack, the switch message already in the second argument
/// register (where `contextSwitch` leaves it), then a jump. Frame pointer
/// and return address are zero, so a stack walk ends here.
fn trampoline() callconv(.naked) noreturn {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
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
