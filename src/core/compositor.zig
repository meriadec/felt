//! Compositor: builds screen frames with caching and damage tracking.
//! Layers: `base` = background + downscaled image (rebuilt on resize),
//! `scene` = base + committed annotations (appended in place, rebuilt after
//! undo), `frame` = scene + preview + chrome, repainted only in damaged rects.
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

pub const background = color.Color.rgb(0x1e1f22);

/// A short list of screen rectangles to repaint and present.
pub const Damage = struct {
    pub const max = 6;
    rects: [max]Rect = undefined,
    len: usize = 0,

    pub fn add(d: *Damage, r_in: Rect) void {
        var r = r_in;
        if (r.isEmpty()) return;
        // Merge with every rectangle it touches, then append.
        var i: usize = 0;
        while (i < d.len) {
            if (d.rects[i].expand(8).intersects(r)) {
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
    view_key: [3]u32 = .{ 0, 0, 0 },
    scene_valid: bool = false,
    scene_count: usize = 0,
    scene_removals: u64 = 0,
    prev_preview: Rect = Rect.empty,
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

    /// Background around the image, downscaled image inside `view.dst`.
    fn drawBase(self: *Compositor, cv: *Canvas, image: *const Canvas, ed: *const Editor) !void {
        const dst = ed.view.dst;
        const full = cv.bounds();
        // Background only where the image is not.
        cv.fillRect(.{ .x0 = 0, .y0 = 0, .x1 = full.x1, .y1 = dst.y0 }, background);
        cv.fillRect(.{ .x0 = 0, .y0 = dst.y1, .x1 = full.x1, .y1 = full.y1 }, background);
        cv.fillRect(.{ .x0 = 0, .y0 = dst.y0, .x1 = dst.x0, .y1 = dst.y1 }, background);
        cv.fillRect(.{ .x0 = dst.x1, .y0 = dst.y0, .x1 = full.x1, .y1 = dst.y1 }, background);
        if (dst.width() == image.width and dst.height() == image.height) {
            cv.blit(image, dst.x0, dst.y0); // 1:1, no copy
            return;
        }
        var scaled = try resample.downscale(self.gpa, image, @intCast(dst.width()), @intCast(dst.height()));
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
        const key = [3]u32{ w, h, @bitCast(ed.view.xf.scale) };
        if (!std.mem.eql(u32, &key, &self.view_key)) {
            if (self.base) |*b| b.deinit(self.gpa);
            self.base = null;
            try self.ensureCanvas(&self.scene, w, h);
            self.view_key = key;
            self.scene_valid = false;
        }
        const scene = &self.scene.?;
        const frame = &self.frame.?;
        const xf = ed.view.xf;
        const items = doc.items.items;

        // Scene: append new annotations, or rebuild after a removal.
        if (!self.scene_valid) {
            try self.drawBase(scene, image, ed);
            for (items) |a| try draw.annotation(ctx, scene, full_rect, a, xf, .{});
            full = true;
        } else if (doc.removals != self.scene_removals or items.len < self.scene_count) {
            if (self.base == null) {
                try self.ensureCanvas(&self.base, w, h);
                try self.drawBase(&self.base.?, image, ed);
            }
            scene.copyRect(&self.base.?, full_rect);
            for (items) |a| try draw.annotation(ctx, scene, full_rect, a, xf, .{});
            full = true;
        } else if (items.len > self.scene_count) {
            for (items[self.scene_count..]) |a| {
                try draw.annotation(ctx, scene, full_rect, a, xf, .{});
                dmg.add(draw.bounds(ctx, a, xf, .{}));
            }
        }
        self.scene_valid = true;
        self.scene_count = items.len;
        self.scene_removals = doc.removals;

        // Overlay damage: old and new preview, chrome if it changed.
        const preview = ed.preview();
        const opts = draw.Options{ .preview = true };
        const cur_preview = if (preview) |p| draw.bounds(ctx, p, xf, opts).intersect(full_rect) else Rect.empty;
        dmg.add(self.prev_preview);
        dmg.add(cur_preview);
        self.prev_preview = cur_preview;

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
            try chrome.draw(ctx, frame, r, &lay);
            // The shape in progress goes over the chrome: what you type stays visible.
            if (preview) |p| try draw.annotation(ctx, frame, r, p, xf, opts);
        }
        return dmg;
    }
};

test "damage merges touching rects" {
    var d = Damage{};
    d.add(Rect.fromSize(0, 0, 10, 10));
    d.add(Rect.fromSize(100, 100, 10, 10));
    try std.testing.expectEqual(@as(usize, 2), d.len);
    d.add(Rect.fromSize(5, 5, 100, 100));
    try std.testing.expectEqual(@as(usize, 1), d.len);
}
