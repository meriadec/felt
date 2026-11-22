//! Compositor: builds screen frames with caching and damage tracking.
//! Layers: `base` = background + downscaled image (rebuilt on resize or crop),
//! `scene` = base + committed annotations (appended in place, rebuilt after
//! undo), `frame` = scene + crop dimming + chrome + preview, repainted only in
//! damaged rects.
const std = @import("std");
const geom = @import("geom.zig");
const color = @import("color.zig");
const draw = @import("draw.zig");
const chrome = @import("chrome.zig");
const resample = @import("resample.zig");
const Canvas = @import("canvas.zig").Canvas;
const Document = @import("document.zig").Document;
const Editor = @import("editor.zig").Editor;

const Rect = geom.Rect;
const View = @import("view.zig").View;

pub const background = color.nord.n0;

/// A short list of screen rectangles to repaint and present.
pub const Damage = struct {
    pub const max = 6;
    rects: [max]Rect = undefined,
    len: usize = 0,

    pub fn add(d: *Damage, r_in: Rect) void {
        var r = r_in;
        if (r.isEmpty()) return;
        // Merge with every rectangle it touches, unless the union would
        // repaint much more than both (e.g. two edges of a crop frame).
        var i: usize = 0;
        while (i < d.len) {
            const o = d.rects[i];
            if (o.expand(8).intersects(r) and o.unite(r).area() <= (o.area() + r.area()) * 3 / 2 + 4096) {
                r = r.unite(d.rects[i]);
                d.rects[i] = d.rects[d.len - 1];
                d.len -= 1;
                i = 0;
            } else i += 1;
        }
        if (d.len == max) {
            for (d.rects[0..d.len]) |o| r = r.unite(o);
            d.len = 0;
        }
        d.rects[d.len] = r;
        d.len += 1;
    }

    pub fn slice(d: *const Damage) []const Rect {
        return d.rects[0..d.len];
    }

    pub fn area(d: *const Damage) u64 {
        var a: u64 = 0;
        for (d.slice()) |r| a += r.area();
        return a;
    }
};

pub const Compositor = struct {
    gpa: std.mem.Allocator,
    /// Background + image only; built lazily on the first scene rebuild
    /// (undo), so startup draws the image straight into `scene`.
    base: ?Canvas = null,
    scene: ?Canvas = null,
    frame: ?Canvas = null,
    /// false: `frame` is a borrowed buffer (e.g. X11 shared memory).
    owns_frame: bool = true,
    view_key: ?View = null,
    scene_valid: bool = false,
    scene_count: usize = 0,
    scene_removals: u64 = 0,
    prev_preview: Rect = Rect.empty,
    prev_crop: ?Rect = null,
    prev_chrome: [3]Rect = .{ Rect.empty, Rect.empty, Rect.empty },
    prev_chrome_sig: u64 = 0,
    force_full: bool = true,

    pub fn deinit(self: *Compositor) void {
        if (self.base) |*cv| cv.deinit(self.gpa);
        if (self.scene) |*cv| cv.deinit(self.gpa);
        if (self.owns_frame) if (self.frame) |*cv| cv.deinit(self.gpa);
        self.base = null;
        self.scene = null;
        self.frame = null;
    }

    /// Render into `cv` (not owned, must match the view size) from now on.
    pub fn setFrameBuffer(self: *Compositor, cv: Canvas) void {
        if (self.owns_frame) if (self.frame) |*f| f.deinit(self.gpa);
        self.frame = cv;
        self.owns_frame = false;
        self.force_full = true;
    }

    /// Next render repaints and reports the whole frame (e.g. after Expose).
    pub fn invalidate(self: *Compositor) void {
        self.force_full = true;
    }

    fn ensureCanvas(self: *Compositor, slot: *?Canvas, w: u32, h: u32) !void {
        if (slot.*) |*cv| {
            if (cv.width == w and cv.height == h) return;
            cv.deinit(self.gpa);
            slot.* = null;
        }
        slot.* = try Canvas.init(self.gpa, w, h);
    }

    /// Background around the image, downscaled kept part inside `view.dst`.
    fn drawBase(self: *Compositor, cv: *Canvas, image: *const Canvas, ed: *const Editor) !void {
        const dst = ed.view.dst;
        const src = ed.view.src;
        const full = cv.bounds();
        // Background only where the image is not.
        cv.fillRect(.{ .x0 = 0, .y0 = 0, .x1 = full.x1, .y1 = dst.y0 }, background);
        cv.fillRect(.{ .x0 = 0, .y0 = dst.y1, .x1 = full.x1, .y1 = full.y1 }, background);
        cv.fillRect(.{ .x0 = 0, .y0 = dst.y0, .x1 = dst.x0, .y1 = dst.y1 }, background);
        cv.fillRect(.{ .x0 = dst.x1, .y0 = dst.y0, .x1 = full.x1, .y1 = dst.y1 }, background);
        if (dst.width() == src.width() and dst.height() == src.height()) {
            cv.blitRect(image, src, dst.x0, dst.y0); // 1:1, no copy
            return;
        }
        var scaled = try resample.downscaleRect(self.gpa, image, src, @intCast(dst.width()), @intCast(dst.height()));
        defer scaled.deinit(self.gpa);
        cv.blit(&scaled, dst.x0, dst.y0);
    }

    /// Bring `frame` up to date; returns the screen rectangles that changed.
    pub fn render(self: *Compositor, ctx: draw.Ctx, image: *const Canvas, doc: *const Document, ed: *const Editor) !Damage {
        var dmg = Damage{};
        const w = ed.view.screen_w;
        const h = ed.view.screen_h;
        const full_rect = Rect.fromSize(0, 0, @intCast(w), @intCast(h));
        var full = self.force_full;
        self.force_full = false;

        if (self.owns_frame) {
            try self.ensureCanvas(&self.frame, w, h);
        } else if (self.frame.?.width != w or self.frame.?.height != h) {
            return error.FrameBufferSizeMismatch;
        }
        if (self.view_key == null or !std.meta.eql(ed.view, self.view_key.?)) {
            if (self.base) |*b| b.deinit(self.gpa);
            self.base = null;
            try self.ensureCanvas(&self.scene, w, h);
            self.view_key = ed.view;
            self.scene_valid = false;
        }
        const scene = &self.scene.?;
        const frame = &self.frame.?;
        const xf = ed.view.xf;
        const items = doc.items.items;
        // Annotations show only over the image, as in the export.
        const img = ed.view.dst.intersect(full_rect);
        const base_opts = draw.Options{ .area = ed.view.dst };

        // Scene: append new annotations, or rebuild after a removal.
        if (!self.scene_valid) {
            try self.drawBase(scene, image, ed);
            for (items) |a| try draw.annotation(ctx, scene, img, a, xf, base_opts);
            full = true;
        } else if (doc.removals != self.scene_removals or items.len < self.scene_count) {
            if (self.base == null) {
                try self.ensureCanvas(&self.base, w, h);
                try self.drawBase(&self.base.?, image, ed);
            }
            scene.copyRect(&self.base.?, full_rect);
            for (items) |a| try draw.annotation(ctx, scene, img, a, xf, base_opts);
            full = true;
        } else if (items.len > self.scene_count) {
            for (items[self.scene_count..]) |a| {
                try draw.annotation(ctx, scene, img, a, xf, base_opts);
                dmg.add(draw.bounds(ctx, a, xf, base_opts).intersect(img));
            }
        }
        self.scene_valid = true;
        self.scene_count = items.len;
        self.scene_removals = doc.removals;

        // Overlay damage: old and new preview, chrome if it changed.
        const preview = ed.preview();
        const opts = draw.Options{ .preview = true, .area = ed.view.dst };
        const cur_preview = if (preview) |p| draw.bounds(ctx, p, xf, opts).intersect(img) else Rect.empty;
        dmg.add(self.prev_preview);
        dmg.add(cur_preview);
        self.prev_preview = cur_preview;

        // Crop in progress: everything outside is dimmed. Damage only the
        // bands between the old and the new rectangle.
        const crop = ed.cropPreview();
        if ((crop == null) != (self.prev_crop == null)) {
            full = true;
        } else if (crop) |cur| {
            for (cropBands(self.prev_crop.?, cur, crop_frame_w + 2)) |b| dmg.add(b);
        }
        self.prev_crop = crop;

        const st = chrome.State.of(ed);
        const lay = chrome.layout(ctx, st, w, h);
        const sig = st.signature();
        if (sig != self.prev_chrome_sig) {
            for (self.prev_chrome) |r| dmg.add(r);
            for (chrome.rects(&lay)) |r| dmg.add(r);
            self.prev_chrome_sig = sig;
        }
        self.prev_chrome = .{ Rect.empty, Rect.empty, Rect.empty };
        for (chrome.rects(&lay), 0..) |r, i| self.prev_chrome[i] = r;

        if (full) {
            dmg = .{};
            dmg.add(full_rect);
        }
        for (dmg.slice()) |r_raw| {
            const r = r_raw.intersect(full_rect);
            frame.copyRect(scene, r);
            if (crop) |c| drawCropOverlay(frame, r, c);
            try chrome.draw(ctx, frame, r, &lay);
            // The shape in progress goes over the chrome: what you type stays visible.
            if (preview) |p| try draw.annotation(ctx, frame, r.intersect(img), p, xf, opts);
        }
        return dmg;
    }
};

const crop_dim = color.nord.n0.withAlpha(170);
const crop_frame = color.nord.n8;
const crop_frame_w = 2;

/// Dim `r` outside the crop rectangle `c` and draw the crop frame.
fn drawCropOverlay(cv: *Canvas, r: Rect, c: Rect) void {
    const outside = [_]Rect{
        .{ .x0 = r.x0, .y0 = r.y0, .x1 = r.x1, .y1 = c.y0 },
        .{ .x0 = r.x0, .y0 = c.y1, .x1 = r.x1, .y1 = r.y1 },
        .{ .x0 = r.x0, .y0 = c.y0, .x1 = c.x0, .y1 = c.y1 },
        .{ .x0 = c.x1, .y0 = c.y0, .x1 = r.x1, .y1 = c.y1 },
    };
    for (outside) |o| cv.blendRect(o.intersect(r), crop_dim);
    const e = crop_frame_w;
    const frame_sides = [_]Rect{
        .{ .x0 = c.x0 - e, .y0 = c.y0 - e, .x1 = c.x1 + e, .y1 = c.y0 },
        .{ .x0 = c.x0 - e, .y0 = c.y1, .x1 = c.x1 + e, .y1 = c.y1 + e },
        .{ .x0 = c.x0 - e, .y0 = c.y0, .x1 = c.x0, .y1 = c.y1 },
        .{ .x0 = c.x1, .y0 = c.y0, .x1 = c.x1 + e, .y1 = c.y1 },
    };
    for (frame_sides) |f| cv.fillRect(f.intersect(r), crop_frame);
}

/// Rectangles that cover every pixel that differs between crop overlays for
/// `a` and `b`, frame included (`m` = frame width plus a margin).
fn cropBands(a: Rect, b: Rect, m: i32) [4]Rect {
    const x0 = @min(a.x0, b.x0) - m;
    const x1 = @max(a.x1, b.x1) + m;
    const y0 = @min(a.y0, b.y0) - m;
    const y1 = @max(a.y1, b.y1) + m;
    return .{
        .{ .x0 = x0, .y0 = @min(a.y0, b.y0) - m, .x1 = x1, .y1 = @max(a.y0, b.y0) + m },
        .{ .x0 = x0, .y0 = @min(a.y1, b.y1) - m, .x1 = x1, .y1 = @max(a.y1, b.y1) + m },
        .{ .x0 = @min(a.x0, b.x0) - m, .y0 = y0, .x1 = @max(a.x0, b.x0) + m, .y1 = y1 },
        .{ .x0 = @min(a.x1, b.x1) - m, .y0 = y0, .x1 = @max(a.x1, b.x1) + m, .y1 = y1 },
    };
}

test "damage merges touching rects" {
    var d = Damage{};
    d.add(Rect.fromSize(0, 0, 10, 10));
    d.add(Rect.fromSize(100, 100, 10, 10));
    try std.testing.expectEqual(@as(usize, 2), d.len);
    d.add(Rect.fromSize(5, 5, 100, 100));
    try std.testing.expectEqual(@as(usize, 1), d.len);
}
