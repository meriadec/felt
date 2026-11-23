//! Compositor: builds screen frames with caching and damage tracking.
//! Layers: `scaled` = the kept part of the image at the view scale (rebuilt on
//! zoom or crop), `scene` = background + canvas background + image + committed
//! annotations (appended in place, scrolled on a pan, repainted in place
//! where an annotation moved or the canvas changed, repainted after undo of an add),
//! `frame` = scene + canvas background the shape in progress adds + crop dimming +
//! chrome + preview, repainted only in damaged rects.
const std = @import("std");
const geom = @import("geom.zig");
const color = @import("color.zig");
const draw = @import("draw.zig");
const extent = @import("extent.zig");
const chrome = @import("chrome.zig");
const resample = @import("resample.zig");
const sdf = @import("sdf.zig");
const raster = @import("raster.zig");
const Canvas = @import("canvas.zig").Canvas;
const Document = @import("document.zig").Document;
const Annotation = @import("annotation.zig").Annotation;
const Editor = @import("editor.zig").Editor;

const Rect = geom.Rect;
const View = @import("view.zig").View;

pub const background = color.Color.rgb(0x20242D);
/// Grid lines on the screen background: a faint step above the background, so the
/// canvas stays distinct from it, whatever the canvas color.
pub const grid_color = color.Color.rgb(0x282D38);
/// Distance between grid lines (screen px).
pub const grid_step: i32 = 32;

/// Fill `r` with the screen background and its grid. The lines hang on the
/// image origin of the view, so a pan (an integer scroll of the scene) keeps
/// the pattern aligned with the strips it paints.
fn fillBackground(cv: *Canvas, r: Rect, origin_x: i32, origin_y: i32) void {
    cv.fillRect(r, background);
    var x = r.x0 + @mod(origin_x - r.x0, grid_step);
    while (x < r.x1) : (x += grid_step) cv.fillRect(.{ .x0 = x, .y0 = r.y0, .x1 = x + 1, .y1 = r.y1 }, grid_color);
    var y = r.y0 + @mod(origin_y - r.y0, grid_step);
    while (y < r.y1) : (y += grid_step) cv.fillRect(.{ .x0 = r.x0, .y0 = y, .x1 = r.x1, .y1 = y + 1 }, grid_color);
}

/// A short list of screen rectangles to repaint and present.
pub const Damage = struct {
    pub const max = 12;
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
            if (o.expand(8).intersects(r) and o.unite(r).area() <= o.area() + r.area() + 4096) {
                r = r.unite(d.rects[i]);
                d.rects[i] = d.rects[d.len - 1];
                d.len -= 1;
                i = 0;
            } else i += 1;
        }
        if (d.len == max) {
            // No room: fold into the rectangle that grows the least.
            var best: usize = 0;
            var best_cost: u64 = std.math.maxInt(u64);
            for (d.rects[0..d.len], 0..) |o, j| {
                const cost = o.unite(r).area() - o.area();
                if (cost < best_cost) {
                    best = j;
                    best_cost = cost;
                }
            }
            r = r.unite(d.rects[best]);
            d.rects[best] = d.rects[d.len - 1];
            d.len -= 1;
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

/// Scene rectangles to repaint in place (a move, a canvas change): a moved
/// diagonal arrow is many slabs (draw.cover), not its bounding box. Two
/// rects merge when their union is no bigger than both apart: a slab at
/// the old and the new place, or a box moved by a pixel or two in both
/// axes (its overlap would else be painted twice).
const Fix = struct {
    const max = 64;
    rects: [max]Rect = undefined,
    len: usize = 0,
    /// All of them, when the pieces run out.
    hull: Rect = Rect.empty,

    fn add(f: *Fix, r_in: Rect) void {
        var r = r_in;
        if (r.isEmpty()) return;
        f.hull = f.hull.unite(r);
        var i: usize = 0;
        while (i < f.len) {
            const o = f.rects[i];
            if (o.unite(r).area() <= o.area() + r.area()) {
                r = r.unite(o);
                f.rects[i] = f.rects[f.len - 1];
                f.len -= 1;
                i = 0;
            } else i += 1;
        }
        if (f.len < max) {
            f.rects[f.len] = r;
            f.len += 1;
        }
    }

    fn slice(f: *Fix) []const Rect {
        if (f.len == max) { // overflow: one rectangle holds all
            f.rects[0] = f.hull;
            f.len = 1;
        }
        return f.rects[0..f.len];
    }
};

/// Where render time goes, summed since the last reset (`--bench` prints it).
pub const Prof = struct {
    /// Scene: appends, repaints in place, full rebuilds.
    scene_ns: u64 = 0,
    /// Frame: the damage rects composed from the scene and the overlays.
    frame_ns: u64 = 0,
    /// Chrome draws, part of `frame_ns`.
    chrome_ns: u64 = 0,
    /// Scene repaint rects (after merges) and frame damage rects.
    fix_rects: u64 = 0,
    dmg_rects: u64 = 0,
};

/// A timer that reads 0 where the OS has none.
const Clock = struct {
    t: ?std.time.Timer,

    fn start() Clock {
        return .{ .t = std.time.Timer.start() catch null };
    }
    fn read(c: *Clock) u64 {
        return if (c.t) |*t| t.read() else 0;
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
    /// Canvas background the scene was painted with.
    scene_bg: color.Color = .{ .r = 0, .g = 0, .b = 0 },
    /// Canvas padding the scene holds: it changes every clip, so a change repaints all.
    scene_pad: i32 = 0,
    prev_preview: Rect = Rect.empty,
    /// Screen rectangle of the canvas with the shape in progress.
    prev_live: Rect = Rect.empty,
    prev_crop: ?Rect = null,
    /// Move tool outline last drawn, and its screen rectangle.
    prev_outline: ?Outline = null,
    /// Chrome panels last drawn: kind, rect and what they showed.
    prev_chrome: [chrome.max_panels]PanelPaint = undefined,
    prev_chrome_n: usize = 0,
    force_full: bool = true,
    prof: Prof = .{},

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

    /// Paint the scene in `r`: background, canvas background, image, then the
    /// first `n` annotations, each in its own clip.
    fn paintScene(self: *Compositor, s: *const Scene, r_in: Rect, n: usize) !void {
        const cv = &self.scene.?;
        const r = r_in.intersect(cv.bounds());
        if (r.isEmpty()) return;
        const ox: i32 = @intFromFloat(@round(s.xf.offset.x));
        const oy: i32 = @intFromFloat(@round(s.xf.offset.y));
        for (r.minus(s.canvas_dst)) |b| fillBackground(cv, b, ox, oy);
        for (r.intersect(s.canvas_dst).minus(s.pic_dst)) |b| cv.fillRect(b, s.bg);
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
            .bg = ed.settings.canvas_bg.color(),
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
        var clock = Clock.start();
        if (!self.scene_valid or ctx.pad != self.scene_pad or doc.removals != self.scene_removals or items.len < self.scene_count) {
            try self.paintScene(&s, full_rect, items.len);
            self.painted.clearRetainingCapacity();
            try self.painted.appendSlice(self.gpa, items);
            full = true;
        } else {
            var fix = Fix{};
            if (!std.meta.eql(s.bg, self.scene_bg)) {
                // The canvas background changed: repaint the canvas outside
                // the image (bands around it), with what is drawn there.
                for (s.canvas_dst.minus(s.pic_dst)) |b| fix.add(b.intersect(full_rect));
            }
            if (!std.meta.eql(ed.canvas, self.scene_canvas)) {
                const old_dst = v.rect(self.scene_canvas);
                for (s.canvas_dst.minus(old_dst)) |b| fix.add(b.intersect(full_rect));
                for (old_dst.minus(s.canvas_dst)) |b| fix.add(b.intersect(full_rect));
            }
            for (self.painted.items[0..self.scene_count], items[0..self.scene_count]) |*old, cur| {
                if (std.meta.eql(old.*, cur)) continue;
                var buf: [draw.max_cover]Rect = undefined;
                for (draw.cover(ctx, old.*, v.xf, &buf)) |r| fix.add(r.intersect(full_rect));
                for (draw.cover(ctx, cur, v.xf, &buf)) |r| fix.add(r.intersect(full_rect));
                old.* = cur;
            }
            const fixes = fix.slice();
            self.prof.fix_rects += fixes.len;
            for (fixes) |r| {
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
        self.prof.scene_ns += clock.read();
        self.scene_valid = true;
        self.scene_count = items.len;
        self.scene_removals = doc.removals;
        self.scene_canvas = ed.canvas;
        const bg_changed = !std.meta.eql(s.bg, self.scene_bg);
        self.scene_bg = s.bg;
        self.scene_pad = ctx.pad;

        // Overlay damage: old and new preview, the canvas it adds,
        // chrome if it changed.
        const preview = ed.preview();
        var preview_clip = Rect.empty;
        var live = s.canvas_dst;
        if (preview) |p| {
            preview_clip = v.rect(extent.grow(ctx, extent.keptPad(ctx, doc, image.width, image.height), p)).intersect(full_rect);
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
        if (bg_changed) for (extra) |b| dmg.add(b.intersect(full_rect));

        // Crop in progress: everything outside is dimmed. Damage only the
        // bands between the old and the new rectangle.
        const crop = ed.cropPreview();
        if ((crop == null) != (self.prev_crop == null)) {
            full = true;
        } else if (crop) |cur| {
            for (cropBands(self.prev_crop.?, cur, crop_frame_w + 2)) |b| dmg.add(b);
        }
        self.prev_crop = crop;

        // Move tool: the outline of the annotation under the pointer.
        const outline = Outline.of(ctx, doc, ed);
        if (!std.meta.eql(outline, self.prev_outline)) {
            if (self.prev_outline) |o| dmg.add(o.rect.intersect(full_rect));
            if (outline) |o| dmg.add(o.rect.intersect(full_rect));
            self.prev_outline = outline;
        }

        const st = chrome.State.of(ed);
        const lay = chrome.layout(ctx, st, w, h);
        // Chrome: repaint a panel where it was and where it is when it
        // moved, changed or came or went; the others stay as painted.
        var cur: [chrome.max_panels]PanelPaint = undefined;
        for (chrome.rects(&lay), chrome.kinds(&lay), 0..) |r, k, i| cur[i] = .{ .kind = k, .rect = r, .sig = st.panelSig(k) };
        const cur_n = chrome.rects(&lay).len;
        for (cur[0..cur_n]) |p| {
            const old = PanelPaint.find(self.prev_chrome[0..self.prev_chrome_n], p.kind);
            if (old != null and std.meta.eql(old.?, p)) continue;
            dmg.add(p.rect);
            if (old) |o| dmg.add(o.rect);
        }
        for (self.prev_chrome[0..self.prev_chrome_n]) |o| {
            if (PanelPaint.find(cur[0..cur_n], o.kind) == null) dmg.add(o.rect);
        }
        self.prev_chrome = cur;
        self.prev_chrome_n = cur_n;

        if (full) {
            dmg = .{};
            dmg.add(full_rect);
        }
        clock = Clock.start();
        self.prof.dmg_rects += dmg.len;
        for (dmg.slice()) |r_raw| {
            const r = r_raw.intersect(full_rect);
            frame.copyRect(scene, r);
            for (extra) |b| frame.fillRect(b.intersect(r), s.bg);
            if (crop) |c| drawCropOverlay(frame, r, c);
            if (outline) |o| o.paint(ctx, frame, r, v.xf);
            var chrome_clock = Clock.start();
            try chrome.draw(ctx, frame, r, &lay);
            self.prof.chrome_ns += chrome_clock.read();
            // The shape in progress goes over the chrome: what you type stays visible.
            if (preview) |p| try draw.annotation(ctx, frame, r.intersect(preview_clip), p, v.xf, .{ .preview = true, .area = preview_clip });
        }
        self.prof.frame_ns += clock.read();
        return dmg;
    }
};

/// A chrome panel as a frame painted it.
const PanelPaint = struct {
    kind: chrome.Panel,
    rect: Rect,
    sig: u64,

    fn find(list: []const PanelPaint, kind: chrome.Panel) ?PanelPaint {
        for (list) |p| if (p.kind == kind) return p;
        return null;
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
    /// Color of the canvas outside the image (settings.zig).
    bg: color.Color,

    /// Screen clip of annotation `i`.
    fn itemClip(s: *const Scene, i: usize) Rect {
        const r = extent.itemClip(s.ctx, s.doc, s.image.width, s.image.height, i);
        return s.view.rect(r).intersect(s.view.screen());
    }
};

/// The move tool's flat outline around an annotation, with handles on the
/// parts that move alone (arrow ends, callout tip).
const Outline = struct {
    ann: Annotation,
    part: @import("annotation.zig").Part,
    /// Screen px at 1080p to screen px.
    ui: f32,
    rect: Rect,
    /// The bend handle on the middle segment of a stairs path (screen px).
    bend: ?geom.Vec2,

    const line = color.nord.n8;
    const handle_edge = color.nord.n0;

    fn of(ctx: draw.Ctx, doc: *const Document, ed: *const Editor) ?Outline {
        const g = ed.outlined() orelse return null;
        const a = doc.items.items[g.index];
        const ui = @import("style.zig").uiScale(ed.view.screen_h);
        var o = Outline{ .ann = a, .part = g.part, .ui = ui, .rect = draw.outlineBounds(ctx, a, ed.view.xf, lineStyle(ui, g.part)), .bend = ed.bendHandle(a) };
        var hs: [3]?geom.Vec2 = undefined;
        for (o.handles(ed.view.xf, &hs)) |h| if (h) |c| {
            o.rect = o.rect.unite((geom.Bounds{ .min = c, .max = c }).expand(o.handleR(true) + 2).toRect());
        };
        return o;
    }

    fn lineStyle(ui: f32, part: @import("annotation.zig").Part) draw.OutlineStyle {
        return .{ .gap = 3 * ui, .w = (if (part == .whole) @as(f32, 2) else 1) * ui, .color = line };
    }

    fn handleR(o: Outline, active: bool) f32 {
        return (if (active) @as(f32, 6) else 4.5) * o.ui;
    }

    /// Screen points of the handles: arrow tail and head, callout tip, the
    /// bend of a stairs path.
    fn handles(o: Outline, xf: geom.Xform, out: *[3]?geom.Vec2) []const ?geom.Vec2 {
        out.* = .{ null, null, o.bend };
        switch (o.ann) {
            .arrow => |a| {
                out[0] = xf.apply(a.tail);
                out[1] = xf.apply(a.head);
            },
            .callout => |c| if (c.target) |t| {
                out[0] = xf.apply(t);
            },
            else => {},
        }
        return out;
    }

    fn paint(o: Outline, ctx: draw.Ctx, cv: *Canvas, r: Rect, xf: geom.Xform) void {
        if (!o.rect.intersects(r)) return;
        draw.outline(ctx, cv, r, o.ann, xf, lineStyle(o.ui, o.part));
        var hs: [3]?geom.Vec2 = undefined;
        for (o.handles(xf, &hs), 0..) |h, i| if (h) |c| {
            const active = switch (o.part) {
                .tail, .tip => i == 0,
                .head => i == 1,
                .bend => i == 2,
                .whole => false,
            };
            const disc = sdf.Disc{ .c = c, .r = o.handleR(active) };
            raster.fill(cv, r, disc, .{ .solid = line }, .{});
            raster.fill(cv, r, sdf.ring(disc, 1), .{ .solid = handle_edge }, .{});
        };
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

test "fix merges a box moved by a pixel, not two far boxes" {
    var f = Fix{};
    f.add(Rect.fromSize(0, 0, 100, 20));
    f.add(Rect.fromSize(1, 1, 100, 20)); // the same box, one pixel off in x and y
    try std.testing.expectEqual(@as(usize, 1), f.len);
    try std.testing.expectEqual(Rect.fromSize(0, 0, 101, 21), f.rects[0]);
    f.add(Rect.fromSize(300, 300, 10, 10));
    try std.testing.expectEqual(@as(usize, 2), f.len);
}
