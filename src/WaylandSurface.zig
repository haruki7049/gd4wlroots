/// WaylandSurface manages a single Wayland client surface.
///
/// Each time the client commits a new SHM buffer, we:
///   1. lock the buffer via wlr_buffer_begin_data_ptr_access()
///   2. memcpy pixels into a Godot Image internal buffer  (one CPU copy)
///   3. call ImageTexture.update() to upload to GPU
///
/// The resulting texture is displayed via an owned Sprite2D that is added
/// as a child of the WaylandCompositor node.
const WaylandSurface = @This();

// ── Wayland / wlroots state ───────────────────────────────────────────────

/// The underlying wlr_surface this object tracks.
wlr_surface: *c.wlr.wlr_surface,

/// Listener attached to wlr_surface.events.commit.
commit_listener: c.wlr.wl_listener,

/// Listener attached to wlr_surface.events.destroy.
destroy_listener: c.wlr.wl_listener,

// ── Godot state ───────────────────────────────────────────────────────────

/// The Sprite2D that shows this surface in the scene.
sprite: *Sprite2D,

/// Persistent ImageTexture — we call .update() on it every commit
/// instead of re-creating it, to avoid GPU resource churn.
texture: *ImageTexture,

/// Scratch Image reused every frame. Same size as the surface.
/// Re-created only when the surface dimensions change.
image: *Image,

/// Current surface dimensions, used to detect resize.
width: u32,
height: u32,

// ── Lifecycle ─────────────────────────────────────────────────────────────

/// Create a WaylandSurface and attach Wayland listeners.
/// `parent` must outlive this surface and is used to add/remove the Sprite2D.
pub fn create(
    allocator: Allocator,
    wlr_surface: *c.wlr.wlr_surface,
    parent: *Node,
) !*WaylandSurface {
    const self = try allocator.create(WaylandSurface);

    // Create Godot objects.
    const sprite = Sprite2D.init();
    const texture = ImageTexture.init();
    // Placeholder 1×1 image; real dimensions set on first commit.
    const image = Image.create(1, 1, false, .format_rgba8).?;

    texture.setImage(image);
    // ImageTexture IS-A Texture2D: use upcast (child → parent) not downcast.
    sprite.setTexture(Texture2D.upcast(texture));
    parent.addChild(.upcast(sprite), .{});

    self.* = .{
        .wlr_surface = wlr_surface,
        .commit_listener = undefined,
        .destroy_listener = undefined,
        .sprite = sprite,
        .texture = texture,
        .image = image,
        .width = 0,
        .height = 0,
    };

    // Attach wlroots signal listeners.
    self.commit_listener.notify = onCommit;
    c.wlr.wl_signal_add(&wlr_surface.events.commit, &self.commit_listener);

    self.destroy_listener.notify = onDestroy;
    c.wlr.wl_signal_add(&wlr_surface.events.destroy, &self.destroy_listener);

    return self;
}

/// Free all resources and detach listeners.
pub fn destroy(self: *WaylandSurface, allocator: Allocator) void {
    c.wlr.wl_list_remove(&self.commit_listener.link);
    c.wlr.wl_list_remove(&self.destroy_listener.link);

    self.sprite.destroy();
    if (self.texture.unreference()) self.texture.destroy();
    if (self.image.unreference()) self.image.destroy();

    allocator.destroy(self);
}

// ── Private: texture update ───────────────────────────────────────────────

/// Copy the SHM buffer pixels into the Godot Image, then upload to GPU.
///
/// wlroots 0.19 removed wlr_shm_buffer_* helpers.  The unified replacement is
/// wlr_buffer_begin_data_ptr_access() / wlr_buffer_end_data_ptr_access(), which
/// works for any buffer type that supports CPU-side reads (including wl_shm).
fn uploadBuffer(self: *WaylandSurface, buffer: *c.wlr.wlr_buffer) void {
    var data: ?*anyopaque = null;
    var format: u32 = 0;
    var stride: usize = 0;

    // Lock the buffer for CPU read access.
    // Returns false if the buffer type doesn't support data pointer access
    // (e.g. a pure DMA-BUF with no CPU mapping).
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

    // Rebuild the scratch Image when the surface size changes.
    if (w != self.width or h != self.height) {
        if (self.image.unreference()) self.image.destroy();
        self.image = Image.create(@intCast(w), @intCast(h), false, .format_rgba8).?;
        self.width = w;
        self.height = h;
    }

    const byte_count = h * stride;
    const src: [*]const u8 = @ptrCast(data.?);

    // Write directly into the Image's internal pixel buffer via the
    // gdextension_interface image_ptrw() function — no intermediate allocation.
    const imagePtrw = godot.raw.imagePtrw orelse return;
    const dst = imagePtrw(self.image);
    @memcpy(dst[0..byte_count], src[0..byte_count]);

    // Upload to GPU. ImageTexture.update() reuses the existing GPU resource.
    self.texture.update(self.image);
}

// ── wlroots signal callbacks ──────────────────────────────────────────────

/// Called by wlroots whenever the client commits a new buffer.
fn onCommit(listener: [*c]c.wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const self = c.listenerParent(WaylandSurface, "commit_listener", listener);

    std.log.info("onCommit called", .{});

    const surface_buffer = self.wlr_surface.*.buffer orelse {
        std.log.info("onCommit: buffer is null", .{});
        return;
    };

    std.log.info("onCommit: buffer fond, uploading", .{});
    self.uploadBuffer(&surface_buffer.*.base);
}

/// Called by wlroots when the client destroys its surface.
/// Memory free is deferred to WaylandCompositor.collectDeadSurfaces().
fn onDestroy(listener: [*c]c.wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const self = c.listenerParent(WaylandSurface, "destroy_listener", listener);
    c.wlr.wl_list_remove(&self.commit_listener.link);
    c.wlr.wl_list_remove(&self.destroy_listener.link);
    self.sprite.setVisible(false);
    self.wlr_surface = undefined; // mark dead
}

// ── Imports ───────────────────────────────────────────────────────────────

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Image = godot.class.Image;
const ImageTexture = godot.class.ImageTexture;
const Node = godot.class.Node;
const Sprite2D = godot.class.Sprite2d;
const Texture2D = godot.class.Texture2d;

const c = @import("c.zig");
