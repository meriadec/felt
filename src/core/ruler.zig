//! Layout of the picker ruler: the marks drawn over the dimmed screen so the
//! picker also measures. For a selection (a drag or a hovered window): a
//! dimension line along its top and its left edge with the size on it (like
//! an architect's plan: end ticks, number on the line), and a dashed hairline
//! from each edge to the screen edge with its distance. With no selection:
//! dashed hairlines from the pointer to the four screen edges. Pure geometry:
//! `picker_draw.zig` paints the result.
const std = @import("std");
const geom = @import("geom.zig");
const text = @import("text.zig");
const Ctx = @import("draw.zig").Ctx;

const Rect = geom.Rect;
const Vec2 = geom.Vec2;

pub const Line = struct {
    r: Rect,
    /// Painted as dashes (a distance hairline) instead of solid.
    dashed: bool = false,
    /// A dimension line of the selection, brighter than a distance hairline.
    strong: bool = false,
};

/// A number on a line, in a small flat plate.
pub const Label = struct {
    rect: Rect,
    buf: [12]u8 = undefined,
    len: u8 = 0,
    px: u16 = 0,
    text_x: f32 = 0,
    /// The selection size, not a distance.
    strong: bool = false,

    pub fn str(l: *const Label) []const u8 {
        return l.buf[0..l.len];
    }
};

pub const Marks = struct {
    lines: [24]Line = undefined,
    n_lines: usize = 0,
    labels: [8]Label = undefined,
    n_labels: usize = 0,
    /// Line thickness, px.
    t: i32 = 1,
    s: f32 = 1,
    w: i32 = 0,
    h: i32 = 0,

    pub fn lineSlice(m: *const Marks) []const Line {
        return m.lines[0..m.n_lines];
    }

    pub fn labelSlice(m: *const Marks) []const Label {
        return m.labels[0..m.n_labels];
    }

    /// Every rectangle the marks cover, for damage. `out` must hold lines + labels.
    pub fn rects(m: *const Marks, out: []Rect) usize {
        var n: usize = 0;
        for (m.lineSlice()) |l| {
            out[n] = l.r;
            n += 1;
        }
        for (m.labelSlice()) |l| {
            out[n] = l.rect;
            n += 1;
        }
        return n;
    }

    pub const max_rects = 24 + 8;

    fn line(m: *Marks, r: Rect, dashed: bool, strong: bool) void {
        if (r.isEmpty() or m.n_lines == m.lines.len) return;
        m.lines[m.n_lines] = .{ .r = r, .dashed = dashed, .strong = strong };
        m.n_lines += 1;
    }

    /// A horizontal line from x0 to x1 at y, with a tick of half length `tick` at each end.
    fn hline(m: *Marks, x0: i32, x1: i32, y: i32, tick: i32, dashed: bool, strong: bool) void {
        const t = m.t;
        m.line(.{ .x0 = x0, .y0 = y, .x1 = x1, .y1 = y + t }, dashed, strong);
        m.line(.{ .x0 = x0, .y0 = y - tick, .x1 = x0 + t, .y1 = y + t + tick }, false, strong);
        m.line(.{ .x0 = x1 - t, .y0 = y - tick, .x1 = x1, .y1 = y + t + tick }, false, strong);
    }

    fn vline(m: *Marks, y0: i32, y1: i32, x: i32, tick: i32, dashed: bool, strong: bool) void {
        const t = m.t;
        m.line(.{ .x0 = x, .y0 = y0, .x1 = x + t, .y1 = y1 }, dashed, strong);
        m.line(.{ .x0 = x - tick, .y0 = y0, .x1 = x + t + tick, .y1 = y0 + t }, false, strong);
        m.line(.{ .x0 = x - tick, .y0 = y1 - t, .x1 = x + t + tick, .y1 = y1 }, false, strong);
    }

    /// A plate with `n` centered on (cx, cy), kept inside the screen.
    fn label(m: *Marks, ctx: Ctx, cx: f32, cy: f32, n: i32, strong: bool) ?Rect {
        if (m.n_labels == m.labels.len) return null;
        var l = Label{ .rect = .empty, .strong = strong };
        const s = std.fmt.bufPrint(&l.buf, "{d}", .{n}) catch return null;
        l.len = @intCast(s.len);
        l.px = text.pxOf((if (strong) @as(f32, 13.0) else @as(f32, 11.5)) * m.s);
        const tw = text.measure(ctx.font, s, l.px).width;
        const pad = 4 * m.s;
        const lw = tw + 2 * pad;
        const lh = plateHeight(m.s);
        const x0 = std.math.clamp(cx - lw / 2, 0, @max(0, @as(f32, @floatFromInt(m.w)) - lw));
        const y0 = std.math.clamp(cy - lh / 2, 0, @max(0, @as(f32, @floatFromInt(m.h)) - lh));
        const rx: i32 = @intFromFloat(@round(x0));
        const ry: i32 = @intFromFloat(@round(y0));
        l.rect = .{ .x0 = rx, .y0 = ry, .x1 = rx + @as(i32, @intFromFloat(@round(lw))), .y1 = ry + @as(i32, @intFromFloat(@round(lh))) };
        l.text_x = x0 + pad;
        m.labels[m.n_labels] = l;
        m.n_labels += 1;
        return l.rect;
    }

    fn free(m: *const Marks, r: Rect) bool {
        for (m.labelSlice()) |l| if (l.rect.expand(2).intersects(r)) return false;
        return true;
    }

    /// Distance hairline along x at row y, from a to b; its number sits mid-way
    /// when it fits and hides no other number.
    fn hdist(m: *Marks, ctx: Ctx, a: i32, b: i32, y: i32) void {
        if (b - a < 2) return;
        m.hline(a, b, y, @intFromFloat(@round(3 * m.s)), true, false);
        m.distLabel(ctx, @as(f32, @floatFromInt(a + b)) / 2, @floatFromInt(y), b - a, true);
    }

    fn vdist(m: *Marks, ctx: Ctx, a: i32, b: i32, x: i32) void {
        if (b - a < 2) return;
        m.vline(a, b, x, @intFromFloat(@round(3 * m.s)), true, false);
        m.distLabel(ctx, @floatFromInt(x), @as(f32, @floatFromInt(a + b)) / 2, b - a, false);
    }

    fn distLabel(m: *Marks, ctx: Ctx, cx: f32, cy: f32, n: i32, horizontal: bool) void {
        // Needs room for the plate along the line, plus a margin.
        const need = (if (horizontal) @as(f32, 36.0) else @as(f32, 16.0)) * m.s + 10 * m.s;
        if (@as(f32, @floatFromInt(n)) < need) return;
        const probe = Rect{ .x0 = @intFromFloat(cx - 18 * m.s), .y0 = @intFromFloat(cy - 8 * m.s), .x1 = @intFromFloat(cx + 18 * m.s), .y1 = @intFromFloat(cy + 8 * m.s) };
        if (!m.free(probe)) return;
        _ = m.label(ctx, cx, cy, n, false);
    }
};

pub fn plateHeight(s: f32) f32 {
    return 16 * s;
}

/// Marks for a selection `hi` on a screen of w x h, or for the `pointer` alone.
pub fn build(ctx: Ctx, hi: ?Rect, pointer: ?Vec2, w: u32, h: u32, scale: f32) Marks {
    var m = Marks{ .s = scale, .w = @intCast(w), .h = @intCast(h) };
    m.t = @max(1, @as(i32, @intFromFloat(@round(scale))));
    if (hi) |r| {
        selection(ctx, &m, r);
    } else if (pointer) |p| {
        const px: i32 = std.math.clamp(@as(i32, @intFromFloat(@floor(p.x))), 0, m.w - 1);
        const py: i32 = std.math.clamp(@as(i32, @intFromFloat(@floor(p.y))), 0, m.h - 1);
        m.hdist(ctx, 0, px, py);
        m.hdist(ctx, px, m.w, py);
        m.vdist(ctx, 0, py, px);
        m.vdist(ctx, py, m.h, px);
    }
    return m;
}

fn selection(ctx: Ctx, m: *Marks, r: Rect) void {
    const s = m.s;
    const off: i32 = @intFromFloat(@round(18 * s));
    const lh: i32 = @intFromFloat(@round(plateHeight(s)));
    const half_h = @divTrunc(lh, 2);
    const cx: f32 = @as(f32, @floatFromInt(r.x0 + r.x1)) / 2;
    const cy: f32 = @as(f32, @floatFromInt(r.y0 + r.y1)) / 2;
    const tick: i32 = @intFromFloat(@round(4 * s));

    // Width: a dimension line above the top edge (below, then inside, when
    // there is no room); the number sits on it.
    var wy = r.y0 - off;
    if (wy - half_h < 0) {
        wy = r.y1 + off;
        if (wy + half_h > m.h) wy = r.y0 + off;
    }
    m.hline(r.x0, r.x1, wy, tick, false, true);
    // Height: the same along the left edge.
    const lw: i32 = @intFromFloat(@round(40 * s));
    var hx = r.x0 - off;
    if (hx - @divTrunc(lw, 2) < 0) {
        hx = r.x1 + off;
        if (hx + @divTrunc(lw, 2) > m.w) hx = r.x0 + off;
    }
    m.vline(r.y0, r.y1, hx, tick, false, true);
    _ = m.label(ctx, cx, @floatFromInt(wy), r.width(), true);
    _ = m.label(ctx, @floatFromInt(hx), cy, r.height(), true);

    // Distances to the screen edges, on the far side of the middle so they do
    // not run into the size numbers.
    const qx: i32 = r.x0 + @divTrunc(r.width() * 3, 4);
    const qy: i32 = r.y0 + @divTrunc(r.height() * 3, 4);
    m.hdist(ctx, 0, r.x0, qy);
    m.hdist(ctx, r.x1, m.w, qy);
    m.vdist(ctx, 0, r.y0, qx);
    m.vdist(ctx, r.y1, m.h, qx);
}

fn testMarks(gpa: std.mem.Allocator, font: *@import("font.zig").Font, hi: ?Rect, ptr: ?Vec2) Marks {
    return build(.{ .gpa = gpa, .font = font }, hi, ptr, 1000, 600, 1);
}

test "a selection gets its size and four distances to the screen edges" {
    const gpa = std.testing.allocator;
    var font = try @import("font.zig").Font.init(gpa, @import("root.zig").font_ttf);
    defer font.deinit();
    const m = testMarks(gpa, &font, Rect.fromSize(200, 150, 400, 300), null);
    const want = [_][]const u8{ "400", "300", "200", "400", "150", "150" };
    try std.testing.expectEqual(want.len, m.n_labels);
    for (want, m.labelSlice()) |w, l| try std.testing.expectEqualStrings(w, l.str());
    for (m.labelSlice()) |l| try std.testing.expectEqual(l.rect, Rect.fromSize(0, 0, 1000, 600).intersect(l.rect));
}

test "a selection against the screen edges has no distance there, and its size moves inside" {
    const gpa = std.testing.allocator;
    var font = try @import("font.zig").Font.init(gpa, @import("root.zig").font_ttf);
    defer font.deinit();
    const m = testMarks(gpa, &font, Rect.fromSize(0, 0, 1000, 600), null);
    try std.testing.expectEqual(@as(usize, 2), m.n_labels);
}

test "with no selection the pointer gets four distances" {
    const gpa = std.testing.allocator;
    var font = try @import("font.zig").Font.init(gpa, @import("root.zig").font_ttf);
    defer font.deinit();
    const m = testMarks(gpa, &font, null, .{ .x = 300, .y = 200 });
    const want = [_][]const u8{ "300", "700", "200", "400" };
    try std.testing.expectEqual(want.len, m.n_labels);
    for (want, m.labelSlice()) |w, l| try std.testing.expectEqualStrings(w, l.str());
}
