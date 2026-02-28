/// C bindings for wlroots and wayland-server.
///
/// All headers are placed in ONE @cImport block intentionally.
/// If they were split into separate blocks (e.g. one for wayland, one for
/// wlroots), Zig would generate two independent cimport modules.  Shared C
/// types such as wl_event_loop would then appear as two distinct opaque types,
/// causing "expected T, found T" type-mismatch errors at call sites.
///
/// Link requirements (in build.zig):
///   mod.linkSystemLibrary("wlroots-0.19", .{});
///   mod.linkSystemLibrary("wayland-server", .{});
pub const wlr = @cImport({
    // WLR_USE_UNSTABLE suppresses the compile-time warning that wlroots
    // considers its API unstable and subject to change between releases.
    @cDefine("WLR_USE_UNSTABLE", "1");

    // --- wlroots backend ---
    // wlr_backend abstracts "where to send rendered output".
    // wlr_headless_backend_create() is in the separate headless header.
    @cInclude("wlr/backend.h");
    @cInclude("wlr/backend/headless.h");

    // --- wlroots rendering ---
    // wlr_renderer and wlr_allocator are required by wlr_compositor even
    // when we do not perform any GPU rendering ourselves.
    @cInclude("wlr/render/allocator.h");
    @cInclude("wlr/render/wlr_renderer.h");

    // --- wlroots Wayland protocol implementations ---
    // Each header implements one Wayland protocol global that clients can use.
    @cInclude("wlr/types/wlr_data_device.h");   // clipboard / drag-and-drop
    @cInclude("wlr/types/wlr_compositor.h");    // wl_surface management
    @cInclude("wlr/types/wlr_output_layout.h"); // logical screen arrangement
    @cInclude("wlr/types/wlr_subcompositor.h"); // wl_subsurface support
    @cInclude("wlr/types/wlr_shm.h");           // shared-memory buffers (SHM)
    @cInclude("wlr/types/wlr_xdg_shell.h");     // application windows (XDG Shell)
    @cInclude("wlr/types/wlr_buffer.h");        // generic buffer access API
    @cInclude("wlr/util/log.h");                // wlroots logging helpers

    // --- wayland-server ---
    // Core server types: wl_display, wl_event_loop, wl_listener, wl_signal …
    // Placed after wlroots headers because wlroots already pulls in
    // wayland-server-core.h internally; keeping everything in one block
    // ensures all definitions share the same translation unit.
    @cInclude("wayland-server-core.h");
    @cInclude("wayland-server-protocol.h");
});

/// Cast a wl_listener pointer back to the struct that contains it.
///
/// wlroots delivers all signals by passing a pointer to the wl_listener that
/// was registered.  The canonical pattern to recover the parent struct is a
/// @fieldParentPtr cast, which this helper wraps for readability.
///
/// Usage:
///   const self = c.listenerParent(MySurface, "commit_listener", listener);
pub inline fn listenerParent(
    comptime T: type,
    comptime field: []const u8,
    listener: *wlr.wl_listener,
) *T {
    return @fieldParentPtr(field, listener);
}
