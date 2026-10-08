//! Switching between stacks: std's `Io.fiber.contextSwitch` (on aarch64 a
//! copy that also keeps the link register), which saves
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

/// A stack's saved state while it is not running. On aarch64 reactor's
/// own, with room for the link register; elsewhere std's.
const Registers = switch (builtin.cpu.arch) {
    .aarch64 => extern struct { sp: u64, fp: u64, pc: u64, lr: u64 },
    else => std.Io.fiber.Context,
};

pub const Context = if (builtin.sanitize_thread) extern struct {
    registers: Registers,
    sanitizer: *anyopaque,
} else Registers;

extern fn __tsan_create_fiber(flags: c_uint) *anyopaque;
extern fn __tsan_destroy_fiber(handle: *anyopaque) void;
extern fn __tsan_get_current_fiber() *anyopaque;
extern fn __tsan_switch_to_fiber(handle: *anyopaque, flags: c_uint) void;

/// Only contexts created by initial, after their stacks have stopped.
pub fn deinit(context: *Context) void {
    if (builtin.sanitize_thread) __tsan_destroy_fiber(context.sanitizer);
    context.* = undefined;
}

/// What a switch carries: the two contexts, and whatever the switcher
/// wants the resumed side to do once the old stack is no longer running.
pub const Switch = extern struct { old: *Context, new: *Context };

/// A new stack's first function. `message` is the switch that started it.
pub const Entry = *const fn (arg: *anyopaque, message: *const Switch) callconv(.c) noreturn;

/// Saves the running context into `s.old`, runs `s.new`, and returns the
/// switch that resumed this context later.
///
/// A call keeps the callee-saved registers in this stack's frame. The
/// assembly ties its input to its returned message register: listing that
/// fixed register as both an input and a clobber made LLVM omit the input
/// move in optimized builds, so the switch read an unrelated address.
pub noinline fn switchTo(s: *const Switch) *const Switch {
    if (builtin.sanitize_thread) {
        s.old.sanitizer = __tsan_get_current_fiber();
        // A switch hands its message and frame to the next context, even
        // for a local task queue that requires no atomic publication.
        __tsan_switch_to_fiber(s.new.sanitizer, 0);
    }
    return switch (builtin.cpu.arch) {
        .aarch64 => switchAarch64(s),
        .x86_64 => switchX86(s),
        .riscv64 => switchRiscv(s),
        else => @compileError("no fiber switch for this architecture"),
    };
}

/// std's aarch64 switch, keeping the link register in the context. LLVM
/// knows x30 only as `lr` and drops a clobber of `x30`, which is how std
/// names it: optimized code then kept a value in x30 across a switch and
/// found the resumer's there after it (seen as a task pointer gone stale
/// and a frame overwritten through it). Saved and restored here, x30
/// holds after the switch what it held before.
inline fn switchAarch64(s: *const Switch) *const Switch {
    return asm volatile (
        \\ ldp x0, x2, [x1]
        \\ ldr x3, [x2, #16]
        \\ mov x4, sp
        \\ stp x4, fp, [x0]
        \\ adr x5, 0f
        \\ stp x5, x30, [x0, #16]
        \\ ldp x4, fp, [x2]
        \\ ldr x30, [x2, #24]
        \\ mov sp, x4
        \\ br x3
        \\0:
        : [received_message] "={x1}" (-> *const Switch),
        : [message_to_send] "0" (s),
        : .{
          .x0 = true,
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

inline fn switchX86(s: *const Switch) *const Switch {
    return asm volatile (
        \\ movq 0(%%rsi), %%rax
        \\ movq 8(%%rsi), %%rcx
        \\ leaq 0f(%%rip), %%rdx
        \\ movq %%rsp, 0(%%rax)
        \\ movq %%rbp, 8(%%rax)
        \\ movq %%rdx, 16(%%rax)
        \\ movq 0(%%rcx), %%rsp
        \\ movq 8(%%rcx), %%rbp
        \\ jmpq *16(%%rcx)
        \\0:
        : [received_message] "={rsi}" (-> *const Switch),
        : [message_to_send] "0" (s),
        : .{
          .rax = true,
          .rcx = true,
          .rdx = true,
          .rbx = true,
          .rdi = true,
          .r8 = true,
          .r9 = true,
          .r10 = true,
          .r11 = true,
          .r12 = true,
          .r13 = true,
          .r14 = true,
          .r15 = true,
          .mm0 = true,
          .mm1 = true,
          .mm2 = true,
          .mm3 = true,
          .mm4 = true,
          .mm5 = true,
          .mm6 = true,
          .mm7 = true,
          .zmm0 = true,
          .zmm1 = true,
          .zmm2 = true,
          .zmm3 = true,
          .zmm4 = true,
          .zmm5 = true,
          .zmm6 = true,
          .zmm7 = true,
          .zmm8 = true,
          .zmm9 = true,
          .zmm10 = true,
          .zmm11 = true,
          .zmm12 = true,
          .zmm13 = true,
          .zmm14 = true,
          .zmm15 = true,
          .zmm16 = true,
          .zmm17 = true,
          .zmm18 = true,
          .zmm19 = true,
          .zmm20 = true,
          .zmm21 = true,
          .zmm22 = true,
          .zmm23 = true,
          .zmm24 = true,
          .zmm25 = true,
          .zmm26 = true,
          .zmm27 = true,
          .zmm28 = true,
          .zmm29 = true,
          .zmm30 = true,
          .zmm31 = true,
          .fpsr = true,
          .fpcr = true,
          .mxcsr = true,
          .rflags = true,
          .dirflag = true,
          .memory = true,
        });
}

inline fn switchRiscv(s: *const Switch) *const Switch {
    return asm volatile (
        \\ ld a0, 0(a1)
        \\ ld a2, 8(a1)
        \\ lla a3, 0f
        \\ sd sp, 0(a0)
        \\ sd fp, 8(a0)
        \\ sd a3, 16(a0)
        \\ ld sp, 0(a2)
        \\ ld fp, 8(a2)
        \\ ld a3, 16(a2)
        \\ jr a3
        \\0:
        : [received_message] "={a1}" (-> *const Switch),
        : [message_to_send] "0" (s),
        : .{
          .x1 = true,
          .x3 = true,
          .x4 = true,
          .x5 = true,
          .x6 = true,
          .x7 = true,
          .x9 = true,
          .x10 = true,
          .x12 = true,
          .x13 = true,
          .x14 = true,
          .x15 = true,
          .x16 = true,
          .x17 = true,
          .x18 = true,
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
          .x29 = true,
          .x30 = true,
          .x31 = true,
          .f0 = true,
          .f1 = true,
          .f2 = true,
          .f3 = true,
          .f4 = true,
          .f5 = true,
          .f6 = true,
          .f7 = true,
          .f8 = true,
          .f9 = true,
          .f10 = true,
          .f11 = true,
          .f12 = true,
          .f13 = true,
          .f14 = true,
          .f15 = true,
          .f16 = true,
          .f17 = true,
          .f18 = true,
          .f19 = true,
          .f20 = true,
          .f21 = true,
          .f22 = true,
          .f23 = true,
          .f24 = true,
          .f25 = true,
          .f26 = true,
          .f27 = true,
          .f28 = true,
          .f29 = true,
          .f30 = true,
          .f31 = true,
          .v0 = true,
          .v1 = true,
          .v2 = true,
          .v3 = true,
          .v4 = true,
          .v5 = true,
          .v6 = true,
          .v7 = true,
          .v8 = true,
          .v9 = true,
          .v10 = true,
          .v11 = true,
          .v12 = true,
          .v13 = true,
          .v14 = true,
          .v15 = true,
          .v16 = true,
          .v17 = true,
          .v18 = true,
          .v19 = true,
          .v20 = true,
          .v21 = true,
          .v22 = true,
          .v23 = true,
          .v24 = true,
          .v25 = true,
          .v26 = true,
          .v27 = true,
          .v28 = true,
          .v29 = true,
          .v30 = true,
          .v31 = true,
          .vtype = true,
          .vl = true,
          .vxsat = true,
          .vxrm = true,
          .vcsr = true,
          .fflags = true,
          .frm = true,
          .memory = true,
        });
}

/// The context that starts `entry(arg, message)` on the stack ending at
/// `top` (16-aligned) when first switched to. Uses the top 48 bytes.
pub fn initial(top: usize, entry: Entry, arg: *anyopaque) Context {
    const registers = initialRegisters(top, entry, arg);
    return if (builtin.sanitize_thread) .{ .registers = registers, .sanitizer = __tsan_create_fiber(0) } else registers;
}

fn initialRegisters(top: usize, entry: Entry, arg: *anyopaque) Registers {
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
            const pc = @intFromPtr(&trampoline); // safe: the naked entry's address
            return if (builtin.cpu.arch == .aarch64) .{ .sp = base, .fp = 0, .pc = pc, .lr = 0 } else .{ .sp = base, .fp = 0, .pc = pc };
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
