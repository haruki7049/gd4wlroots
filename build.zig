const std = @import("std");
const gdzig = @import("gdzig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const godot_version = b.option([]const u8, "godot-version", "Download and use this Godot version (e.g. `latest` or `4.5`)");
    const godot_path = b.option([]const u8, "godot-path", "Directory containing Godot executable [default: $PATH]");
    const single_threaded = b.option(bool, "single_threaded", "Target single threaded GdExtension [default: false]") orelse false;

    // Path to wayland-protocols XML files.
    // Defaults to the WAYLAND_PROTOCOLS env var set by shell.nix, then falls
    // back to the common system path on non-Nix distros.
    const wp_dir = b.option(
        []const u8,
        "wayland-protocols",
        "Path to wayland-protocols share dir (contains stable/, unstable/, ...)",
    ) orelse std.process.getEnvVarOwned(b.allocator, "WAYLAND_PROTOCOLS") catch
        "/usr/share/wayland-protocols";

    // ── Generate xdg-shell-protocol.h ────────────────────────────────────
    // wlr/types/wlr_xdg_shell.h does #include "xdg-shell-protocol.h" (quoted,
    // not angled), so wayland-scanner must run before the C translation unit.
    const xdg_shell_xml = b.pathJoin(&.{ wp_dir, "stable/xdg-shell/xdg-shell.xml" });

    const gen_xdg = b.addSystemCommand(&.{ "wayland-scanner", "server-header" });
    gen_xdg.addArg(xdg_shell_xml);
    const xdg_header = gen_xdg.addOutputFileArg("xdg-shell-protocol.h");

    // ── Module ────────────────────────────────────────────────────────────
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

    // Add the directory containing the generated header to the C include path.
    mod.addIncludePath(xdg_header.dirname());

    // Link wlroots and wayland-server.
    mod.linkSystemLibrary("wlroots-0.19", .{});
    mod.linkSystemLibrary("wayland-server", .{});

    // ── Extension ─────────────────────────────────────────────────────────
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
