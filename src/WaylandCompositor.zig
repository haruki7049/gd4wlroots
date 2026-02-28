const WaylandCompositor = @This();

allocator: Allocator,
base: *Node2D,

display: ?*c.wlr.wl_display = null,
event_loop: ?*c.wlr.wl_event_loop = null,
backend: ?*c.wlr.wlr_backend = null,
renderer: ?*c.wlr.wlr_renderer = null,
allocator_wlr: ?*c.wlr.wlr_allocator = null,
compositor: ?*c.wlr.wlr_compositor = null,
xdg_shell: ?*c.wlr.wlr_xdg_shell = null,
seat: ?*c.wlr.wlr_seat = null,

socket_name: [64]u8 = std.mem.zeroes([64]u8),
surfaces: SurfaceMap,
new_surface_listener: c.wlr.wl_listener = undefined,

pub fn register(r: *Registry) void {
    const class = r.createClass(WaylandCompositor, r.allocator, .auto);
    class.addMethod("get_socket_name", .auto);
}

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

pub fn _ready(self: *WaylandCompositor) void {
    self.base.setProcess(true);

    self.initWayland() catch |err| {
        std.log.err("WaylandCompositor: failed to init Wayland: {}", .{err});
    };
}

pub fn _process(self: *WaylandCompositor, _: f64) void {
    const display = self.display orelse return;
    const el = self.event_loop orelse return;

    _ = c.wlr.wl_event_loop_dispatch(el, 0);
    c.wlr.wl_display_flush_clients(display);
    self.collectDeadSurfaces();
}

pub fn _exitTree(self: *WaylandCompositor) void {
    self.shutdownWayland();
}

pub fn getSocketName(self: *WaylandCompositor) String {
    const len = std.mem.indexOfScalar(u8, &self.socket_name, 0) orelse self.socket_name.len;
    return String.fromLatin1(self.socket_name[0..len]);
}

fn initWayland(self: *WaylandCompositor) !void {
    const display = c.wlr.wl_display_create() orelse return error.DisplayCreateFailed;
    self.display = display;

    const event_loop = c.wlr.wl_display_get_event_loop(display);
    self.event_loop = event_loop;

    const backend = c.wlr.wlr_headless_backend_create(event_loop) orelse return error.BackendCreateFailed;
    self.backend = backend;

    const renderer = c.wlr.wlr_renderer_autocreate(backend) orelse return error.RendererCreateFailed;
    self.renderer = renderer;
    _ = c.wlr.wlr_renderer_init_wl_display(renderer, display);

    self.allocator_wlr = c.wlr.wlr_allocator_autocreate(backend, renderer);

    self.compositor = c.wlr.wlr_compositor_create(display, 5, renderer);
    _ = c.wlr.wlr_subcompositor_create(display);
    _ = c.wlr.wlr_data_device_manager_create(display);
    self.seat = c.wlr.wlr_seat_create(display, "seat0");

    const output_layout = c.wlr.wlr_output_layout_create(display) orelse return error.OutputLayoutCreateFailed;
    const headless_output = c.wlr.wlr_headless_add_output(backend, 1280, 720);
    _ = c.wlr.wlr_output_layout_add_auto(output_layout, headless_output);

    var state: c.wlr.wlr_output_state = undefined;
    c.wlr.wlr_output_state_init(&state);
    c.wlr.wlr_output_state_set_enabled(&state, true);
    _ = c.wlr.wlr_output_commit_state(headless_output, &state);
    c.wlr.wlr_output_state_finish(&state);

    _ = c.wlr.wlr_renderer_init_wl_shm(renderer, display);

    const xdg_shell = c.wlr.wlr_xdg_shell_create(display, 3) orelse return error.XdgShellCreateFailed;
    self.xdg_shell = xdg_shell;

    self.new_surface_listener.notify = onNewXdgSurface;
    c.wlr.wl_signal_add(&xdg_shell.*.events.new_toplevel, &self.new_surface_listener);

    if (!c.wlr.wlr_backend_start(backend)) return error.BackendStartFailed;

    const socket_cstr = c.wlr.wl_display_add_socket_auto(display) orelse return error.SocketFailed;
    const socket_slice = std.mem.span(socket_cstr);
    const copy_len = @min(socket_slice.len, self.socket_name.len - 1);
    @memcpy(self.socket_name[0..copy_len], socket_slice[0..copy_len]);

    std.log.info("WaylandCompositor: listening on {s}", .{socket_cstr});
}

fn shutdownWayland(self: *WaylandCompositor) void {
    var it = self.surfaces.valueIterator();
    while (it.next()) |surf| {
        surf.*.destroy(self.allocator);
    }
    self.surfaces.deinit(self.allocator);
    self.surfaces = .{};

    if (self.xdg_shell != null) {
        c.wlr.wl_list_remove(&self.new_surface_listener.link);
        self.xdg_shell = null;
    }

    if (self.display) |d| {
        c.wlr.wl_display_destroy(d);
        self.display = null;
    }
}

fn collectDeadSurfaces(self: *WaylandCompositor) void {
    var to_remove: std.array_list.Aligned(*c.wlr.wlr_surface, null) = .empty;
    defer to_remove.deinit(self.allocator);

    var it = self.surfaces.iterator();
    while (it.next()) |entry| {
        if (@intFromPtr(entry.value_ptr.*.wlr_surface) == 0) {
            entry.value_ptr.*.destroy(self.allocator);
            to_remove.append(self.allocator, entry.key_ptr.*) catch {};
        }
    }
    for (to_remove.items) |key| {
        _ = self.surfaces.remove(key);
    }
}

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

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const Node2D = godot.class.Node2d;
const String = godot.builtin.String;

const c = @import("c.zig");
const WaylandSurface = @import("WaylandSurface.zig");

const SurfaceMap = std.AutoHashMapUnmanaged(*c.wlr.wlr_surface, *WaylandSurface);
