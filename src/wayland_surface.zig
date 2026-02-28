/// WaylandSurface — tracks one Wayland client window and renders it in Godot.
///
/// # Relationship to Wayland concepts
///
/// In Wayland, a wl_surface is the fundamental drawable unit — roughly a
/// window, but without title bars or decorations.  An XDG toplevel wraps a
/// surface and adds desktop-window semantics: title, min/max/close, and a
/// resize negotiation protocol.
///
/// This struct owns:
///   - A reference to the wlroots wlr_surface  (NOT owned; managed by wlroots)
///   - A reference to the wlr_xdg_toplevel     (NOT owned; managed by wlroots)
///   - Two wlroots signal listeners             (commit, destroy)
///   - A Godot Sprite2D + ImageTexture + Image chain for GPU display
///
/// # Pixel data flow (per frame)
///
/// When a client renders a new frame it:
///   1. Writes pixels into a wl_shm buffer (ordinary CPU-accessible memory).
///   2. Attaches the buffer: wl_surface.attach(buffer).
///   3. Calls wl_surface.commit() — "I'm done, please display this."
///
/// wlroots fires wlr_surface.events.commit → our onCommit() callback runs:
///
///   Client SHM buffer (CPU memory)
///     │  wlr_buffer_begin_data_ptr_access()  — lock buffer, get raw pointer
///     ▼
///   [B][G][R][X] per pixel  (XRGB8888, the format wl_shm uses by default)
///     │  per-pixel swizzle: R←src[2], G←src[1], B←src[0], A←255
///     ▼
///   [R][G][B][A] per pixel  (Godot Image.FORMAT_RGBA8)
///     │  ImageTexture.update()  — upload to GPU
///     ▼
///   GPU texture  →  Sprite2D  →  screen
///
/// # Why a per-pixel swizzle is required
///
/// wl_shm clients typically produce XRGB8888 (memory byte order: B G R X),
/// while Godot's Image.FORMAT_RGBA8 expects byte order R G B A.  The two
/// formats differ in channel order, so a channel swap is unavoidable.
///
/// Eliminating the swizzle would require restricting wl_shm to ABGR8888 only,
/// but wlroots asserts that ARGB8888 and XRGB8888 are always registered before
/// wlr_shm_create() is called.  We cannot bypass wlr_renderer_init_wl_shm()
/// to limit the advertised format set without triggering that assertion.
///
/// # XDG Shell configure / ack / commit handshake
///
/// XDG Shell requires a handshake before the first real buffer is sent:
///   compositor → client : xdg_toplevel.configure(width, height)
///   client → compositor : xdg_surface.ack_configure(serial)
///   client → compositor : wl_surface.commit()   ← first real frame arrives
///
/// The wlr_xdg_surface.initial_commit flag is true on the very first commit.
/// We respond with set_size(0, 0) (let the client choose its own size) and
/// return without trying to read a pixel buffer — there is none yet.
const WaylandSurface = @This();

// ── Wayland / wlroots state ───────────────────────────────────────────────

/// The underlying wlroots surface.  Lifetime is managed by wlroots; do NOT
/// free this pointer.  When the client disconnects, wlroots fires
/// wlr_surface.events.destroy and onDestroy() sets this field to `undefined`
/// (pointer value 0) as a "dead" marker for collectDeadSurfaces().
wlr_surface: *c.wlr.wlr_surface,

/// The XDG toplevel wrapping this surface.  We keep this pointer to send
/// configure events (set_size, set_activated) back to the client.
toplevel: *c.wlr.wlr_xdg_toplevel,

/// Listener registered on wlr_surface.events.commit.
/// Fires every time the client calls wl_surface.commit().
commit_listener: c.wlr.wl_listener,

/// Listener registered on wlr_surface.events.destroy.
/// Fires when the client destroys its wl_surface (window close / disconnect).
destroy_listener: c.wlr.wl_listener,

// ── Godot rendering state ─────────────────────────────────────────────────

/// The Sprite2D node that displays this surface in the Godot scene.
sprite: *Sprite2D,

/// The GPU texture displayed by sprite.  Kept persistent across commits and
/// updated in-place via update() to avoid GPU resource allocation churn.
texture: *ImageTexture,

/// CPU-side Image reused across commits.  Re-created only when the surface
/// dimensions change, to avoid per-frame heap allocation.
image: *Image,

/// Cached surface dimensions.  Used to detect resize events so we can
/// re-create the Image with the correct size before copying pixel data.
width: u32,
height: u32,

// ── Lifecycle ─────────────────────────────────────────────────────────────

/// Create a WaylandSurface, set up Godot display objects, and attach wlroots
/// signal listeners.
///
/// The Sprite2D is immediately added as a child of `parent` and centred in
/// the viewport.  It remains invisible until the first real commit because
/// the placeholder Image is 1×1.
pub fn create(
    allocator: Allocator,
    wlr_surface: *c.wlr.wlr_surface,
    toplevel: *c.wlr.wlr_xdg_toplevel,
    parent: *Node,
) !*WaylandSurface {
    const self = try allocator.create(WaylandSurface);

    const sprite = Sprite2D.init();
    const texture = ImageTexture.init();
    // 1×1 placeholder — real dimensions are applied on the first real commit.
    const image = Image.create(1, 1, false, .format_rgba8).?;

    // Centre the sprite in the viewport.
    const viewport = parent.getViewport().?;
    const screen_size = viewport.getVisibleRect().size;
    sprite.setCentered(true);
    sprite.setPosition(.{ .x = screen_size.x / 2.0, .y = screen_size.y / 2.0 });

    // ImageTexture IS-A Texture2D: upcast (child → parent direction).
    // downcast would go the wrong way (Texture2D → ImageTexture).
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

    // Attach listeners.  From this point wlroots will call our callbacks.
    self.commit_listener.notify = onCommit;
    c.wlr.wl_signal_add(&wlr_surface.events.commit, &self.commit_listener);

    self.destroy_listener.notify = onDestroy;
    c.wlr.wl_signal_add(&wlr_surface.events.destroy, &self.destroy_listener);

    return self;
}

/// Free all resources owned by this WaylandSurface.
///
/// Do NOT call from inside a wlroots signal callback; use the
/// "dead marker + collectDeadSurfaces()" pattern for that case.
pub fn destroy(self: *WaylandSurface, allocator: Allocator) void {
    c.wlr.wl_list_remove(&self.commit_listener.link);
    c.wlr.wl_list_remove(&self.destroy_listener.link);

    self.sprite.destroy();
    if (self.texture.unreference()) self.texture.destroy();
    if (self.image.unreference()) self.image.destroy();

    allocator.destroy(self);
}

// ── Private: pixel upload ─────────────────────────────────────────────────

/// Lock the wlroots buffer, copy pixels into the Godot ImageTexture.
///
/// wlr_buffer_begin_data_ptr_access() returns a raw CPU pointer, the DRM
/// pixel format (e.g. DRM_FORMAT_XRGB8888), and the stride (bytes per row).
/// Stride may be larger than width * 4 due to alignment padding.
fn uploadBuffer(self: *WaylandSurface, buffer: *c.wlr.wlr_buffer) void {
    var data: ?*anyopaque = null;
    var format: u32 = 0;
    var stride: usize = 0;

    // Request CPU read access.  Returns false for GPU-only DMA-BUF buffers
    // that have no linear CPU mapping — we silently skip those.
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

    // Re-create the scratch Image whenever the client resizes its window.
    if (w != self.width or h != self.height) {
        if (self.image.unreference()) self.image.destroy();
        self.image = Image.create(@intCast(w), @intCast(h), false, .format_rgba8).?;
        self.width = w;
        self.height = h;
        // Notify ImageTexture of the new Image object.
        self.texture.setImage(self.image);
    }

    // imagePtrw() is a GDExtension low-level helper that returns a direct
    // writable pointer to the Image's internal pixel buffer.  This avoids
    // a PackedByteArray copy that would otherwise double the memory traffic.
    const imagePtrw = godot.raw.imagePtrw orelse @panic("imagePtrw is null");
    const dst = imagePtrw(self.image);
    const src: [*]const u8 = @ptrCast(data.?);

    // Swizzle XRGB8888 [B G R X] → FORMAT_RGBA8 [R G B A] per pixel.
    // We advance src by `stride` per row (not w*4) to account for padding.
    for (0..h) |y| {
        for (0..w) |x| {
            const src_off = y * stride + x * 4;
            const dst_off = (y * @as(usize, w) + x) * 4;

            // XRGB8888 memory layout: byte 0 = B, 1 = G, 2 = R, 3 = X (unused)
            dst[dst_off + 0] = src[src_off + 2]; // R
            dst[dst_off + 1] = src[src_off + 1]; // G
            dst[dst_off + 2] = src[src_off + 0]; // B
            dst[dst_off + 3] = 255; // A (fully opaque)
        }
    }

    // Upload the modified CPU Image to the GPU texture.
    // update() reuses the existing GPU resource — no re-allocation occurs.
    self.texture.update(self.image);
}

// ── wlroots signal callbacks ──────────────────────────────────────────────

/// Called by wlroots every time the client calls wl_surface.commit().
///
/// Commit means "I've finished writing this frame; please display it."
/// The very first commit is special: the client has not yet sent a pixel
/// buffer and is waiting for the compositor to confirm the initial configure.
fn onCommit(listener: [*c]c.wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const self = c.listenerParent(WaylandSurface, "commit_listener", listener);
    const xdg_surface = self.toplevel.*.base;

    if (xdg_surface.*.initial_commit) {
        // XDG Shell handshake: send size (0, 0) to let the client choose its
        // own dimensions, then mark it as the active (focused) window.
        // The client will ack_configure and then send the first real commit.
        _ = c.wlr.wlr_xdg_toplevel_set_size(self.toplevel, 0, 0);
        _ = c.wlr.wlr_xdg_toplevel_set_activated(self.toplevel, true);
        return;
    }

    // buffer is null if the client committed without attaching a new buffer
    // (damage-only commit, or commit after unmap).  Nothing to display.
    const surface_buffer = self.wlr_surface.*.buffer orelse return;
    self.uploadBuffer(&surface_buffer.*.base);

    // Send a frame-done event so the client knows it can start the next frame.
    // Without this the client stalls waiting for the compositor's acknowledgement.
    var now: c.wlr.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
    c.wlr.wlr_surface_send_frame_done(self.wlr_surface, &now);
}

/// Called by wlroots when the client destroys its wl_surface.
///
/// Freeing memory here is unsafe because this callback runs from inside
/// wlroots signal dispatch.  Instead we:
///   1. Detach both listeners so no further callbacks fire.
///   2. Hide the Sprite2D so the stale last frame is not visible.
///   3. Set wlr_surface = undefined (pointer value 0) as a "dead" marker.
///
/// WaylandCompositor.collectDeadSurfaces() detects the marker on the next
/// _process() tick and calls destroy() safely outside the dispatch context.
fn onDestroy(listener: [*c]c.wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const self = c.listenerParent(WaylandSurface, "destroy_listener", listener);
    c.wlr.wl_list_remove(&self.commit_listener.link);
    c.wlr.wl_list_remove(&self.destroy_listener.link);
    self.sprite.setVisible(false);
    self.wlr_surface = undefined; // dead marker: @intFromPtr(wlr_surface) == 0
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
