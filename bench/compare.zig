//! Interleaved reactor A/B benchmark output. All fixtures and the immutable
//! baseline checkout stay under this clone's cache. No timing is a CI gate.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const baseline = "46f6da8cba6b20ac3bc8e4cd6cba1d35861f19e4";
const ownership_baseline = "7e7e851534d971da778956e4b587c14cb7f194ae";
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
    return measureProgram(gpa, io, writer, round, variant, directory, &.{ ".zig-cache/later-bench", "--workers", "0", "--json" }, args);
}
fn measureProgram(gpa: std.mem.Allocator, io: Io, writer: *Io.Writer, round: usize, variant: []const u8, directory: []const u8, prefix: []const []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, prefix);
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
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--smoke")) return;
    if (args.len < 2 or args.len > 3) return error.ExpectedZigPath;
    const zig = args[1];
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buffer);
    const w = &stdout.interface;
    const ownership_mode = args.len == 3 and std.mem.eql(u8, args[2], "--ownership");
    const before_source = if (ownership_mode) ownership_baseline else baseline;
    try w.print("{{\"baseline\":\"{s}\",\"os\":\"{s}\",\"arch\":\"{s}\"}}\n", .{ before_source, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
    try w.flush();
    Io.Dir.cwd().access(io, base_dir, .{}) catch {
        try checked(gpa, io, &.{ "git", "clone", "--no-checkout", ".", base_dir }, ".");
    };
    // A hosted scratch snapshot need not contain the later branch ancestry.
    // Fetch the immutable public comparison checkpoint into our own fixture.
    try checked(gpa, io, &.{ "git", "fetch", "--no-tags", "https://github.com/pedronaugusto/reactor.git", ownership_baseline }, base_dir);
    try checked(gpa, io, &.{ "git", "reset", "--hard", before_source }, base_dir);
    try checked(gpa, io, &.{ "git", "checkout", "--detach", before_source }, base_dir);
    if (args.len == 3 and std.mem.eql(u8, args[2], "--offloads")) return offloadBefore(gpa, io, w, zig);
    if (args.len == 3 and std.mem.eql(u8, args[2], "--regressions")) {
        try before(gpa, io, w, zig);
        return;
    }
    if (args.len == 3 and std.mem.eql(u8, args[2], "--costs")) return costs(gpa, io, w, zig);
    const compile = &.{ zig, "build-exe", "-OReleaseFast", "--dep", "reactor", "-Mroot=bench/main.zig", "-OReleaseFast", "-Mreactor=src/reactor.zig", "-femit-bin=.zig-cache/later-bench" };
    try Io.Dir.cwd().createDirPath(io, base_dir ++ "/.zig-cache");
    try checked(gpa, io, compile, base_dir);
    try checked(gpa, io, compile, ".");
    if (ownership_mode) {
        for ([_][]const u8{ "spawn", "wake" }) |workload| for ([_][]const u8{ "0", "1" }) |workers| for (0..5) |round| {
            const before_label = try std.fmt.allocPrint(gpa, "before-ownership-workers-{s}", .{workers});
            defer gpa.free(before_label);
            const after_label = try std.fmt.allocPrint(gpa, "after-ownership-workers-{s}", .{workers});
            defer gpa.free(after_label);
            const rows = &.{ "--only", workload, "--workers", workers };
            if (round % 2 == 0) {
                try measure(gpa, io, w, round, before_label, base_dir, rows);
                try measure(gpa, io, w, round, after_label, ".", rows);
            } else {
                try measure(gpa, io, w, round, after_label, ".", rows);
                try measure(gpa, io, w, round, before_label, base_dir, rows);
            }
        };
        return;
    }
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
    for ([_][]const u8{ "spawn-options", "priority-lanes" }) |workload| {
        for (0..5) |round| {
            const a = &.{ "--only", workload };
            const b = &.{ "--only", workload, "--latency" };
            if (round % 2 == 0) {
                try measure(gpa, io, w, round, "normal-priority", ".", a);
                try measure(gpa, io, w, round, "latency-priority", ".", b);
            } else {
                try measure(gpa, io, w, round, "latency-priority", ".", b);
                try measure(gpa, io, w, round, "normal-priority", ".", a);
            }
        }
    }
    for ([_][]const u8{ "65536", "262144", "1048576" }) |bytes| {
        const label = try std.fmt.allocPrint(gpa, "default-stack-{s}", .{bytes});
        defer gpa.free(label);
        for (0..5) |round| {
            const a = &.{ "--only", "spawn-options" };
            const b = &.{ "--only", "spawn-options", "--task-size", bytes };
            if (round % 2 == 0) {
                try measure(gpa, io, w, round, label, ".", a);
                try measure(gpa, io, w, round, bytes, ".", b);
            } else {
                try measure(gpa, io, w, round, bytes, ".", b);
                try measure(gpa, io, w, round, label, ".", a);
            }
        }
    }
    try costs(gpa, io, w, zig);
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
        const a = &.{ "--only", "wake", "--workers", "1", "--msg-ring-off" };
        const b = &.{ "--only", "wake", "--workers", "1" };
        if (round % 2 == 0) {
            try measure(gpa, io, w, round, "eventfd-wake", ".", a);
            try measure(gpa, io, w, round, "msg-ring-wake", ".", b);
        } else {
            try measure(gpa, io, w, round, "msg-ring-wake", ".", b);
            try measure(gpa, io, w, round, "eventfd-wake", ".", a);
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
        const label = try std.fmt.allocPrint(gpa, "zero-copy-{s}", .{bytes});
        defer gpa.free(label);
        for (0..5) |round| {
            const a = &.{ "--only", "bulk", "--bytes", bytes, "--zero-copy-min", "off" };
            const b = &.{ "--only", "bulk", "--bytes", bytes, "--zero-copy-min", "1" };
            if (round % 2 == 0) {
                try measure(gpa, io, w, round, bytes, ".", a);
                try measure(gpa, io, w, round, label, ".", b);
            } else {
                try measure(gpa, io, w, round, label, ".", b);
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

fn offloadBefore(gpa: std.mem.Allocator, io: Io, writer: *Io.Writer, zig: []const u8) !void {
    const directory = Io.Dir.cwd();
    try focusTests(gpa, io);
    const source = try directory.readFileAlloc(io, "src/offload_test.zig", gpa, .unlimited);
    defer gpa.free(source);
    try directory.writeFile(io, .{ .sub_path = base_dir ++ "/src/offload_test.zig", .data = source });
    const roots = try directory.readFileAlloc(io, base_dir ++ "/src/tests.zig", gpa, .unlimited);
    defer gpa.free(roots);
    const updated = try std.mem.concat(gpa, u8, &.{ roots, "\ntest { _ = @import(\"offload_test.zig\"); }\n" });
    defer gpa.free(updated);
    try directory.writeFile(io, .{ .sub_path = base_dir ++ "/src/tests.zig", .data = updated });
    try expectBefore(gpa, io, writer, zig, "r6: raw offload refusal survives", "expected error.ConcurrencyUnavailable, found void");
    try expectBefore(gpa, io, writer, zig, "r6: accepted raw offloads from outside", "TestUnexpectedResult");
    try expectBefore(gpa, io, writer, zig, "r6: a foreign raw offload", "TestExpectedEqual");
}

fn installTests(gpa: std.mem.Allocator, io: Io) !void {
    const directory = Io.Dir.cwd();
    try focusTests(gpa, io);
    const regression = try directory.readFileAlloc(io, "src/r1_regression_test.zig", gpa, .unlimited);
    defer gpa.free(regression);
    try directory.writeFile(io, .{ .sub_path = base_dir ++ "/src/r1_regression_test.zig", .data = regression });
    const lanes = try directory.readFileAlloc(io, "src/lanes_test.zig", gpa, .unlimited);
    defer gpa.free(lanes);
    const stop = std.mem.indexOf(u8, lanes, "const Ordered = struct").?;
    try directory.writeFile(io, .{ .sub_path = base_dir ++ "/src/lanes_test.zig", .data = lanes[0..stop] });
    const roots = try directory.readFileAlloc(io, base_dir ++ "/src/tests.zig", gpa, .unlimited);
    defer gpa.free(roots);
    const with_regressions = try std.mem.concat(gpa, u8, &.{ roots, "\ntest { _ = @import(\"r1_regression_test.zig\"); _ = @import(\"lanes_test.zig\"); }\n" });
    defer gpa.free(with_regressions);
    try directory.writeFile(io, .{ .sub_path = base_dir ++ "/src/tests.zig", .data = with_regressions });
}
fn expectBefore(gpa: std.mem.Allocator, io: Io, writer: *Io.Writer, zig: []const u8, filter: []const u8, marker: []const u8) !void {
    const arg = try std.fmt.allocPrint(gpa, "-Dtest-filter={s}", .{filter});
    defer gpa.free(arg);
    const result = try std.process.run(gpa, io, .{ .argv = &.{ zig, "build", "later-before", "-Dci-lint=false", arg }, .cwd = .{ .path = base_dir }, .timeout = .{ .duration = .{ .raw = .fromSeconds(180), .clock = .awake } } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try writer.print("BEFORE {s}\n{s}\n{s}\n", .{ filter, result.stdout, result.stderr });
    try writer.flush();
    if (result.term == .exited and result.term.exited == 0) return error.RegressionDidNotFailBefore;
    if (std.mem.indexOf(u8, result.stderr, marker) == null) return error.WrongBaselineFailure;
}
fn before(gpa: std.mem.Allocator, io: Io, writer: *Io.Writer, zig: []const u8) !void {
    try installTests(gpa, io);
    try checked(gpa, io, &.{ zig, "build", "--list-steps" }, base_dir);
    try expectBefore(gpa, io, writer, zig, "R1 cross-runtime spawning", "R1 cross-runtime spawning retains destination scheduler ownership");
    try expectBefore(gpa, io, writer, zig, "R1 cross-runtime wake retains destination", "R1 cross-runtime wake retains destination scheduler ownership");
    try expectBefore(gpa, io, writer, zig, "executor rejection", "executor rejection finishes without running a lane call inline");
    try expectBefore(gpa, io, writer, zig, "disabled owned lane", "a disabled owned lane refuses instead of queueing forever");
    if (builtin.os.tag == .linux) {
        try expectBefore(gpa, io, writer, zig, "R1 Linux dialing", "TODO implement netInterfaceName for linux");
        try expectBefore(gpa, io, writer, zig, "R1 native open", "R1 native open and stat use no inline file lane");
        try checked(gpa, io, &.{ "git", "reset", "--hard", ownership_baseline }, base_dir);
        try focusTests(gpa, io);
        const ownership_tests = try Io.Dir.cwd().readFileAlloc(io, "src/r1_regression_test.zig", gpa, .unlimited);
        defer gpa.free(ownership_tests);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = base_dir ++ "/src/r1_regression_test.zig", .data = ownership_tests });
        try expectBefore(gpa, io, writer, zig, "R1 cross-runtime pinned", "R1 cross-runtime pinned wake retains no source-ring target reference");
        // The shutdown bug was introduced in the first pushed LATER
        // checkpoint, whose exact public source is retained in history.
        try checked(gpa, io, &.{ "git", "reset", "--hard", "f110c7943327868ef21172e80320f34355e0498c" }, base_dir);
        try focusTests(gpa, io);
        // That checkpoint already imported these two test files.
        const regression = try Io.Dir.cwd().readFileAlloc(io, "src/r1_regression_test.zig", gpa, .unlimited);
        defer gpa.free(regression);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = base_dir ++ "/src/r1_regression_test.zig", .data = regression });
        try expectBefore(gpa, io, writer, zig, "R1 group await", "expected 0, found 1");
        try expectBefore(gpa, io, writer, zig, "R1 stopping idle", "exited with code 97");
    } else if (builtin.os.tag == .macos) {
        try expectBefore(gpa, io, writer, zig, "R1 native child", "R1 native child wait uses no inline wait lane");
    }
}

fn focusTests(gpa: std.mem.Allocator, io: Io) !void {
    // Select only the test artifact. Example and benchmark smoke programs
    // otherwise hang at shutdown in the deliberately broken checkpoint.
    const path = base_dir ++ "/build.zig";
    const original = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(original);
    const declaration = "const test_step = b.step(\"test\", \"Run the tests and example\");";
    const focused = try std.mem.replaceOwned(u8, gpa, original, declaration, declaration ++ "\n    b.step(\"later-before\", \"Run only the selected before regression\").dependOn(&b.addRunArtifact(tests).step);");
    defer gpa.free(focused);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = focused });
}

fn costs(gpa: std.mem.Allocator, io: Io, writer: *Io.Writer, zig: []const u8) !void {
    const directory = Io.Dir.cwd();
    const source = try directory.readFileAlloc(io, "bench/costs.zig", gpa, .unlimited);
    defer gpa.free(source);
    try directory.writeFile(io, .{ .sub_path = base_dir ++ "/bench/costs.zig", .data = source });
    try directory.createDirPath(io, base_dir ++ "/.zig-cache");
    const compile = &.{ zig, "build-exe", "-OReleaseFast", "--dep", "reactor", "-Mroot=bench/costs.zig", "-OReleaseFast", "-Mreactor=src/reactor.zig", "-femit-bin=.zig-cache/later-costs" };
    try checked(gpa, io, compile, base_dir);
    try checked(gpa, io, compile, ".");
    for ([_][]const u8{ "process", "stacks" }) |workload| for (0..5) |round| {
        const prefix = &.{".zig-cache/later-costs"};
        const rows = &.{workload};
        if (round % 2 == 0) {
            try measureProgram(gpa, io, writer, round, "main-costs", base_dir, prefix, rows);
            try measureProgram(gpa, io, writer, round, "later-costs", ".", prefix, rows);
        } else {
            try measureProgram(gpa, io, writer, round, "later-costs", ".", prefix, rows);
            try measureProgram(gpa, io, writer, round, "main-costs", base_dir, prefix, rows);
        }
    };
}
