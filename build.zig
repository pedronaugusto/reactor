const std = @import("std");

/// What a project that depends on reactor builds: the `reactor` module and its
/// library. The tests, example, benchmarks and gate are `dev`'s. The seam in
/// front of reactor's raw socket calls is a module of its own that only
/// reactor and `reactor.testing` import, so neither exports it, as airlock's
/// is; `reactor.testing` is made by `testing`, on the shakedown the project's
/// build gives it.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    // A task's stack and switch are shuttle's.
    const shuttle = b.dependency("shuttle", .{ .target = target, .optimize = optimize }).module("shuttle");
    const seam = b.createModule(.{ .root_source_file = b.path("src/seam.zig"), .target = target, .optimize = optimize });
    const module = b.addModule("reactor", .{ .root_source_file = b.path("src/reactor.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "aegis", .module = aegis }, .{ .name = "shuttle", .module = shuttle }, .{ .name = "seam", .module = seam } } });
    b.installArtifact(b.addLibrary(.{ .name = "reactor", .root_module = module }));
}

/// reactor's development: its tests, example and benchmarks under preflight's
/// gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const sanitize_thread = b.option(bool, "sanitize-thread", "Run focused native race tests with thread sanitizer") orelse false;
    const package = b.dependency("reactor", .{ .target = target, .optimize = optimize });
    const p = package.builder;
    const module = package.module("reactor");
    const library = package.artifact("reactor");
    const aegis_dependency = p.dependency("aegis", .{ .target = target, .optimize = optimize });
    const aegis = aegis_dependency.module("aegis");
    const shuttle_dependency = p.dependency("shuttle", .{ .target = target, .optimize = optimize });

    const filters = if (test_filter) |filter| &.{filter} else &.{};
    const test_module = b.createModule(.{
        .root_source_file = p.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "aegis", .module = aegis }, .{ .name = "shuttle", .module = shuttle_dependency.module("shuttle") }, .{ .name = "seam", .module = module.import_table.get("seam").? } },
    });
    if (target.result.os.tag == .windows) {
        test_module.link_libc = true;
        test_module.addCSourceFile(.{ .file = p.path("src/testing/seh.c"), .flags = &.{"-fms-extensions"} });
    }
    test_module.sanitize_thread = sanitize_thread;
    // std's own Threaded.zig, read by the test that checks which slots may
    // run std's code on a worker.
    const threaded_source = b.addWriteFiles().addCopyFile(std.Build.LazyPath.zig_lib.path(b, "std/Io/Threaded.zig"), "Threaded.zig.txt");
    test_module.addAnonymousImport("threaded.source", .{ .root_source_file = threaded_source });
    const tests = b.addTest(.{ .name = "reactor-tests", .filters = filters, .root_module = test_module });
    const test_step = b.step("test", "Run the tests and example");
    // The suite alone: what the hardened profile fuzzes and runs under
    // ThreadSanitizer, without the example and the gate.
    const unit = b.step("unit", "Run the test suite alone");
    unit.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(unit);
    const check = b.step("check", "Compile the tests, library, example and benchmarks without running them");
    check.dependOn(&tests.step);
    check.dependOn(&library.step);
    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{ .root_source_file = p.path("examples/usage.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "reactor", .module = module }} }),
    });
    const examples = b.step("examples", "Build and run the usage example");
    examples.dependOn(&b.addRunArtifact(example).step);
    test_step.dependOn(examples);
    check.dependOn(&example.step);
    b.getInstallStep().dependOn(&tests.step);
    b.getInstallStep().dependOn(&example.step);

    // The test doubles and the conformance suite are shakedown's.
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize });
    test_module.addImport("shakedown", shakedown.module("shakedown"));
    // The seam's tests install its hook as a project's do.
    test_module.addImport("reactor.testing", testing(package, shakedown.module("shakedown")));
    // airlock's device flushes through `syncLane`, the executor reactor
    // supplies for its `Blocking`.
    test_module.addImport("airlock", b.dependency("airlock", .{ .target = target, .optimize = optimize }).module("airlock"));
    tools.preflight.addCi(b, p, .{
        .tests = test_step,
        .portable_tests = true,
        // The release tier fuzzes the scheduler's properties and runs the
        // suite under ThreadSanitizer, where a race between a task and the
        // thread that awaits it shows.
        .hardened = .{ .fuzz_step = "unit", .tsan_step = "unit" },
        .bench = .{
            .programs = &.{ .{ .name = "bench", .source = "bench/main.zig" }, .{ .name = "costs", .source = "bench/costs.zig", .timed = false }, .{ .name = "v11-prepare", .source = "bench/v11/prepare.zig", .timed = false } },
            .imports = tools.preflight.Bench.importsFrom(benchImports),
            .target = target,
            .optimize = optimize,
        },
    });
    // A project that depends on reactor by path, with no packages to
    // fetch: the build a consumer gets.
    tools.preflight.addConsumerCheck(b, p, .{ .package = "reactor", .program = p.path("ci/consumer.zig"), .packages = &.{ aegis_dependency, shuttle_dependency } });
}

/// reactor again, in the mode a benchmark builds in: an imported module keeps
/// its own mode, so a ReleaseFast benchmark over the Debug module would
/// time the Debug module. `b` is the development build.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const p = b.dependency("reactor", .{ .target = target, .optimize = optimize }).builder;
    const aegis = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    const shuttle = p.dependency("shuttle", .{ .target = target, .optimize = optimize }).module("shuttle");
    const seam = b.createModule(.{ .root_source_file = p.path("src/seam.zig"), .target = target, .optimize = optimize });
    const reactor = b.createModule(.{ .root_source_file = p.path("src/reactor.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "aegis", .module = aegis }, .{ .name = "shuttle", .module = shuttle }, .{ .name = "seam", .module = seam } } });
    return b.allocator.dupe(std.Build.Module.Import, &.{ .{ .name = "reactor", .module = reactor }, .{ .name = "aegis", .module = aegis } }) catch @panic("OOM");
}

/// The test seam for a project's tests: the module `reactor.testing`, for
/// `reactor`'s dependency in that project's build, on `shakedown`, the
/// project's own, so that a test binary links one shakedown. Its `Seam` is an
/// `Io` whose sockets are not the system's (a simulation's), where reactor's
/// raw socket calls ask the test instead.
///
///     const reactor_build = @import("reactor"); // at the top of the build.zig
///
///     const reactor = b.dependency("reactor", .{ .target = target, .optimize = optimize });
///     const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize });
///     tests.root_module.addImport("reactor.testing", reactor_build.testing(reactor, shakedown.module("shakedown")));
pub fn testing(reactor: *std.Build.Dependency, shakedown: *std.Build.Module) *std.Build.Module {
    const module = reactor.module("reactor");
    return reactor.builder.createModule(.{
        .root_source_file = reactor.builder.path("src/testing.zig"),
        .target = module.resolved_target,
        .optimize = module.optimize,
        .imports = &.{
            .{ .name = "seam", .module = module.import_table.get("seam").? },
            .{ .name = "aegis", .module = module.import_table.get("aegis").? },
            .{ .name = "shakedown", .module = shakedown },
        },
    });
}
