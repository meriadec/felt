//! Drawing of the capture picker (picker.zig) in the Nord chrome style: the
//! frozen screen dimmed, the highlighted rectangle bright with a thin frost
//! border, a size pill (`812x430`) at its top-left, and a delay pill at the
//! top center. `Scene.render` repaints only what changed (the old and new
//! highlight and pills) and returns that damage for the backend to present.
const std = @import("std");
const geom = @import("geom.zig");
const color = @import("color.zig");
const sdf = @import("sdf.zig");
const raster = @import("raster.zig");
const text = @import("text.zig");
const style = @import("style.zig");
const picker = @import("picker.zig");
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

const Pill = struct {
    rect: Rect = .empty,
    s: []const u8 = "",
    px: u16 = 0,
    /// Left of the text, and a status dot before it (the delay pill).
    text_x: f32 = 0,
    dot: ?Vec2 = null,
    dot_on: bool = false,
};

const Items = struct {
    scale: f32,
    border: i32,
    hi: ?Rect,
    label_buf: [24]u8 = undefined,
    label: Pill = .{},
    delay_buf: [24]u8 = undefined,
    delay: Pill = .{},

    /// What the highlight and its label cover (the delay pill is static).
    fn overlay(it: *const Items) Rect {
        const h = if (it.hi) |r| r.expand(it.border) else Rect.empty;
        return h.unite(it.label.rect);
    }
};

fn pill(ctx: Ctx, s: []const u8, px: u16, x: f32, y: f32, s_ui: f32, dot: bool) Pill {
    const tw = text.measure(ctx.font, s, px).width;
    const ph = 26 * s_ui;
    const dot_w: f32 = if (dot) 14 * s_ui else 0;
    const pw = tw + 20 * s_ui + dot_w;
    const x0 = @round(x);
    const y0 = @round(y);
    var p = Pill{
        .rect = .{ .x0 = @intFromFloat(x0), .y0 = @intFromFloat(y0), .x1 = @intFromFloat(@round(x0 + pw)), .y1 = @intFromFloat(@round(y0 + ph)) },
        .s = s,
        .px = px,
        .text_x = x0 + 10 * s_ui + dot_w,
    };
    if (dot) p.dot = .{ .x = x0 + 13 * s_ui, .y = y0 + ph / 2 };
    return p;
}

fn layout(ctx: Ctx, it: *Items, p: *const picker.Picker) void {
    const w: f32 = @floatFromInt(p.w);
    const s = it.scale;
    const px = text.pxOf(13 * s);

    // The delay pill, centered at the top.
    const dl = picker.delayLabel(&it.delay_buf, p.delay_ms);
    var d = pill(ctx, dl, px, 0, 12 * s, s, true);
    d = pill(ctx, dl, px, (w - @as(f32, @floatFromInt(d.rect.width()))) / 2, 12 * s, s, true);
    d.dot_on = p.delayOn();
    it.delay = d;

    // The size pill above the top-left corner of the highlight, inside it if there is no room.
    const hi = it.hi orelse return;
    const sl = picker.sizeLabel(&it.label_buf, hi);
    var l = pill(ctx, sl, px, 0, 0, s, false);
    const lw: f32 = @floatFromInt(l.rect.width());
    const lh: f32 = @floatFromInt(l.rect.height());
    var y: f32 = @floatFromInt(hi.y0 - it.border);
    y -= 6 * s + lh;
    if (y < 0) y = @as(f32, @floatFromInt(hi.y0)) + 6 * s;
    const x = std.math.clamp(@as(f32, @floatFromInt(hi.x0)), 0, @max(0, w - lw));
    l = pill(ctx, sl, px, x, y, s, false);
    it.label = l;
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
    const radius = 6 * s;
    raster.fill(cv, clip, rrect(b, radius), .{ .solid = nord.n1 }, .{});
    raster.fill(cv, clip, sdf.ring(rrect(b.expand(-0.5), radius - 0.5), 1), .{ .solid = nord.n2 }, .{});
    if (p.dot) |c| raster.fill(cv, clip, sdf.Disc{ .c = c, .r = 4 * s }, .{ .solid = if (p.dot_on) nord.n14 else nord.n3 }, .{});
    var mask = try text.render(ctx.gpa, ctx.font, p.s, p.px, 0, 0, false);
    defer mask.deinit(ctx.gpa);
    const ph: f32 = @floatFromInt(p.rect.height());
    const y: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(p.rect.y0)) + ph / 2 - @as(f32, @floatFromInt(p.px)) * 0.6));
    cv.blendMask(mask.data, mask.w, mask.h, @intFromFloat(p.text_x), y, nord.n6, clip);
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
    try drawPill(ctx, frame, clip, it.label, it.scale);
    try drawPill(ctx, frame, clip, it.delay, it.scale);
}

/// What the last frame showed, so the next one repaints only the difference.
pub const Scene = struct {
    painted: bool = false,
    prev_overlay: Rect = .empty,
    prev_delay: u32 = 0,

    /// Paint the picker over `frozen` into `frame` (same size). Returns the
    /// rectangles that changed: present them.
    pub fn render(self: *Scene, ctx: Ctx, p: *const picker.Picker, frozen: *const Canvas, frame: *Canvas) !compositor.Damage {
        std.debug.assert(frozen.width == frame.width and frozen.height == frame.height);
        var it = Items{ .scale = style.uiScale(frame.height), .border = 0, .hi = p.highlight() };
        it.border = @max(1, @as(i32, @intFromFloat(@round(it.scale))));
        layout(ctx, &it, p);
        const ov = it.overlay();
        var dmg = compositor.Damage{};
        if (!self.painted) {
            dmg.add(frame.bounds());
        } else {
            dmg.add(self.prev_overlay.expand(2));
            dmg.add(ov.expand(2));
            if (self.prev_delay != p.delay_ms) dmg.add(it.delay.rect.expand(2));
        }
        for (dmg.slice()) |r| try paint(ctx, &it, frozen, frame, r);
        self.painted = true;
        self.prev_overlay = ov;
        self.prev_delay = p.delay_ms;
        return dmg;
    }
};
