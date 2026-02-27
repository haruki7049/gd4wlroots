/// WaylandSurface manages a single Wayland client surface.
///
/// Each time the client commits a new SHM buffer, we:
///   1. mmap the buffer pixels (they are already in CPU memory)
///   2. memcpy into a Godot Image internal buffer  (one CPU copy)
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

    // Create Godot objects
    const sprite = Sprite2D.init();
    const texture = ImageTexture.init();
    // Placeholder 1×1 image; real dimensions set on first commit.
    const image = Image.create(1, 1, false, .format_rgba8).?;

    texture.setImage(image);
    sprite.setTexture(Texture2D.downcast(texture).?);
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

    // Clean up Godot resources
    self.sprite.destroy();
    if (self.texture.unreference()) self.texture.destroy();
    if (self.image.unreference()) self.image.destroy();

    allocator.destroy(self);
}

// ── Private: texture update ───────────────────────────────────────────────

/// Copy the SHM buffer pixels into the Godot Image, then upload to GPU.
fn uploadShmBuffer(self: *WaylandSurface, buf: *c.wlr.wlr_shm_buffer) void {
    const w: u32 = @intCast(self.wlr_surface.current.width);
    const h: u32 = @intCast(self.wlr_surface.current.height);

    // Rebuild Image if the surface size changed.
    if (w != self.width or h != self.height) {
        if (self.image.unreference()) self.image.destroy();
        self.image = Image.create(@intCast(w), @intCast(h), false, .format_rgba8).?;
        self.width = w;
        self.height = h;
    }

    // Begin access to the SHM pixel data (locks the buffer for CPU read).
    c.wlr.wlr_shm_buffer_begin_access(buf);
    defer c.wlr.wlr_shm_buffer_end_access(buf);

    const src_pixels: [*]const u8 = @ptrCast(buf.data);
    const stride: u32 = @intCast(buf.stride);
    const byte_count = h * stride;

    // Get a writable pointer to the Image's internal pixel buffer.
    // gdextension_interface exposes this as image_ptrw().
    const dst_pixels = godot.raw.imagePtrw(self.image);
    @memcpy(dst_pixels[0..byte_count], src_pixels[0..byte_count]);

    // Upload the modified Image to the GPU texture.
    // ImageTexture.update() re-uses the existing GPU resource.
    self.texture.update(self.image);
}

// ── wlroots signal callbacks ──────────────────────────────────────────────

/// Called by wlroots whenever the client commits a new buffer.
fn onCommit(listener: [*c]c.wlr.wl_listener, _: ?*anyopaque) callconv(.C) void {
    const self = c.listenerParent(WaylandSurface, "commit_listener", listener);
    const surface = self.wlr_surface;

    // Only handle SHM buffers in this CPU-copy implementation.
    // DMA-BUF support would be added here later via wlr_dmabuf_v1_buffer_try_from_buffer().
    const buffer = surface.buffer orelse return;
    const shm_buf = c.wlr.wlr_shm_buffer_try_from_buffer(buffer) orelse return;

    self.uploadShmBuffer(shm_buf);
}

/// Called by wlroots when the client destroys its surface.
/// We cannot free ourselves here (we're inside a C callback), so we just
/// mark ourselves as dead; WaylandCompositor cleans up on the next _process().
fn onDestroy(listener: [*c]c.wlr.wl_listener, _: ?*anyopaque) callconv(.C) void {
    const self = c.listenerParent(WaylandSurface, "destroy_listener", listener);
    // Detach listeners immediately to prevent double-fire.
    c.wlr.wl_list_remove(&self.commit_listener.link);
    c.wlr.wl_list_remove(&self.destroy_listener.link);
    // Hide the sprite so there is no visual artifact until GC.
    self.sprite.setVisible(false);
    // NOTE: actual memory free happens in WaylandCompositor.collectDeadSurfaces().
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
