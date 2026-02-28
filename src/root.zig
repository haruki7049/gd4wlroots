/// Extension entry point.
/// Registers WaylandCompositor with Godot's ClassDB.
pub fn register(r: *Registry) void {
    r.addModule(WaylandCompositor);
}

pub const gdwlroots_init = godot.init(.{
    .register_fn = register,
});

const godot = @import("godot");
const Registry = godot.extension.Registry;
const WaylandCompositor = @import("wayland_compositor.zig");
