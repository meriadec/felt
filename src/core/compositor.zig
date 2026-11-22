//! Compositor: builds screen frames with caching and damage tracking.
//! Layers: `scaled` = the kept part of the image at the view scale (rebuilt on
//! zoom or crop), `scene` = background + white canvas + image + committed
//! annotations (appended in place, scrolled on a pan, repainted in place
//! where an annotation moved or the canvas changed, repainted after undo of an add),
//! `frame` = scene + white canvas of the shape in progress + crop dimming +
//! chrome + preview, repainted only in damaged rects.
const std = @import("std");
const geom = @import("geom.zig");
const color = @import("color.zig");
const draw = @import("draw.zig");
const extent = @import("extent.zig");
const chrome = @import("chrome.zig");
const resample = @import("resample.zig");
const Canvas = @import("canvas.zig").Canvas;
const Document = @import("document.zig").Document;
const Annotation = @import("annotation.zig").Annotation;
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
    /// The kept part of the image at the view scale, when the scale is
    /// below 1:1. Built when the scale or the crop changes; scene rebuilds
    /// (undo) only copy it.
    scaled: ?Canvas = null,
    scaled_key: Rect = Rect.empty,
    scaled_pic: Rect = Rect.empty,
    scene: ?Canvas = null,
    frame: ?Canvas = null,
    /// false: `frame` is a borrowed buffer (e.g. X11 shared memory).
    owns_frame: bool = true,
    view_key: ?View = null,
    pic_key: Rect = Rect.empty,
    scene_valid: bool = false,
    scene_count: usize = 0,
    /// The annotations as the scene shows them (shallow copies: the text
    /// belongs to the document). A move shows up as a difference.
    painted: std.ArrayList(Annotation) = .empty,
    scene_removals: u64 = 0,
    /// Canvas (image px) the scene was painted with.
    scene_canvas: Rect = Rect.empty,
    prev_preview: Rect = Rect.empty,
    /// Screen rectangle of the canvas with the shape in progress.
    prev_live: Rect = Rect.empty,
    prev_crop: ?Rect = null,
    prev_chrome: [chrome.max_panels]Rect = @splat(Rect.empty),
    prev_chrome_sig: u64 = 0,
    force_full: bool = true,

    pub fn deinit(self: *Compositor) void {
        if (self.scaled) |*cv| cv.deinit(self.gpa);
        if (self.scene) |*cv| cv.deinit(self.gpa);
        if (self.owns_frame) if (self.frame) |*cv| cv.deinit(self.gpa);
        self.painted.deinit(self.gpa);
        self.scaled = null;
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

    /// Paint the scene in `r`: background, white canvas, image, then the
    /// first `n` annotations, each in its own clip.
    fn paintScene(self: *Compositor, s: *const Scene, r_in: Rect, n: usize) !void {
        const cv = &self.scene.?;
        const r = r_in.intersect(cv.bounds());
        if (r.isEmpty()) return;
        for (r.minus(s.canvas_dst)) |b| cv.fillRect(b, background);
        for (r.intersect(s.canvas_dst).minus(s.pic_dst)) |b| cv.fillRect(b, extent.fill);
        try self.paintImage(cv, s, r);
        for (s.doc.items.items[0..n], 0..) |a, i| {
            if (!draw.bounds(s.ctx, a, s.xf, .{}).intersects(r)) continue; // e.g. no text mask to render
            const clip = s.itemClip(i);
            try draw.annotation(s.ctx, cv, r.intersect(clip), a, s.xf, .{ .area = clip });
        }
    }

    /// Grow `r` to hold every pixelate among the first `n` annotations that it
    /// touches: a pixelate block averages the pixels under it, so a repaint
    /// that cuts a pixelate would average its own output.
    fn coverPixelates(s: *const Scene, r_in: Rect, n: usize) Rect {
        var r = r_in;
        var grew = true;
        while (grew) {
            grew = false;
            for (s.doc.items.items[0..n], 0..) |a, i| {
                if (a != .pixelate) continue;
                const b = draw.bounds(s.ctx, a, s.xf, .{}).intersect(s.itemClip(i));
                if (b.intersects(r) and !r.contains(b)) {
                    r = r.unite(b);
                    grew = true;
                }
            }
        }
        return r.intersect(s.view.screen());
    }

    /// The kept part of the image, in `r` of its screen rectangle.
    fn paintImage(self: *Compositor, cv: *Canvas, s: *const Scene, r: Rect) !void {
        const pd = s.pic_dst;
        const q = r.intersect(pd);
        if (q.isEmpty()) return;
        const pic = s.pic;
        if (pd.width() == pic.width() and pd.height() == pic.height()) {
            cv.blitRect(s.image, q.offset(pic.x0 - pd.x0, pic.y0 - pd.y0), q.x0, q.y0); // 1:1
        } else if (pd.width() > pic.width() or pd.height() > pic.height()) {
            resample.nearestInto(cv, q, s.image, pic, pd);
        } else {
            const key = Rect.fromSize(0, 0, pd.width(), pd.height());
            if (self.scaled == null or !std.meta.eql(self.scaled_key, key) or !std.meta.eql(self.scaled_pic, pic)) {
                if (self.scaled) |*old| old.deinit(self.gpa);
                self.scaled = null;
                self.scaled = try resample.downscaleRect(self.gpa, s.image, pic, @intCast(pd.width()), @intCast(pd.height()));
                self.scaled_key = key;
                self.scaled_pic = pic;
            }
            cv.blitRect(&self.scaled.?, q.offset(-pd.x0, -pd.y0), q.x0, q.y0);
        }
    }

    /// The view only moved by whole pixels over a valid scene. Pixelate reads
    /// the pixels under it, so a strip repaint could differ: repaint all.
    fn canScroll(self: *const Compositor, doc: *const Document, old: View, new: View, pic: Rect) bool {
        if (!self.scene_valid or !std.meta.eql(pic, self.pic_key)) return false;
        if (old.screen_w != new.screen_w or old.screen_h != new.screen_h or old.xf.scale != new.xf.scale) return false;
        const dx = @abs(new.xf.offset.x - old.xf.offset.x);
        const dy = @abs(new.xf.offset.y - old.xf.offset.y);
        if (dx >= @as(f32, @floatFromInt(new.screen_w)) or dy >= @as(f32, @floatFromInt(new.screen_h))) return false;
        for (doc.items.items[0..@min(self.scene_count, doc.items.items.len)]) |a| if (a == .pixelate) return false;
        return true;
    }

    /// Bring `frame` up to date; returns the screen rectangles that changed.
    pub fn render(self: *Compositor, ctx: draw.Ctx, image: *const Canvas, doc: *const Document, ed: *const Editor) !Damage {
        var dmg = Damage{};
        const v = ed.view;
        const w = v.screen_w;
        const h = v.screen_h;
        const full_rect = v.screen();
        var full = self.force_full;
        self.force_full = false;

        if (self.owns_frame) {
            try self.ensureCanvas(&self.frame, w, h);
        } else if (self.frame.?.width != w or self.frame.?.height != h) {
            return error.FrameBufferSizeMismatch;
        }
        const pic = doc.kept(image.width, image.height).intersect(image.bounds());
        const s = Scene{
            .ctx = ctx,
            .doc = doc,
            .image = image,
            .xf = v.xf,
            .view = v,
            .pic = pic,
            .pic_dst = v.rect(pic),
            .canvas_dst = v.rect(ed.canvas),
        };
        if (self.view_key == null or !std.meta.eql(v, self.view_key.?) or !std.meta.eql(pic, self.pic_key)) {
            if (self.view_key != null and self.canScroll(doc, self.view_key.?, v, pic)) {
                // A pan: scroll the scene, paint only the strips it uncovers,
                // with the canvas the scene holds (growth is appended below).
                const dx: i32 = @intFromFloat(v.xf.offset.x - self.view_key.?.xf.offset.x);
                const dy: i32 = @intFromFloat(v.xf.offset.y - self.view_key.?.xf.offset.y);
                self.scene.?.scroll(dx, dy);
                var old = s;
                old.canvas_dst = v.rect(self.scene_canvas);
                for (full_rect.minus(full_rect.offset(dx, dy))) |strip| try self.paintScene(&old, strip, self.scene_count);
                full = true;
            } else {
                try self.ensureCanvas(&self.scene, w, h);
                self.scene_valid = false;
            }
            self.view_key = v;
            self.pic_key = pic;
        }
        const scene = &self.scene.?;
        const frame = &self.frame.?;
        const items = doc.items.items;

        // Scene: append new annotations; repaint in place where one moved or
        // the canvas grew or shrank; repaint all after a removal.
        if (!self.scene_valid or doc.removals != self.scene_removals or items.len < self.scene_count) {
            try self.paintScene(&s, full_rect, items.len);
            self.painted.clearRetainingCapacity();
            try self.painted.appendSlice(self.gpa, items);
            full = true;
        } else {
            var fix = Damage{};
            if (!std.meta.eql(ed.canvas, self.scene_canvas)) {
                const old_dst = v.rect(self.scene_canvas);
                for (s.canvas_dst.minus(old_dst)) |b| fix.add(b.intersect(full_rect));
                for (old_dst.minus(s.canvas_dst)) |b| fix.add(b.intersect(full_rect));
            }
            for (self.painted.items[0..self.scene_count], items[0..self.scene_count]) |*old, cur| {
                if (std.meta.eql(old.*, cur)) continue;
                fix.add(draw.bounds(ctx, old.*, v.xf, .{}).intersect(full_rect));
                fix.add(draw.bounds(ctx, cur, v.xf, .{}).intersect(full_rect));
                old.* = cur;
            }
            for (fix.slice()) |r| {
                const rr = coverPixelates(&s, r, self.scene_count);
                try self.paintScene(&s, rr, self.scene_count);
                dmg.add(rr);
            }
            try self.painted.appendSlice(self.gpa, items[self.scene_count..]);
            for (items[self.scene_count..], self.scene_count..) |a, i| {
                const clip = s.itemClip(i);
                try draw.annotation(ctx, scene, clip, a, v.xf, .{ .area = clip });
                dmg.add(draw.bounds(ctx, a, v.xf, .{}).intersect(clip));
            }
        }
        self.scene_valid = true;
        self.scene_count = items.len;
        self.scene_removals = doc.removals;
        self.scene_canvas = ed.canvas;

        // Overlay damage: old and new preview, the white canvas it adds,
        // chrome if it changed.
        const preview = ed.preview();
        var preview_clip = Rect.empty;
        var live = s.canvas_dst;
        if (preview) |p| {
            preview_clip = v.rect(extent.grow(ctx, doc.kept(image.width, image.height), p)).intersect(full_rect);
            live = live.unite(preview_clip);
        }
        const cur_preview = if (preview) |p| draw.bounds(ctx, p, v.xf, .{ .preview = true }).intersect(preview_clip) else Rect.empty;
        dmg.add(self.prev_preview);
        dmg.add(cur_preview);
        self.prev_preview = cur_preview;
        if (!std.meta.eql(live, self.prev_live)) {
            for (live.minus(self.prev_live)) |b| dmg.add(b.intersect(full_rect));
            for (self.prev_live.minus(live)) |b| dmg.add(b.intersect(full_rect));
            self.prev_live = live;
        }
        const extra = live.minus(s.canvas_dst);

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
        self.prev_chrome = @splat(Rect.empty);
        for (chrome.rects(&lay), 0..) |r, i| self.prev_chrome[i] = r;

        if (full) {
            dmg = .{};
            dmg.add(full_rect);
        }
        for (dmg.slice()) |r_raw| {
            const r = r_raw.intersect(full_rect);
            frame.copyRect(scene, r);
            for (extra) |b| frame.fillRect(b.intersect(r), extent.fill);
            if (crop) |c| drawCropOverlay(frame, r, c);
            try chrome.draw(ctx, frame, r, &lay);
            // The shape in progress goes over the chrome: what you type stays visible.
            if (preview) |p| try draw.annotation(ctx, frame, r.intersect(preview_clip), p, v.xf, .{ .preview = true, .area = preview_clip });
        }
        return dmg;
    }
};

/// What a scene paint needs: the document, the image and where both go.
const Scene = struct {
    ctx: draw.Ctx,
    doc: *const Document,
    image: *const Canvas,
    xf: geom.Xform,
    view: View,
    /// Kept part of the image (image px) and its screen rectangle.
    pic: Rect,
    pic_dst: Rect,
    /// Screen rectangle of the canvas.
    canvas_dst: Rect,

    /// Screen clip of annotation `i`.
    fn itemClip(s: *const Scene, i: usize) Rect {
        const r = extent.itemClip(s.ctx, s.doc, s.image.width, s.image.height, i);
        return s.view.rect(r).intersect(s.view.screen());
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
