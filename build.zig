const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //Miniaudio stuff

    const opusfile_dep = b.dependency("opusfile", .{});
    const opusfile_lib = opusfile_dep.artifact("opusfile");

    const translate_c = b.addTranslateC(.{
        .optimize = optimize,
        .target = target,
        .root_source_file = b.path("src/miniaudioc.h"),
    });

    const c_mod = translate_c.addModule("c_mod");

    c_mod.addCSourceFile(.{ .file = b.path("src/miniaudio.c") });
    c_mod.addCSourceFile(.{ .file = b.path("src/libopus/miniaudio_libopus.c") });

    c_mod.linkLibrary(opusfile_lib);

    // Create our Mach app module, where all our code lives.
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/App.zig"),
        .optimize = optimize,
        .target = target,
        .imports = &.{
            .{ .name = "c", .module = c_mod },
        },
    });

    // Add Mach import to our app.
    const mach_dep = b.dependency("mach", .{
        .target = target,
        .optimize = optimize,
    });
    app_mod.addImport("mach", mach_dep.module("mach"));

    // Have Mach create the executable for us
    const exe = @import("mach").addExecutable(mach_dep.builder, .{
        .name = "miniaudio_mach",
        .app = app_mod,
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    // Run the app when `zig build run` is invoked
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Run tests when `zig build test` is run
    const app_unit_tests = b.addTest(.{
        .root_module = app_mod,
    });
    const run_app_unit_tests = b.addRunArtifact(app_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_app_unit_tests.step);

    // Check step for ZLS
    const check_exe = @import("mach").addExecutable(mach_dep.builder, .{
        .name = "miniaudio_mach",
        .app = app_mod,
        .target = target,
        .optimize = optimize,
    });

    const check_step = b.step("check", "build on save checking");
    check_step.dependOn(&check_exe.step);
}
