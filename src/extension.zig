/// Extension entry point.
/// Registers WaylandCompositor with Godot's ClassDB.
pub fn register(r: *Registry) void {
    r.addModule(WaylandCompositor);
}

const godot = @import("godot");
const Registry = godot.extension.Registry;
const WaylandCompositor = @import("WaylandCompositor.zig");
