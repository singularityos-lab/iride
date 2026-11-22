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

    const step = b.step("test", "run tests");
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = lib })).step);
    if (b.option(bool, "pixbuf", "build the gdk-pixbuf loader") orelse false) {
        const loader = b.createModule(.{
            .root_source_file = b.path("pixbuf/loader.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
            .link_libc = true,
            .imports = &.{.{ .name = "libiride", .module = lib }},
        });
        for ([_][]const u8{ "gdk-pixbuf-2.0", "gio-2.0" }) |name| loader.linkSystemLibrary(name, .{});
        const so = b.addLibrary(.{ .name = "pixbufloader-iride", .linkage = .dynamic, .root_module = loader });
        b.getInstallStep().dependOn(&b.addInstallArtifact(so, .{
            .dest_dir = .{ .override = .{ .custom = "lib/gdk-pixbuf-2.0/2.10.0/loaders" } },
        }).step);
        b.installFile("pixbuf/dev.sinty.iride.xml", "share/mime/packages/dev.sinty.iride.xml");
        step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = loader })).step);
    }
    if (!(b.option(bool, "tool", "build the compiler, which needs GTK and Cairo") orelse true)) return;

    const tool = b.createModule(.{
        .root_source_file = b.path("cmd/iride/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "libiride", .module = lib }},
    });
    for ([_][]const u8{ "gtk4", "cairo" }) |name| tool.linkSystemLibrary(name, .{});
    b.installArtifact(b.addExecutable(.{ .name = "iride", .root_module = tool }));
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = tool })).step);
}
