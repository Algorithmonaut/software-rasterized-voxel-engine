const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdl_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/platform/sdl.h"),
        .target = target,
        .optimize = optimize,
    });

    sdl_translate.linkSystemLibrary("sdl2", .{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{
            .name = "sdl",
            .module = sdl_translate.createModule(),
        }},
    });

    exe_mod.linkSystemLibrary("sdl2", .{});

    const exe = b.addExecutable(.{
        .name = "softrast-voxel",
        .root_module = exe_mod,

        // Workaround for Arch/GCC/glibc .sframe realloc issue
        .use_llvm = true,
        .use_lld = true,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the game");
    run_step.dependOn(&run_cmd.step);
}
