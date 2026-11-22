const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.createModule(.{
        .root_source_file = b.path("libiride/libiride.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    const static = b.addLibrary(.{ .name = "iride", .linkage = .static, .root_module = lib });
    static.bundle_compiler_rt = true;
    static.installHeader(b.path("libiride/libiride.h"), "libiride.h");
    b.installArtifact(static);
    b.installArtifact(b.addLibrary(.{ .name = "iride", .linkage = .dynamic, .root_module = lib }));
    b.installFile("libiride/libiride.vapi", "share/vala/vapi/libiride.vapi");

    const tool = b.createModule(.{
        .root_source_file = b.path("cmd/iride/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "libiride", .module = lib }},
    });
    for ([_][]const u8{ "gtk4", "cairo" }) |name| tool.linkSystemLibrary(name, .{});
    b.installArtifact(b.addExecutable(.{ .name = "iride", .root_module = tool }));

    const step = b.step("test", "run tests");
    for ([_]*std.Build.Module{ lib, tool }) |mod| step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
}
