const WaylandSurface = @This();

wlr_surface: *c.wlr.wlr_surface,
toplevel: *c.wlr.wlr_xdg_toplevel,
commit_listener: c.wlr.wl_listener,
destroy_listener: c.wlr.wl_listener,
sprite: *Sprite2D,
texture: *ImageTexture,
image: *Image,
width: u32,
height: u32,

pub fn create(
    allocator: Allocator,
    wlr_surface: *c.wlr.wlr_surface,
    toplevel: *c.wlr.wlr_xdg_toplevel,
    parent: *Node,
) !*WaylandSurface {
    const self = try allocator.create(WaylandSurface);

    const sprite = Sprite2D.init();
    const texture = ImageTexture.init();
    const image = Image.create(1, 1, false, .format_rgba8).?;

    texture.setImage(image);
    sprite.setTexture(Texture2D.upcast(texture));
    parent.addChild(.upcast(sprite), .{});

    self.* = .{
        .wlr_surface = wlr_surface,
        .toplevel = toplevel,
        .commit_listener = undefined,
        .destroy_listener = undefined,
        .sprite = sprite,
        .texture = texture,
        .image = image,
        .width = 0,
        .height = 0,
    };

    self.commit_listener.notify = onCommit;
    c.wlr.wl_signal_add(&wlr_surface.events.commit, &self.commit_listener);

    self.destroy_listener.notify = onDestroy;
    c.wlr.wl_signal_add(&wlr_surface.events.destroy, &self.destroy_listener);

    return self;
}

pub fn destroy(self: *WaylandSurface, allocator: Allocator) void {
    c.wlr.wl_list_remove(&self.commit_listener.link);
    c.wlr.wl_list_remove(&self.destroy_listener.link);

    self.sprite.destroy();
    if (self.texture.unreference()) self.texture.destroy();
    if (self.image.unreference()) self.image.destroy();

    allocator.destroy(self);
}

fn uploadBuffer(self: *WaylandSurface, buffer: *c.wlr.wlr_buffer) void {
    var data: ?*anyopaque = null;
    var format: u32 = 0;
    var stride: usize = 0;

    if (!c.wlr.wlr_buffer_begin_data_ptr_access(
        buffer,
        c.wlr.WLR_BUFFER_DATA_PTR_ACCESS_READ,
        &data,
        &format,
        &stride,
    )) return;
    defer c.wlr.wlr_buffer_end_data_ptr_access(buffer);

    const w: u32 = @intCast(self.wlr_surface.*.current.width);
    const h: u32 = @intCast(self.wlr_surface.*.current.height);

    if (w == 0 or h == 0) return;

    if (w != self.width or h != self.height) {
        if (self.image.unreference()) self.image.destroy();
        self.image = Image.create(@intCast(w), @intCast(h), false, .format_rgba8).?;
        self.width = w;
        self.height = h;
    }

    const byte_count = h * stride;
    const src: [*]const u8 = @ptrCast(data.?);

    const imagePtrw = godot.raw.imagePtrw orelse return;
    const dst = imagePtrw(self.image);
    @memcpy(dst[0..byte_count], src[0..byte_count]);

    self.texture.update(self.image);
}

fn onCommit(listener: [*c]c.wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const self = c.listenerParent(WaylandSurface, "commit_listener", listener);

    const xdg_surface = self.toplevel.*.base;

    if (xdg_surface.*.initial_commit) {
        std.log.info("onCommit: initial commit, sending configure", .{});
        _ = c.wlr.wlr_xdg_toplevel_set_size(self.toplevel, 0, 0);
        _ = c.wlr.wlr_xdg_toplevel_set_activated(self.toplevel, true);
        return;
    }

    const surface_buffer = self.wlr_surface.*.buffer orelse {
        std.log.info("onCommit: buffer is null", .{});
        return;
    };

    std.log.info("onCommit: buffer found, uploading", .{});
    self.uploadBuffer(&surface_buffer.*.base);
}

fn onDestroy(listener: [*c]c.wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const self = c.listenerParent(WaylandSurface, "destroy_listener", listener);
    c.wlr.wl_list_remove(&self.commit_listener.link);
    c.wlr.wl_list_remove(&self.destroy_listener.link);
    self.sprite.setVisible(false);
    self.wlr_surface = undefined;
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Image = godot.class.Image;
const ImageTexture = godot.class.ImageTexture;
const Node = godot.class.Node;
const Sprite2D = godot.class.Sprite2d;
const Texture2D = godot.class.Texture2d;

const c = @import("c.zig");
