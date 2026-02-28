/// WaylandCompositor — Godot node that acts as a Wayland compositor.
///
/// # What this does
///
/// A Wayland compositor is a server that Wayland client applications (foot,
/// weston-terminal, etc.) connect to for rendering.  This node embeds such a
/// server inside Godot, making Godot itself the compositor.
///
/// When this node is added to the scene tree, it:
///   1. Creates a wl_display — the Wayland server root object.
///   2. Opens a Unix socket (e.g. "wayland-0") that clients connect to.
///   3. Advertises Wayland protocol globals (wl_compositor, wl_shm,
///      xdg_wm_base, wl_seat …) so standard Wayland applications can run.
///   4. Drives the Wayland event loop from Godot's _process() callback so
///      client events are handled once per game frame without blocking.
///
/// Each connecting client window becomes a WaylandSurface child, which owns
/// a Sprite2D.  Pixel data flows from the client's SHM buffer into a Godot
/// ImageTexture on every wl_surface.commit().
///
/// # Architecture
///
///   [Wayland client (e.g. foot)]
///         │  wl_surface.commit()          Unix socket
///         ▼
///   [wlroots event loop]  ←── wl_event_loop_dispatch() called from _process()
///         │  onNewXdgSurface() / onCommit() callbacks
///         ▼
///   [WaylandSurface.uploadBuffer()]  — CPU pixel copy + XRGB→RGBA swizzle
///         │  ImageTexture.update()
///         ▼
///   [Godot GPU texture]  →  Sprite2D  →  screen
///
/// # Limitations (current implementation)
///
///   - SHM (shared-memory) buffers only; no DMA-BUF / zero-copy path.
///   - No input forwarding (keyboard / pointer events are not sent to clients).
///   - Single 1280×720 headless virtual output; no dynamic resize.
const WaylandCompositor = @This();

// ── Fields ────────────────────────────────────────────────────────────────

allocator: Allocator,

/// The underlying Godot Node2D.  WaylandSurface Sprite2D children are added
/// to this node, so they inherit its transform in the scene tree.
base: *Node2D,

/// The Wayland server root object.  Owns the Unix socket, the event loop,
/// and the registry of protocol globals.  Created in _ready(), destroyed
/// in _exitTree() via shutdownWayland().
display: ?*c.wlr.wl_display = null,

/// The event loop owned by wl_display.  We call wl_event_loop_dispatch()
/// on it every frame to process pending client messages without blocking.
event_loop: ?*c.wlr.wl_event_loop = null,

/// wlroots headless backend — a virtual GPU output with no physical monitor.
/// Required because wlroots ties its object graph to a backend, even when
/// all rendering is handled externally (here, by Godot).
backend: ?*c.wlr.wlr_backend = null,

/// wlroots renderer.  Not used for actual GPU rendering in this implementation,
/// but wlroots requires one to initialise wl_shm and advertise supported pixel
/// formats to connecting clients via wlr_renderer_init_wl_shm().
renderer: ?*c.wlr.wlr_renderer = null,

/// wlroots allocator — manages GPU buffer allocation.  Required by
/// wlr_compositor even though we use only CPU-side SHM buffers.
allocator_wlr: ?*c.wlr.wlr_allocator = null,

/// Implements the wl_compositor Wayland global.  Clients use it to create
/// wl_surface objects — the fundamental drawable unit in Wayland.
compositor: ?*c.wlr.wlr_compositor = null,

/// Implements the xdg_wm_base Wayland global (XDG Shell protocol).
/// XDG Shell is the standard protocol for desktop application windows;
/// it adds title, min/max/close and resize negotiation on top of wl_surface.
xdg_shell: ?*c.wlr.wlr_xdg_shell = null,

/// Input seat — represents a logical set of input devices (keyboard + pointer
/// + touch).  Many clients check for a seat at startup even if they do not
/// actively use input, so we advertise one even though we don't forward events.
seat: ?*c.wlr.wlr_seat = null,

/// The socket name chosen by wlroots (e.g. "wayland-0").
/// Clients read this from the WAYLAND_DISPLAY environment variable.
socket_name: [64]u8 = std.mem.zeroes([64]u8),

/// All currently active client surfaces, keyed by their wlr_surface pointer.
/// Surfaces are inserted in onNewXdgSurface() and removed (lazily) by
/// collectDeadSurfaces() after the client destroys its wl_surface.
surfaces: SurfaceMap,

/// wlroots signal listener for xdg_shell.events.new_toplevel.
/// Fires whenever a client creates a new XDG toplevel (application window).
new_surface_listener: c.wlr.wl_listener = undefined,

// ── GDExtension class registration ───────────────────────────────────────

/// Called once at extension load time by gdzig to register this type with
/// Godot's ClassDB.  After registration, "WaylandCompositor" is available
/// as a node type in scenes and from GDScript, just like built-in nodes.
pub fn register(r: *Registry) void {
    const class = r.createClass(WaylandCompositor, r.allocator, .auto);
    // Expose getSocketName() as get_socket_name() in GDScript so scenes can
    // pass the socket name to child processes via WAYLAND_DISPLAY.
    class.addMethod("get_socket_name", .auto);
}

// ── Lifecycle ─────────────────────────────────────────────────────────────

/// Called by gdzig when Godot instantiates this node.
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

/// Called by gdzig when Godot frees this node.
pub fn destroy(self: *WaylandCompositor, allocator: *Allocator) void {
    self.shutdownWayland();
    self.base.destroy();
    allocator.destroy(self);
}

// ── Godot callbacks ───────────────────────────────────────────────────────

/// Godot calls _ready() once after the node enters the scene tree.
/// This is the earliest safe point to start the Wayland server because
/// the viewport and parent nodes are guaranteed to exist.
pub fn _ready(self: *WaylandCompositor) void {
    // Enable _process() so the Wayland event loop is driven every frame.
    self.base.setProcess(true);

    self.initWayland() catch |err| {
        std.log.err("WaylandCompositor: failed to init Wayland: {}", .{err});
    };
}

/// Godot calls _process() once per rendered frame.
///
/// wl_event_loop_dispatch() with timeout=0 is non-blocking: it processes all
/// messages clients have already sent and returns immediately if the queue is
/// empty.  This keeps Godot's frame rate unaffected by slow clients.
///
/// wl_display_flush_clients() sends any queued outbound messages (configure
/// events, frame callbacks, etc.) back to clients over the socket.
pub fn _process(self: *WaylandCompositor, _: f64) void {
    const display = self.display orelse return;
    const el = self.event_loop orelse return;

    // Timeout 0: non-blocking — process all queued events, then return.
    _ = c.wlr.wl_event_loop_dispatch(el, 0);

    // Flush outbound messages accumulated during dispatch.
    c.wlr.wl_display_flush_clients(display);

    self.collectDeadSurfaces();
}

/// Godot calls _exitTree() when this node is removed from the scene tree.
/// We shut down the Wayland server here so all client connections are closed
/// and all wlroots resources are freed before the node is destroyed.
pub fn _exitTree(self: *WaylandCompositor) void {
    self.shutdownWayland();
}

// ── Public API (callable from GDScript) ──────────────────────────────────

/// Returns the WAYLAND_DISPLAY socket name (e.g. "wayland-0").
/// Returns an empty String before _ready() has run.
///
/// GDScript usage:
///   var sock = $WaylandCompositor.get_socket_name()
///   OS.create_process("foot", [], {"WAYLAND_DISPLAY": sock})
pub fn getSocketName(self: *WaylandCompositor) String {
    const len = std.mem.indexOfScalar(u8, &self.socket_name, 0) orelse self.socket_name.len;
    return String.fromLatin1(self.socket_name[0..len]);
}

// ── Private: Wayland init / shutdown ─────────────────────────────────────

/// Initialise the Wayland server and all required wlroots objects.
///
/// Creation order matters — each object depends on those created above it:
///
///   wl_display
///     └─ wl_event_loop         (owned by wl_display)
///          └─ wlr_backend      (headless: no real monitor)
///               ├─ wlr_renderer
///               └─ wlr_allocator
///                    └─ wlr_compositor   (wl_surface management)
///                         └─ wlr_xdg_shell  (window protocol)
fn initWayland(self: *WaylandCompositor) !void {
    // wl_display is the root of a Wayland server.  It owns the Unix socket,
    // the event loop, and the registry of protocol globals.
    const display = c.wlr.wl_display_create() orelse return error.DisplayCreateFailed;
    self.display = display;

    // wlroots 0.19 changed wlr_headless_backend_create() to accept
    // wl_event_loop* instead of wl_display*, so retrieve it first.
    const event_loop = c.wlr.wl_display_get_event_loop(display);
    self.event_loop = event_loop;

    // Headless backend: provides a virtual GPU context with no physical output.
    // We use it because wlroots requires a backend to exist, but Godot itself
    // renders all visible content via Sprite2D nodes.
    const backend = c.wlr.wlr_headless_backend_create(event_loop) orelse
        return error.BackendCreateFailed;
    self.backend = backend;

    // The renderer is not used for rendering here, but wlroots needs one to
    // initialise wl_shm and advertise supported pixel formats to clients.
    const renderer = c.wlr.wlr_renderer_autocreate(backend) orelse
        return error.RendererCreateFailed;
    self.renderer = renderer;
    _ = c.wlr.wlr_renderer_init_wl_display(renderer, display);

    // Required by wlr_compositor even for SHM-only compositing.
    self.allocator_wlr = c.wlr.wlr_allocator_autocreate(backend, renderer);

    // wl_compositor global: clients use it to create wl_surface objects.
    self.compositor = c.wlr.wlr_compositor_create(display, 5, renderer);

    // wl_subcompositor: allows composing a surface from multiple sub-regions.
    // Used e.g. for embedded video overlays inside a window.
    _ = c.wlr.wlr_subcompositor_create(display);

    // wl_data_device_manager: clipboard and drag-and-drop support.
    _ = c.wlr.wlr_data_device_manager_create(display);

    // wl_seat: represents a set of input devices (keyboard + pointer + touch).
    // Many clients check for a seat at startup even without active input use.
    self.seat = c.wlr.wlr_seat_create(display, "seat0");

    // Create a logical output layout and attach a 1280×720 headless monitor.
    // Clients query the output layout to know available screen dimensions;
    // without an output, some clients (e.g. foot) refuse to draw anything.
    const output_layout = c.wlr.wlr_output_layout_create(display) orelse
        return error.OutputLayoutCreateFailed;
    const headless_output = c.wlr.wlr_headless_add_output(backend, 1280, 720);
    _ = c.wlr.wlr_output_layout_add_auto(output_layout, headless_output);

    // Commit the output state to activate the virtual monitor.
    var state: c.wlr.wlr_output_state = undefined;
    c.wlr.wlr_output_state_init(&state);
    c.wlr.wlr_output_state_set_enabled(&state, true);
    _ = c.wlr.wlr_output_commit_state(headless_output, &state);
    c.wlr.wlr_output_state_finish(&state);

    // Advertise wl_shm and register all pixel formats supported by the renderer.
    // wlr_renderer_init_wl_shm() MUST be used instead of calling wlr_shm_create()
    // directly: wlr_shm_create() asserts that the renderer has already registered
    // ARGB8888 and XRGB8888 before it is called, so bypassing this function
    // causes an immediate abort.
    _ = c.wlr.wlr_renderer_init_wl_shm(renderer, display);

    // XDG Shell (xdg_wm_base): the standard protocol for desktop app windows.
    // Version 3 is widely supported by clients as of 2024.
    const xdg_shell = c.wlr.wlr_xdg_shell_create(display, 3) orelse
        return error.XdgShellCreateFailed;
    self.xdg_shell = xdg_shell;

    // Register a listener for new XDG toplevels (new application windows).
    // onNewXdgSurface() is called whenever a client creates a new window.
    self.new_surface_listener.notify = onNewXdgSurface;
    c.wlr.wl_signal_add(&xdg_shell.*.events.new_toplevel, &self.new_surface_listener);

    // Start the backend (initialises the headless GPU context).
    if (!c.wlr.wlr_backend_start(backend)) return error.BackendStartFailed;

    // Open the Unix socket.  wl_display_add_socket_auto() picks the first free
    // name ("wayland-0", "wayland-1", …) under $XDG_RUNTIME_DIR.
    const socket_cstr = c.wlr.wl_display_add_socket_auto(display) orelse
        return error.SocketFailed;
    const socket_slice = std.mem.span(socket_cstr);
    const copy_len = @min(socket_slice.len, self.socket_name.len - 1);
    @memcpy(self.socket_name[0..copy_len], socket_slice[0..copy_len]);

    std.log.info("WaylandCompositor: listening on {s}", .{socket_cstr});
}

/// Tear down the Wayland server and free all associated resources.
///
/// wl_display_destroy() closes the socket and recursively destroys all
/// protocol objects, so wlr_backend / wlr_renderer / etc. do not need to be
/// freed individually — wlroots handles that via wl_display destroy listeners.
fn shutdownWayland(self: *WaylandCompositor) void {
    // Destroy WaylandSurface wrappers first so their Godot Sprite2D nodes
    // are freed before wl_display (and its surfaces) disappear.
    var it = self.surfaces.valueIterator();
    while (it.next()) |surf| {
        surf.*.destroy(self.allocator);
    }
    self.surfaces.deinit(self.allocator);
    self.surfaces = .{};

    // Detach the xdg_shell listener before destroying the display to prevent
    // a use-after-free if wlroots fires the signal during teardown.
    if (self.xdg_shell != null) {
        c.wlr.wl_list_remove(&self.new_surface_listener.link);
        self.xdg_shell = null;
    }

    if (self.display) |d| {
        // Destroys the socket, event loop, and all wlroots objects in one call.
        c.wlr.wl_display_destroy(d);
        self.display = null;
    }
}

/// Free surface entries whose client has disconnected.
///
/// We cannot call WaylandSurface.destroy() directly from inside the wlroots
/// onDestroy() callback because that callback runs from within signal dispatch,
/// and freeing memory mid-dispatch is unsafe.  Instead, onDestroy() sets
/// wlr_surface to undefined (pointer value 0) as a "dead" marker, and this
/// function collects those entries safely on the next _process() tick.
fn collectDeadSurfaces(self: *WaylandCompositor) void {
    var to_remove: std.ArrayList(*c.wlr.wlr_surface) = .empty;
    defer to_remove.deinit(self.allocator);

    var it = self.surfaces.iterator();
    while (it.next()) |entry| {
        // wlr_surface == undefined means onDestroy() already ran for this entry.
        if (@intFromPtr(entry.value_ptr.*.wlr_surface) == 0) {
            entry.value_ptr.*.destroy(self.allocator);
            to_remove.append(self.allocator, entry.key_ptr.*) catch {};
        }
    }
    for (to_remove.items) |key| {
        _ = self.surfaces.remove(key);
    }
}

// ── wlroots signal callbacks ──────────────────────────────────────────────

/// Called by wlroots when a client creates a new XDG toplevel window.
///
/// `data` points to the new wlr_xdg_toplevel.  We create a WaylandSurface
/// wrapper and add its Sprite2D to the scene so the window content will
/// appear once the client sends its first commit.
///
/// The (listener, data) signature is mandated by the C Wayland signal API:
///   void (*notify)(struct wl_listener *listener, void *data)
fn onNewXdgSurface(listener: [*c]c.wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const self = c.listenerParent(WaylandCompositor, "new_surface_listener", listener);
    const toplevel: *c.wlr.wlr_xdg_toplevel = @ptrCast(@alignCast(data orelse return));
    const wlr_surface = toplevel.*.base.*.surface;

    const surf = WaylandSurface.create(
        self.allocator,
        wlr_surface,
        toplevel,
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

/// Map from wlr_surface pointer to its WaylandSurface wrapper.
/// The pointer is a stable key because wlroots never reuses a wlr_surface
/// address while that surface is still alive.
const SurfaceMap = std.AutoHashMapUnmanaged(*c.wlr.wlr_surface, *WaylandSurface);
