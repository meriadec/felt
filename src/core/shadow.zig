//! Elevation shadow of a rectangle: three stacked Gaussian-like blurs (a tight
//! contact shadow, a medium one, a wide ambient one), lit from above, plus a
//! 1 px border. All numbers that tune the look are the named constants here.
//!
//! The blur of a rectangle is separable: the shadow at (x, y) is
//! `alpha * fx(x) * fy(y)`, with `fx` and `fy` the blurred edge profiles of
//! the rectangle's two sides. So no shadow tile is cached: each call builds
//! four short 1D tables per layer (one pass over the width and the height of
//! the damaged area), then each pixel costs a few multiplies. A slight
//! ordered dither (keyed on an `anchor` point that moves with the view, so a
//! pan, a canvas growth or a partial repaint gives the same pixels) hides the 8-bit banding of
//! the long, faint falloff.
const std = @import("std");
const color = @import("color.zig");
const geom = @import("geom.zig");
const canvas = @import("canvas.zig");
const Canvas = canvas.Canvas;
const Rect = geom.Rect;

/// What the shadow falls on: a light canvas needs a faint, cool shadow; a dark
/// surface needs a stronger one.
pub const Theme = enum { light, dark };

/// One blur layer. Lengths are in units of `unit` (see `unitFor`).
pub const Layer = struct {
    /// Standard deviation of the blur.
    sigma: f32,
    /// Shift down (light from the top).
    dy: f32,
    /// Peak opacity (0..1) in the light and the dark theme, before the blur
    /// (at the rectangle edge the shadow shows about half of it).
    alpha_light: f32,
    alpha_dark: f32,
};

/// Contact, medium, ambient. Opacities add up to about 13 % at the edge of the
/// rectangle in the light theme.
pub const layers = [_]Layer{
    .{ .sigma = 0.2, .dy = 0.1, .alpha_light = 0.10, .alpha_dark = 0.30 },
    .{ .sigma = 0.55, .dy = 0.35, .alpha_light = 0.09, .alpha_dark = 0.30 },
    .{ .sigma = 1.2, .dy = 0.8, .alpha_light = 0.08, .alpha_dark = 0.25 },
};

/// Shadow color per theme: a cool, deep blue-grey on light, black on dark.
pub const tint_light = color.Color{ .r = 18, .g = 28, .b = 48 };
pub const tint_dark = color.Color{ .r = 0, .g = 0, .b = 0 };

/// 1 px border outside the rectangle: nearly invisible on light, a faint
/// light line on dark.
pub const border_light = color.Color{ .r = 18, .g = 28, .b = 48, .a = 20 };
pub const border_dark = color.Color{ .r = 255, .g = 255, .b = 255, .a = 32 };

/// The unit of the layer lengths (screen px) is `unit_per_side` times the
/// shorter side of the rectangle, kept between `unit_min` and `unit_max`: the
/// shadow grows with zoom and image size, never vanishes, never floods a
/// 64 image px gap at low zoom.
pub const unit_per_side: f32 = 0.06;
pub const unit_min: f32 = 7;
pub const unit_max: f32 = 16;

/// The blur is cut at this many sigmas.
pub const cut_sigmas: f32 = 3.2;

/// Largest distance from a rectangle (px) that a shadow reaches: damage
/// rectangles grow by this.
pub const max_reach: i32 = blk: {
    var m: f32 = 0;
    for (layers) |l| m = @max(m, l.dy + cut_sigmas * l.sigma);
    break :blk @as(i32, @intFromFloat(@ceil(m * unit_max))) + 1;
};

/// Below this total opacity a pixel is left alone.
const min_alpha: f32 = 1.0 / 1024.0;
/// Slope of the logistic that stands for the Gaussian CDF.
const logistic_k: f32 = 1.702;
/// Widest table (columns or rows per pass).
const max_span = 4096;

/// The unit under the canvas: fixed, so that growing the canvas (a drag, an
/// annotation past the edge) never changes the shadow along the old edges.
pub const canvas_unit: f32 = 12;

/// The unit under an image (see `unit_per_side`).
pub fn unitFor(c: Rect) f32 {
    const side: f32 = @floatFromInt(@min(c.width(), c.height()));
    return std.math.clamp(side * unit_per_side, unit_min, unit_max);
}

/// How far from a rectangle its shadow reaches (px) for a unit.
pub fn reachFor(u: f32) i32 {
    var m: f32 = 0;
    for (layers) |l| m = @max(m, l.dy + cut_sigmas * l.sigma);
    return @as(i32, @intFromFloat(@ceil(m * u))) + 1;
}

/// Gaussian CDF (as a logistic) in sigmas, rescaled to be exactly 0 below
/// `-cut_sigmas` and exactly 1 above `cut_sigmas`: a shadow then ends where
/// `reachFor` says, so a repaint of a strip that far from a changed edge gives the
/// same pixels as a full repaint.
inline fn cdf(z: f32) f32 {
    if (z <= -cut_sigmas) return 0;
    if (z >= cut_sigmas) return 1;
    const lo = 1 / (1 + @exp(logistic_k * cut_sigmas));
    return (1 / (1 + @exp(-logistic_k * z)) - lo) / (1 - 2 * lo);
}

/// Blurred profile of the segment [a, b) at pixel centers `lo`..`lo + out.len`.
fn profile(out: []f32, lo: i32, a: f32, b: f32, sigma: f32) void {
    const inv = 1 / sigma;
    for (out, 0..) |*o, i| {
        const p: f32 = @as(f32, @floatFromInt(lo + @as(i32, @intCast(i)))) + 0.5;
        o.* = cdf((p - a) * inv) - cdf((p - b) * inv);
    }
}

const bayer = [16]f32{ 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };

/// Paint the shadow and the border of rectangle `c` in `r_in`, outside `c`
/// (the caller has painted the surface there).
pub fn paint(cv: *Canvas, r_in: Rect, c: Rect, theme: Theme, u: f32, anchor: [2]i32) void {
    if (c.isEmpty()) return;
    const r = r_in.intersect(c.expand(reachFor(u))).intersect(cv.bounds());
    if (r.isEmpty()) return;
    var x0 = r.x0;
    while (x0 < r.x1) : (x0 += max_span) {
        const x1 = @min(r.x1, x0 + max_span);
        var y0 = r.y0;
        while (y0 < r.y1) : (y0 += max_span) {
            paintChunk(cv, .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = @min(r.y1, y0 + max_span) }, c, theme, u, anchor);
        }
    }
}

fn paintChunk(cv: *Canvas, r: Rect, c: Rect, theme: Theme, u: f32, anchor: [2]i32) void {
    const w: usize = @intCast(r.width());
    const h: usize = @intCast(r.height());
    var tx: [layers.len][max_span]f32 = undefined;
    var ty: [layers.len][max_span]f32 = undefined;
    var amp: [layers.len]f32 = undefined;
    const cx0: f32 = @floatFromInt(c.x0);
    const cx1: f32 = @floatFromInt(c.x1);
    const cy0: f32 = @floatFromInt(c.y0);
    const cy1: f32 = @floatFromInt(c.y1);
    for (layers, 0..) |l, i| {
        amp[i] = if (theme == .light) l.alpha_light else l.alpha_dark;
        profile(tx[i][0..w], r.x0, cx0, cx1, l.sigma * u);
        profile(ty[i][0..h], r.y0, cy0 + l.dy * u, cy1 + l.dy * u, l.sigma * u);
    }
    const tint = if (theme == .light) tint_light else tint_dark;
    const border = if (theme == .light) border_light else border_dark;
    const tr: f32 = @floatFromInt(tint.r);
    const tg: f32 = @floatFromInt(tint.g);
    const tb: f32 = @floatFromInt(tint.b);
    var y = r.y0;
    while (y < r.y1) : (y += 1) {
        const iy: usize = @intCast(y - r.y0);
        var ay: [layers.len]f32 = undefined;
        inline for (0..layers.len) |i| ay[i] = amp[i] * ty[i][iy];
        const inside_rows = y >= c.y0 and y < c.y1;
        const base = @as(usize, @intCast(y)) * cv.width;
        const dr: [4]f32 = .{
            (bayer[@as(usize, @intCast(@mod(y - anchor[1], 4))) * 4 + 0] + 0.5) / 16.0,
            (bayer[@as(usize, @intCast(@mod(y - anchor[1], 4))) * 4 + 1] + 0.5) / 16.0,
            (bayer[@as(usize, @intCast(@mod(y - anchor[1], 4))) * 4 + 2] + 0.5) / 16.0,
            (bayer[@as(usize, @intCast(@mod(y - anchor[1], 4))) * 4 + 3] + 0.5) / 16.0,
        };
        const ctx = Row{ .px = cv.pixels[base..], .c0 = anchor[0], .r0 = r.x0, .tx = &tx, .ay = ay, .dr = dr, .tint = .{ tr, tg, tb } };
        if (inside_rows) {
            run(ctx, r.x0, @min(r.x1, c.x0));
            run(ctx, @max(r.x0, c.x1), r.x1);
        } else run(ctx, r.x0, r.x1);
    }
    ring(cv, r, c, border);
}

/// One row to shade: its pixels, the origin of the dither, the x tables and the
/// per-layer opacity of this row.
const Row = struct {
    px: []u32,
    c0: i32,
    r0: i32,
    tx: *const [layers.len][max_span]f32,
    ay: [layers.len]f32,
    dr: [4]f32,
    tint: [3]f32,
};

/// Shade the pixels [xa, xb) of a row, 8 at a time then one by one.
fn run(row: Row, xa: i32, xb: i32) void {
    var x = xa;
    while (x + 8 <= xb) : (x += 8) shade(8, row, x);
    while (x < xb) : (x += 1) shade(1, row, x);
}

inline fn shade(comptime n: usize, row: Row, x: i32) void {
    const V = @Vector(n, f32);
    const U = @Vector(n, u32);
    const ci: usize = @intCast(x - row.r0);
    var keep: V = @splat(1);
    inline for (0..layers.len) |i| {
        const t: V = row.tx[i][ci..][0..n].*;
        keep *= @as(V, @splat(1)) - t * @as(V, @splat(row.ay[i]));
    }
    const a = @as(V, @splat(1)) - keep;
    var th: [n]f32 = undefined;
    const ph: usize = @intCast((x - row.c0) & 3);
    for (&th, 0..) |*t, j| t.* = row.dr[(ph + j) & 3];
    const t: V = th;
    const px: *[n]u32 = row.px[@intCast(x)..][0..n];
    const d: U = px.*;
    const mask: U = @splat(0xff);
    const fr: V = @floatFromInt((d >> @as(@Vector(n, u5), @splat(16))) & mask);
    const fg: V = @floatFromInt((d >> @as(@Vector(n, u5), @splat(8))) & mask);
    const fb: V = @floatFromInt(d & mask);
    const nr: U = @intFromFloat(fr + (@as(V, @splat(row.tint[0])) - fr) * a + t);
    const ng: U = @intFromFloat(fg + (@as(V, @splat(row.tint[1])) - fg) * a + t);
    const nb: U = @intFromFloat(fb + (@as(V, @splat(row.tint[2])) - fb) * a + t);
    const lit = a >= @as(V, @splat(min_alpha));
    const out = @as(U, @splat(0xff000000)) | (nr << @as(@Vector(n, u5), @splat(16))) | (ng << @as(@Vector(n, u5), @splat(8))) | nb;
    px.* = @select(u32, lit, out, d);
}

/// The 1 px border ring just outside `c`, where it meets `r`.
fn ring(cv: *Canvas, r: Rect, c: Rect, border: color.Color) void {
    const e = c.expand(1);
    for ([_]Rect{
        .{ .x0 = e.x0, .y0 = e.y0, .x1 = e.x1, .y1 = c.y0 },
        .{ .x0 = e.x0, .y0 = c.y1, .x1 = e.x1, .y1 = e.y1 },
        .{ .x0 = e.x0, .y0 = c.y0, .x1 = c.x0, .y1 = c.y1 },
        .{ .x0 = c.x1, .y0 = c.y0, .x1 = e.x1, .y1 = c.y1 },
    }) |b| cv.blendRect(b.intersect(r), border);
}

test "shadow fades smoothly and stays outside the rectangle" {
    const gpa = std.testing.allocator;
    var cv = try Canvas.init(gpa, 200, 200);
    defer cv.deinit(gpa);
    cv.fill(color.Color.rgb(0xF5F7FA));
    const c = Rect{ .x0 = 60, .y0 = 40, .x1 = 140, .y1 = 120 };
    cv.fillRect(c, color.Color.rgb(0xffffff));
    paint(&cv, cv.bounds(), c, .light, unitFor(c), .{ c.x0, c.y0 });
    // Inside untouched, below the rectangle darker than above it.
    try std.testing.expectEqual(@as(color.Pixel, 0xffffffff), cv.at(100, 80));
    try std.testing.expect((cv.at(100, 125) & 0xff) < (cv.at(100, 35) & 0xff));
    // Monotonic (within dither) away from the bottom edge.
    var prev: u32 = 0;
    var y: i32 = 122;
    while (y < 160) : (y += 1) {
        const v = cv.at(100, y) & 0xff;
        try std.testing.expect(v + 1 >= prev);
        prev = v;
    }
    // Far away: untouched.
    try std.testing.expectEqual(@as(color.Pixel, 0xffF5F7FA), cv.at(100, 199));
    try std.testing.expect(reachFor(unitFor(c)) <= max_reach);
}

test "painting in pieces gives the pixels of painting at once" {
    const gpa = std.testing.allocator;
    var a = try Canvas.init(gpa, 200, 160);
    defer a.deinit(gpa);
    var b = try Canvas.init(gpa, 200, 160);
    defer b.deinit(gpa);
    a.fill(color.Color.rgb(0xF5F7FA));
    b.fill(color.Color.rgb(0xF5F7FA));
    const c = Rect{ .x0 = 53, .y0 = 41, .x1 = 143, .y1 = 111 };
    paint(&a, a.bounds(), c, .light, unitFor(c), .{ c.x0, c.y0 });
    var x: i32 = 0;
    while (x < 200) : (x += 13) paint(&b, .{ .x0 = x, .y0 = 0, .x1 = x + 13, .y1 = 160 }, c, .light, unitFor(c), .{ c.x0, c.y0 });
    try std.testing.expectEqualSlices(color.Pixel, a.pixels, b.pixels);
}
