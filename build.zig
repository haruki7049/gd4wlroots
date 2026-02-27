const std = @import("std");
const gdzig = @import("gdzig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const godot_version = b.option([]const u8, "godot-version", "Download and use this Godot version (e.g. `latest` or `4.5`)");
    const godot_path = b.option([]const u8, "godot-path", "Directory containing Godot executable [default: $PATH]");
    const single_threaded = b.option(bool, "single_threaded", "Target single threaded GdExtension [default: false]") orelse false;

    const gdzig_dep = b.dependency("gdzig", .{
        .target = target,
        .optimize = optimize,
        .@"godot-version" = godot_version,
        .@"godot-path" = godot_path,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/extension.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .imports = &.{
            .{ .name = "godot", .module = gdzig_dep.module("gdzig") },
        },
    });

    // Link wlroots and wayland-server.
    // Requires wlroots >= 0.17 and wayland-server >= 1.21 installed on the system.
    mod.linkSystemLibrary("wlroots-0.19", .{});
    mod.linkSystemLibrary("wayland-server", .{});

    const extension = gdzig.addExtension(b, .{
        .name = "gdwlroots",
        .root_module = mod,
        .entry_symbol = "gdwlroots_init",
        .target = target,
        .optimize = optimize,
    }) orelse return;

    const install = b.addInstallFileWithDir(
        extension.output,
        .{ .custom = "../project/lib" },
        extension.filename,
    );
    b.default_step.dependOn(&install.step);
}
