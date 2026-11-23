const std = @import("std");
const Backend = enum {
    fallback,
    vt,
    native,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const backend = b.option(Backend, "out", "Choose the backend") orelse .fallback;
    const termy = b.dependency("termy", .{ .target = target, .optimize = optimize, .out = backend });

    const tmod = termy.module("termy");

    const stdx_mod = b.addModule("stdx", .{
        .root_source_file = b.path("leek-stdx/root.zig"),
        .target = target,
    });

    const tui_mod = b.addModule(
        "tui",
        .{
            .root_source_file = b.path("leek-tui/root.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "termy", .module = tmod },
                .{ .name = "stdx", .module = stdx_mod },
            },
        },
    );

    const mod = b.addModule("leek", .{
        .root_source_file = b.path("leek/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "termy", .module = tmod },
            .{ .name = "tui", .module = tui_mod },
            .{ .name = "stdx", .module = stdx_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "leek",
        .root_module = b.createModule(.{
            .root_source_file = b.path("leek/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "leek", .module = mod }},
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const test_stdx = b.step("test-stdx", "Run stdx tests");
    const test_tui = b.step("test-tui", "Run TUI tests");
    const test_step = b.step("test", "Run all tests");

    const stdx_tests = b.addTest(.{
        .root_module = stdx_mod,
    });

    const tui_tests = b.addTest(.{
        .root_module = tui_mod,
    });

    const stdx_run = b.addRunArtifact(stdx_tests);
    stdx_run.has_side_effects = true;

    const tui_run = b.addRunArtifact(tui_tests);
    tui_run.has_side_effects = true;

    test_stdx.dependOn(&stdx_run.step);
    test_tui.dependOn(&tui_run.step);

    test_step.dependOn(&stdx_run.step);
    test_step.dependOn(&tui_run.step);
}
