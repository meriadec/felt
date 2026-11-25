//! Drawing of the capture picker (picker.zig) in the Nord chrome style: the
//! frozen screen dimmed, the highlighted rectangle bright with a thin frost
//! border, the ruler marks (ruler.zig: dimension lines with the size, dashed
//! hairlines to the screen edges with their distances), and a delay pill at
//! the top center, shown only while a delay is on. `Scene.render` repaints
//! only what changed (the old and new highlight and marks) and returns that
//! damage for the backend to present.
const std = @import("std");
const geom = @import("geom.zig");
const color = @import("color.zig");
const sdf = @import("sdf.zig");
const raster = @import("raster.zig");
const text = @import("text.zig");
const style = @import("style.zig");
const picker = @import("picker.zig");
const ruler = @import("ruler.zig");
const compositor = @import("compositor.zig");
const Canvas = @import("canvas.zig").Canvas;
const Ctx = @import("draw.zig").Ctx;

const Rect = geom.Rect;
const Bounds = geom.Bounds;
const Vec2 = geom.Vec2;
const nord = color.nord;

/// Brightness of the frozen screen outside the selection, out of 256.
pub const dim_level: u32 = 150;
const border_color = nord.n10;
/// Ruler lines: snow white, faint for the distance hairlines.
const line_soft = nord.n6.withAlpha(120);
const line_strong = nord.n6.withAlpha(210);

const Pill = struct {
    rect: Rect = .empty,
    s: []const u8 = "",
    px: u16 = 0,
    /// Left of the text, and a status dot before it.
    text_x: f32 = 0,
    dot: ?Vec2 = null,
    dot_on: bool = false,
};

const Items = struct {
    scale: f32,
    border: i32,
    hi: ?Rect,
    marks: ruler.Marks = .{},
    delay_buf: [24]u8 = undefined,
    delay: Pill = .{},
};

/// The delay pill: height 26, with a status dot before the text.
fn pill(ctx: Ctx, s: []const u8, px: u16, x: f32, y: f32, s_ui: f32) Pill {
    const ph = 26 * s_ui;
    const pad = 10 * s_ui;
    const tw = text.measure(ctx.font, s, px).width;
    const dot_w = 14 * s_ui;
    const pw = tw + 2 * pad + dot_w;
    const x0 = @round(x);
    const y0 = @round(y);
    return .{
        .rect = .{ .x0 = @intFromFloat(x0), .y0 = @intFromFloat(y0), .x1 = @intFromFloat(@round(x0 + pw)), .y1 = @intFromFloat(@round(y0 + ph)) },
        .s = s,
        .px = px,
        .text_x = x0 + pad + dot_w,
        .dot = .{ .x = x0 + 13 * s_ui, .y = y0 + ph / 2 },
    };
}

fn layout(ctx: Ctx, it: *Items, p: *const picker.Picker) void {
    const w: f32 = @floatFromInt(p.w);
    const s = it.scale;
    const px = text.pxOf(13 * s);

    // The delay pill, centered at the top.
    const dl = picker.delayLabel(&it.delay_buf, p.delay_ms);
    var d = pill(ctx, dl, px, 0, 12 * s, s);
    d = pill(ctx, dl, px, (w - @as(f32, @floatFromInt(d.rect.width()))) / 2, 12 * s, s);
    d.dot_on = p.delayOn();
    it.delay = d;

    const pointer: ?Vec2 = if (p.seen) p.pointer else null;
    it.marks = ruler.build(ctx, it.hi, pointer, p.w, p.h, s);
}

inline fn dim(p: u32) u32 {
    const r = ((p >> 16) & 0xff) * dim_level >> 8;
    const g = ((p >> 8) & 0xff) * dim_level >> 8;
    const b = (p & 0xff) * dim_level >> 8;
    return 0xff000000 | r << 16 | g << 8 | b;
}

fn rrect(b: Bounds, radius: f32) sdf.RoundRect {
    return .{ .min = b.min, .max = b.max, .radius = radius };
}

fn drawPill(ctx: Ctx, cv: *Canvas, clip: Rect, p: Pill, s: f32) !void {
    if (p.rect.isEmpty() or !p.rect.intersects(clip)) return;
    const b = p.rect.toBounds();
    raster.fill(cv, clip, rrect(b, 6 * s), .{ .solid = nord.n1 }, .{});
    raster.fill(cv, clip, sdf.ring(rrect(b.expand(-0.5), 6 * s - 0.5), 1), .{ .solid = nord.n2 }, .{});
    if (p.dot) |c| raster.fill(cv, clip, sdf.Disc{ .c = c, .r = 4 * s }, .{ .solid = if (p.dot_on) nord.n14 else nord.n3 }, .{});
    var mask = try text.render(ctx.gpa, ctx.font, p.s, p.px, 0, 0, null);
    defer mask.deinit(ctx.gpa);
    const ph: f32 = @floatFromInt(p.rect.height());
    const y: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(p.rect.y0)) + ph / 2 - @as(f32, @floatFromInt(p.px)) * 0.6));
    cv.blendMask(mask.data, mask.w, mask.h, @intFromFloat(p.text_x), y, nord.n6, clip);
}

fn drawLabel(ctx: Ctx, cv: *Canvas, clip: Rect, l: ruler.Label, s: f32) !void {
    if (!l.rect.intersects(clip)) return;
    const b = l.rect.toBounds();
    raster.fill(cv, clip, rrect(b, 3 * s), .{ .solid = if (l.strong) nord.n1 else nord.n0.withAlpha(230) }, .{});
    var mask = try text.render(ctx.gpa, ctx.font, l.str(), l.px, 0, 0, null);
    defer mask.deinit(ctx.gpa);
    const ph: f32 = @floatFromInt(l.rect.height());
    const y: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(l.rect.y0)) + ph / 2 - @as(f32, @floatFromInt(l.px)) * 0.6));
    cv.blendMask(mask.data, mask.w, mask.h, @intFromFloat(l.text_x), y, if (l.strong) nord.n6 else nord.n4, clip);
}

fn drawLine(cv: *Canvas, clip: Rect, l: ruler.Line, s: f32) void {
    const c = if (l.strong) line_strong else line_soft;
    if (!l.dashed) return cv.blendRect(l.r.intersect(clip), c);
    // Dashes along the longer side.
    const dash: i32 = @intFromFloat(@round(4 * s));
    const gap: i32 = @intFromFloat(@round(4 * s));
    const horiz = l.r.width() >= l.r.height();
    var p = if (horiz) l.r.x0 else l.r.y0;
    const end = if (horiz) l.r.x1 else l.r.y1;
    while (p < end) : (p += dash + gap) {
        const q = @min(p + dash, end);
        const seg: Rect = if (horiz) .{ .x0 = p, .y0 = l.r.y0, .x1 = q, .y1 = l.r.y1 } else .{ .x0 = l.r.x0, .y0 = p, .x1 = l.r.x1, .y1 = q };
        cv.blendRect(seg.intersect(clip), c);
    }
}

fn paint(ctx: Ctx, it: *const Items, frozen: *const Canvas, frame: *Canvas, clip_in: Rect) !void {
    const clip = clip_in.intersect(frame.bounds());
    if (clip.isEmpty()) return;
    var y = clip.y0;
    while (y < clip.y1) : (y += 1) {
        const src = frozen.row(y, clip.x0, clip.x1);
        for (frame.row(y, clip.x0, clip.x1), src) |*d, sp| d.* = dim(sp);
    }
    if (it.hi) |hi| {
        const out = hi.expand(it.border);
        for (out.minus(hi)) |band| frame.fillRect(band.intersect(clip), border_color);
        frame.copyRect(frozen, hi.intersect(clip));
    }
    for (it.marks.lineSlice()) |l| drawLine(frame, clip, l, it.scale);
    for (it.marks.labelSlice()) |l| try drawLabel(ctx, frame, clip, l, it.scale);
    // The delay pill shows only while a delay is on (--delay, or Tab).
    if (it.delay.dot_on) try drawPill(ctx, frame, clip, it.delay, it.scale);
}

/// What the last frame showed, so the next one repaints only the difference.
pub const Scene = struct {
    painted: bool = false,
    prev_hi: Rect = .empty,
    prev: [ruler.Marks.max_rects]Rect = undefined,
    prev_n: usize = 0,
    prev_delay: u32 = 0,

    /// Paint the picker over `frozen` into `frame` (same size). Returns the
    /// rectangles that changed: present them.
    pub fn render(self: *Scene, ctx: Ctx, p: *const picker.Picker, frozen: *const Canvas, frame: *Canvas) !compositor.Damage {
        std.debug.assert(frozen.width == frame.width and frozen.height == frame.height);
        var it = Items{ .scale = style.uiScale(frame.height), .border = 0, .hi = p.highlight() };
        it.border = @max(1, @as(i32, @intFromFloat(@round(it.scale))));
        layout(ctx, &it, p);
        var now: [ruler.Marks.max_rects]Rect = undefined;
        const n = it.marks.rects(&now);
        const hi_now = if (it.hi) |r| r.expand(it.border) else Rect.empty;
        var dmg = compositor.Damage{};
        if (!self.painted) {
            dmg.add(frame.bounds());
        } else {
            // The highlight and every mark, old and new.
            dmg.add(self.prev_hi.expand(2));
            dmg.add(hi_now.expand(2));
            for (self.prev[0..self.prev_n]) |r| dmg.add(r.expand(2));
            for (now[0..n]) |r| dmg.add(r.expand(2));
            if (self.prev_delay != p.delay_ms) dmg.add(it.delay.rect.expand(2));
        }
        for (dmg.slice()) |r| try paint(ctx, &it, frozen, frame, r);
        self.painted = true;
        self.prev_hi = hi_now;
        self.prev_n = n;
        @memcpy(self.prev[0..n], now[0..n]);
        self.prev_delay = p.delay_ms;
        return dmg;
    }
};
