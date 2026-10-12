//! The switch between contexts keeps what the code that switched holds in
//! registers, whatever the other context does with them.
const builtin = @import("builtin");
const std = @import("std");

const fiber = @import("fiber.zig");

test "values a caller keeps in vector registers across a switch survive a context that overwrites them" {
    if (!fiber.supported) return error.SkipZigTest;
    const V = @Vector(4, f32);
    const Probe = struct {
        var driver: fiber.Context = undefined;
        var task: fiber.Context = undefined;
        fn run(arg: *anyopaque, message: *const fiber.Switch) callconv(.c) noreturn {
            _ = arg;
            _ = message;
            overwrite();
            _ = fiber.switchTo(&.{ .old = &task, .new = &driver });
            unreachable; // unreachable: the test never switches back to it
        }
        /// What any context's code may do with the vector registers: here,
        /// every one of them set, and nothing told.
        noinline fn overwrite() void {
            switch (builtin.cpu.arch) {
                .x86_64 => asm volatile (
                    \\ pcmpeqd %%xmm0, %%xmm0
                    \\ pcmpeqd %%xmm1, %%xmm1
                    \\ pcmpeqd %%xmm2, %%xmm2
                    \\ pcmpeqd %%xmm3, %%xmm3
                    \\ pcmpeqd %%xmm4, %%xmm4
                    \\ pcmpeqd %%xmm5, %%xmm5
                    \\ pcmpeqd %%xmm6, %%xmm6
                    \\ pcmpeqd %%xmm7, %%xmm7
                    \\ pcmpeqd %%xmm8, %%xmm8
                    \\ pcmpeqd %%xmm9, %%xmm9
                    \\ pcmpeqd %%xmm10, %%xmm10
                    \\ pcmpeqd %%xmm11, %%xmm11
                    \\ pcmpeqd %%xmm12, %%xmm12
                    \\ pcmpeqd %%xmm13, %%xmm13
                    \\ pcmpeqd %%xmm14, %%xmm14
                    \\ pcmpeqd %%xmm15, %%xmm15
                ),
                .aarch64 => asm volatile (
                    \\ movi v0.16b, #0xff
                    \\ movi v1.16b, #0xff
                    \\ movi v2.16b, #0xff
                    \\ movi v3.16b, #0xff
                    \\ movi v4.16b, #0xff
                    \\ movi v5.16b, #0xff
                    \\ movi v6.16b, #0xff
                    \\ movi v7.16b, #0xff
                    \\ movi v16.16b, #0xff
                    \\ movi v17.16b, #0xff
                    \\ movi v18.16b, #0xff
                    \\ movi v19.16b, #0xff
                ),
                else => {},
            }
        }
    };
    // A stack of its own, committed whole: on Windows its bounds are its ends.
    const memory = try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(16), 64 << 10);
    defer std.heap.page_allocator.free(memory);
    const base = @intFromPtr(memory.ptr); // safe: an address, kept as a number to lay out the stack
    const top = base + memory.len;
    Probe.task = fiber.initial(.{ .top = top, .limit = base, .bottom = base }, top, Probe.run, &Probe.driver);
    defer fiber.deinit(&Probe.task);
    var input: [12]V = undefined;
    for (&input, 0..) |*v, i| v.* = @splat(@floatFromInt(i + 1));
    std.mem.doNotOptimizeAway(&input);
    // On Windows the vector registers from xmm6 up are the callee's to keep:
    // a caller may hold these across the switch in them, as across any call.
    var kept: [12]V = undefined;
    inline for (0..12) |i| kept[i] = input[i] * input[i];
    _ = fiber.switchTo(&.{ .old = &Probe.driver, .new = &Probe.task });
    inline for (0..12) |i| {
        const square: f32 = @floatFromInt((i + 1) * (i + 1));
        try std.testing.expectEqual(@as(V, @splat(square)), kept[i]);
    }
}
