pub const wlr = @cImport({
    // Disable the wlroots log macro so it doesn't conflict with Zig's
    @cDefine("WLR_USE_UNSTABLE", "1");
    @cInclude("wlr/backend.h");
    @cInclude("wlr/backend/headless.h"); // provides wlr_headless_backend_create()
    @cInclude("wlr/render/allocator.h");
    @cInclude("wlr/render/wlr_renderer.h");
    @cInclude("wlr/types/wlr_data_device.h");
    @cInclude("wlr/types/wlr_compositor.h");
    @cInclude("wlr/types/wlr_output_layout.h");
    @cInclude("wlr/types/wlr_subcompositor.h");
    @cInclude("wlr/types/wlr_shm.h");
    @cInclude("wlr/types/wlr_xdg_shell.h");
    @cInclude("wlr/types/wlr_buffer.h");
    @cInclude("wlr/util/log.h");

    @cInclude("wayland-server-core.h");
    @cInclude("wayland-server-protocol.h");
});

/// Convenience: cast a wl_listener pointer back to its containing struct.
/// This is the standard wlroots callback pattern.
///
/// Example:
///   const self = listenerParent(MySurface, "commit_listener", listener);
pub inline fn listenerParent(
    comptime T: type,
    comptime field: []const u8,
    listener: *wlr.wl_listener,
) *T {
    return @fieldParentPtr(field, listener);
}
