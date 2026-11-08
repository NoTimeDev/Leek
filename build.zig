const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const termy = b.dependency("termy", .{ .target = target, .optimize = optimize });

    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("leek-core/root.zig"),
        .target = target,
    });

    const tui_mod = b.addModule("tui", .{ .root_source_file = b.path("leek-tui/root.zig"), .target = target, .imports = &.{ .{ .name = "termy", .module = termy.module("termy") }, .{ .name = "core", .module = core_mod } } });

    const mod = b.createModule(.{
        .root_source_file = b.path("leek/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "tui", .module = tui_mod }, .{ .name = "core", .module = core_mod } },
    });

    const exe = b.addExecutable(.{
        .name = "leek",
        .root_module = mod,
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const test_core = b.step("test-core", "Run core tests");
    const test_tui = b.step("test-tui", "Run TUI tests");
    const test_step = b.step("test", "Run all tests");

    const core_tests = b.addTest(.{
        .root_module = core_mod,
    });

    const tui_tests = b.addTest(.{
        .root_module = tui_mod,
    });

    const core_run = b.addRunArtifact(core_tests);
    core_run.has_side_effects = true;
    const tui_run = b.addRunArtifact(tui_tests);
    tui_run.has_side_effects = true;

    test_core.dependOn(&core_run.step);
    test_tui.dependOn(&tui_run.step);

    test_step.dependOn(&core_run.step);
    test_step.dependOn(&tui_run.step);
}
