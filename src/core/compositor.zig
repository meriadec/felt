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
    base: ?Canvas = null,
    scene: ?Canvas = null,
    frame: ?Canvas = null,
    base_key: [3]u32 = .{ 0, 0, 0 },
    scene_valid: bool = false,
    scene_count: usize = 0,
    scene_removals: u64 = 0,
    prev_preview: Rect = Rect.empty,
    prev_chrome: [3]Rect = .{ Rect.empty, Rect.empty, Rect.empty },
    prev_chrome_sig: u64 = 0,
    force_full: bool = true,

    pub fn deinit(self: *Compositor) void {
        inline for (.{ &self.base, &self.scene, &self.frame }) |c| if (c.*) |*cv| cv.deinit(self.gpa);
    }

    /// Next render repaints and reports the whole frame (e.g. after Expose).
    pub fn invalidate(self: *Compositor) void {
        self.force_full = true;
    }

    fn ensureSize(self: *Compositor, w: u32, h: u32) !bool {
        if (self.frame) |f| if (f.width == w and f.height == h) return false;
        self.deinit();
        self.base = null;
        self.scene = null;
        self.frame = null;
        self.base = try Canvas.init(self.gpa, w, h);
        self.scene = try Canvas.init(self.gpa, w, h);
        self.frame = try Canvas.init(self.gpa, w, h);
        return true;
    }

    fn buildBase(self: *Compositor, image: *const Canvas, ed: *const Editor) !void {
        const base = &self.base.?;
        base.fill(background);
        const dst = ed.view.dst;
        var scaled = try resample.downscale(self.gpa, image, @intCast(dst.width()), @intCast(dst.height()));
        defer scaled.deinit(self.gpa);
        base.blit(&scaled, dst.x0, dst.y0);
    }

    /// Bring `frame` up to date; returns the screen rectangles that changed.
    pub fn render(self: *Compositor, ctx: draw.Ctx, image: *const Canvas, doc: *const Document, ed: *const Editor) !Damage {
        var dmg = Damage{};
        const w = ed.view.screen_w;
        const h = ed.view.screen_h;
        const full_rect = Rect.fromSize(0, 0, @intCast(w), @intCast(h));
        var full = self.force_full;
        self.force_full = false;

        const key = [3]u32{ w, h, @bitCast(ed.view.xf.scale) };
        if (try self.ensureSize(w, h) or !std.mem.eql(u32, &key, &self.base_key)) {
            try self.buildBase(image, ed);
            self.base_key = key;
            self.scene_valid = false;
        }
        const scene = &self.scene.?;
        const frame = &self.frame.?;
        const xf = ed.view.xf;
        const items = doc.items.items;

        // Scene: append new annotations, or rebuild after a removal.
        if (!self.scene_valid or doc.removals != self.scene_removals or items.len < self.scene_count) {
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
        const opts = draw.Options{ .caret = true };
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
            if (preview) |p| try draw.annotation(ctx, frame, r, p, xf, opts);
            try chrome.draw(ctx, frame, r, &lay);
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
