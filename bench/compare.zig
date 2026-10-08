//! Interleaved public reactor A/B evidence. All fixtures and the immutable
//! baseline checkout stay under this clone's cache. No timing is a CI gate.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const baseline = "46f6da8cba6b20ac3bc8e4cd6cba1d35861f19e4";
const base_dir = ".zig-cache/later-evidence-base";

fn command(gpa: std.mem.Allocator, io: Io, argv: []const []const u8, cwd: []const u8) !std.process.RunResult {
    const result = try std.process.run(gpa, io, .{ .argv = argv, .cwd = .{ .path = cwd }, .timeout = .{ .duration = .{ .raw = .fromSeconds(180), .clock = .awake } } });
    if (result.term != .exited or result.term.exited != 0) {
        var buffer: [1024]u8 = undefined;
        var stderr = Io.File.stderr().writer(io, &buffer);
        try stderr.interface.print("command {s}: {s}\n{s}\n", .{ argv[0], result.stdout, result.stderr });
        try stderr.interface.flush();
        gpa.free(result.stdout);
        gpa.free(result.stderr);
        return error.CommandFailed;
    }
    return result;
}
fn checked(gpa: std.mem.Allocator, io: Io, argv: []const []const u8, cwd: []const u8) !void {
    const result = try command(gpa, io, argv, cwd);
    gpa.free(result.stdout);
    gpa.free(result.stderr);
}
fn measure(gpa: std.mem.Allocator, io: Io, writer: *Io.Writer, round: usize, variant: []const u8, directory: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ ".zig-cache/later-bench", "--workers", "0", "--json" });
    try argv.appendSlice(gpa, args);
    const result = try command(gpa, io, argv.items, directory);
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| if (line.len != 0) {
        try writer.print("{{\"round\":{d},\"variant\":\"{s}\",\"measurement\":{s}}}\n", .{ round, variant, line });
    };
    try writer.flush();
}
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--smoke")) return;
    if (args.len != 2) return error.ExpectedZigPath;
    const zig = args[1];
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buffer);
    const w = &stdout.interface;
    try w.print("{{\"baseline\":\"{s}\",\"os\":\"{s}\",\"arch\":\"{s}\"}}\n", .{ baseline, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
    try w.flush();
    Io.Dir.cwd().access(io, base_dir, .{}) catch {
        try checked(gpa, io, &.{ "git", "clone", "--no-checkout", ".", base_dir }, ".");
    };
    try checked(gpa, io, &.{ "git", "checkout", "--detach", baseline }, base_dir);
    const compile = &.{ zig, "build-exe", "-OReleaseFast", "--dep", "reactor", "-Mroot=bench/main.zig", "-OReleaseFast", "-Mreactor=src/reactor.zig", "-femit-bin=.zig-cache/later-bench" };
    try Io.Dir.cwd().createDirPath(io, base_dir ++ "/.zig-cache");
    try checked(gpa, io, compile, base_dir);
    try checked(gpa, io, compile, ".");
    for ([_][]const u8{ "spawn", "wake", "loop", "files", "lanes", "echo", "deadlines", "waits", "timers" }) |workload| {
        for (0..5) |round| {
            const rows = &.{ "--only", workload };
            if (round % 2 == 0) {
                try measure(gpa, io, w, round, "main", base_dir, rows);
                try measure(gpa, io, w, round, "later", ".", rows);
            } else {
                try measure(gpa, io, w, round, "later", ".", rows);
                try measure(gpa, io, w, round, "main", base_dir, rows);
            }
        }
    }
    if (builtin.os.tag != .linux) return;
    try measure(gpa, io, w, 0, "native-capabilities", ".", &.{ "--only", "info" });
    for ([_]struct { name: []const u8, workload: []const u8, off: []const u8 }{
        .{ .name = "fixed-files", .workload = "files", .off = "--fixed-files-off" },
        .{ .name = "linked-timeout", .workload = "deadlines", .off = "--linked-timeout-off" },
        .{ .name = "native-open-stat", .workload = "open-stat", .off = "--files-pool" },
    }) |feature| {
        for (0..5) |round| {
            const a = &.{ "--only", feature.workload, feature.off };
            const b = &.{ "--only", feature.workload };
            if (round % 2 == 0) {
                try measure(gpa, io, w, round, feature.off, ".", a);
                try measure(gpa, io, w, round, feature.name, ".", b);
            } else {
                try measure(gpa, io, w, round, feature.name, ".", b);
                try measure(gpa, io, w, round, feature.off, ".", a);
            }
        }
    }
    for (0..5) |round| {
        const a = &.{ "--only", "files" };
        const b = &.{ "--only", "files", "--registered" };
        if (round % 2 == 0) {
            try measure(gpa, io, w, round, "ordinary-buffer", ".", a);
            try measure(gpa, io, w, round, "registered-buffer", ".", b);
        } else {
            try measure(gpa, io, w, round, "registered-buffer", ".", b);
            try measure(gpa, io, w, round, "ordinary-buffer", ".", a);
        }
    }
    for ([_][]const u8{ "512", "4096", "16384", "65536", "1048576" }) |bytes| {
        for (0..5) |round| {
            const a = &.{ "--only", "bulk", "--bytes", bytes, "--zero-copy-min", "off" };
            const b = &.{ "--only", "bulk", "--bytes", bytes, "--zero-copy-min", "1" };
            if (round % 2 == 0) {
                try measure(gpa, io, w, round, bytes, ".", a);
                try measure(gpa, io, w, round, "zero-copy", ".", b);
            } else {
                try measure(gpa, io, w, round, "zero-copy", ".", b);
                try measure(gpa, io, w, round, bytes, ".", a);
            }
        }
    }
    for (0..5) |round| {
        const a = &.{ "--only", "files" };
        const b = &.{ "--only", "files", "--sqpoll" };
        if (round % 2 == 0) {
            try measure(gpa, io, w, round, "ordinary-ring", ".", a);
            try measure(gpa, io, w, round, "sqpoll", ".", b);
        } else {
            try measure(gpa, io, w, round, "sqpoll", ".", b);
            try measure(gpa, io, w, round, "ordinary-ring", ".", a);
        }
    }
}
