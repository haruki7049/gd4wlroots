/// WaylandCompositor is a Godot Node2D that acts as a Wayland compositor.
///
/// Add it to your scene tree and it will:
///   - Create a wl_display and advertise a WAYLAND_DISPLAY socket
///   - Accept XDG-Shell client windows and display each as a Sprite2D child
///   - Drive the Wayland event loop from Godot's _process() callback
///
/// This implementation uses SHM buffers with CPU copy (one memcpy per frame
/// per surface).  DMA-BUF / zero-copy can be added later via
/// texture_create_from_native_handle() once a Vulkan path is validated.
const WaylandCompositor = @This();

// ── Fields ────────────────────────────────────────────────────────────────

allocator: Allocator,
base: *Node2D,

/// wlroots core objects — valid after _ready(), null before.
display: ?*c.wl.wl_display = null,
event_loop: ?*c.wl.wl_event_loop = null,
backend: ?*c.wlr.wlr_backend = null,
renderer: ?*c.wlr.wlr_renderer = null,
allocator_wlr: ?*c.wlr.wlr_allocator = null,
compositor: ?*c.wlr.wlr_compositor = null,
xdg_shell: ?*c.wlr.wlr_xdg_shell = null,

/// Socket name written by wlroots (e.g. "wayland-1").
socket_name: [64]u8 = std.mem.zeroes([64]u8),

/// Live surfaces, keyed by their wlr_surface pointer.
surfaces: SurfaceMap,

/// wlroots signal listeners.
new_surface_listener: c.wl.wl_listener = undefined,

// ── gdzig class registration ──────────────────────────────────────────────

pub fn register(r: *Registry) void {
    const class = r.createClass(WaylandCompositor, r.allocator, .auto);
    class.addMethod("get_socket_name", .auto);
}

// ── Lifecycle ─────────────────────────────────────────────────────────────

pub fn create(allocator: *Allocator) !*WaylandCompositor {
    const self = try allocator.create(WaylandCompositor);
    self.* = .{
        .allocator = allocator.*,
        .base = Node2D.init(),
        .surfaces = .{},
    };
    self.base.setInstance(WaylandCompositor, self);
    return self;
}

pub fn destroy(self: *WaylandCompositor, allocator: *Allocator) void {
    self.shutdownWayland();
    self.base.destroy();
    allocator.destroy(self);
}

// ── Godot callbacks ───────────────────────────────────────────────────────

pub fn _ready(self: *WaylandCompositor) void {
    self.initWayland() catch |err| {
        std.log.err("WaylandCompositor: failed to init Wayland: {}", .{err});
    };
}

pub fn _exitTree(self: *WaylandCompositor) void {
    self.shutdownWayland();
}

/// Drive the Wayland event loop.  Called every frame by Godot.
pub fn _process(self: *WaylandCompositor, _: f64) void {
    const el = self.event_loop orelse return;
    // dispatch with 0 ms timeout — non-blocking, handle all pending events.
    _ = c.wl.wl_event_loop_dispatch(el, 0);
    self.collectDeadSurfaces();
}

// ── Public API (exposed to GDScript) ─────────────────────────────────────

/// Returns the WAYLAND_DISPLAY socket name, e.g. "wayland-1".
/// Returns an empty String if the compositor is not yet running.
pub fn getSocketName(self: *WaylandCompositor) String {
    const len = std.mem.indexOfScalar(u8, &self.socket_name, 0) orelse self.socket_name.len;
    return String.fromLatin1(self.socket_name[0..len]);
}

// ── Private: Wayland init / shutdown ─────────────────────────────────────

fn initWayland(self: *WaylandCompositor) !void {
    // Create the wl_display (Wayland server).
    const display = c.wl.wl_display_create() orelse return error.DisplayCreateFailed;
    self.display = display;
    self.event_loop = c.wl.wl_display_get_event_loop(display);

    // Create a headless wlroots backend (no GPU device needed for SHM).
    const backend = c.wlr.wlr_headless_backend_create(display) orelse return error.BackendCreateFailed;
    self.backend = backend;

    // Create a no-op wlr_renderer (not used for SHM, but wlroots requires one).
    const renderer = c.wlr.wlr_renderer_autocreate(backend) orelse return error.RendererCreateFailed;
    self.renderer = renderer;
    c.wlr.wlr_renderer_init_wl_display(renderer, display);

    // Allocator (needed by compositor).
    self.allocator_wlr = c.wlr.wlr_allocator_autocreate(backend, renderer);

    // Advertise wl_compositor and wl_shm globals to clients.
    self.compositor = c.wlr.wlr_compositor_create(display, 5, renderer);
    _ = c.wlr.wlr_shm_create(display, 1, &[_]u32{c.wlr.WL_SHM_FORMAT_ARGB8888});

    // XDG Shell — handles modern Wayland application windows.
    const xdg_shell = c.wlr.wlr_xdg_shell_create(display, 3) orelse return error.XdgShellCreateFailed;
    self.xdg_shell = xdg_shell;

    // Listen for new XDG surfaces (new application windows).
    self.new_surface_listener.notify = onNewXdgSurface;
    c.wl.wl_signal_add(&xdg_shell.events.new_toplevel, &self.new_surface_listener);

    // Start the backend and open a socket.
    if (c.wlr.wlr_backend_start(backend) == 0) return error.BackendStartFailed;

    const socket_cstr = c.wl.wl_display_add_socket_auto(display) orelse return error.SocketFailed;
    const socket_slice = std.mem.span(socket_cstr);
    const copy_len = @min(socket_slice.len, self.socket_name.len - 1);
    @memcpy(self.socket_name[0..copy_len], socket_slice[0..copy_len]);

    std.log.info("WaylandCompositor: listening on {s}", .{socket_cstr});
}

fn shutdownWayland(self: *WaylandCompositor) void {
    // Destroy all tracked surfaces.
    var it = self.surfaces.valueIterator();
    while (it.next()) |surf| {
        surf.*.destroy(self.allocator);
    }
    self.surfaces.deinit(self.allocator);
    self.surfaces = .{};

    if (self.display) |d| {
        c.wl.wl_display_destroy(d);
        self.display = null;
    }
}

/// Remove surfaces whose wlr_surface was destroyed (marked dead in onDestroy).
fn collectDeadSurfaces(self: *WaylandCompositor) void {
    var to_remove = std.ArrayList(*c.wlr.wlr_surface).init(self.allocator);
    defer to_remove.deinit();

    var it = self.surfaces.iterator();
    while (it.next()) |entry| {
        // A surface is "dead" when we cleared its wlr_surface pointer in onDestroy.
        if (@intFromPtr(entry.value_ptr.*.wlr_surface) == 0) {
            entry.value_ptr.*.destroy(self.allocator);
            to_remove.append(entry.key_ptr.*) catch {};
        }
    }
    for (to_remove.items) |key| {
        _ = self.surfaces.remove(key);
    }
}

// ── wlroots signal callbacks ──────────────────────────────────────────────

/// Called when an XDG toplevel (application window) is created.
fn onNewXdgSurface(listener: [*c]c.wl.wl_listener, data: ?*anyopaque) callconv(.C) void {
    const self = c.listenerParent(WaylandCompositor, "new_surface_listener", listener);
    const toplevel: *c.wlr.wlr_xdg_toplevel = @ptrCast(@alignCast(data orelse return));
    const wlr_surface = toplevel.base.surface;

    const surf = WaylandSurface.create(
        self.allocator,
        wlr_surface,
        .upcast(self.base),
    ) catch |err| {
        std.log.err("WaylandCompositor: failed to create surface: {}", .{err});
        return;
    };

    self.surfaces.put(self.allocator, wlr_surface, surf) catch |err| {
        std.log.err("WaylandCompositor: failed to track surface: {}", .{err});
        surf.destroy(self.allocator);
    };
}

// ── Imports ───────────────────────────────────────────────────────────────

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const Node2D = godot.class.Node2d;
const String = godot.builtin.String;

const c = @import("c.zig");
const WaylandSurface = @import("WaylandSurface.zig");

const SurfaceMap = std.AutoHashMapUnmanaged(*c.wlr.wlr_surface, *WaylandSurface);
