//! View: the image-to-screen transform. `fit` puts the canvas (the image, or
//! its crop, grown by annotations) inside the screen, never above 1:1,
//! centered. `zoomAt` and `panBy` move it freely (zoom steps in `levels`).
//! The offset is always whole screen pixels, so 1:1 views blit the image as
//! is and a pan is an exact scroll.
const std = @import("std");
const geom = @import("geom.zig");

pub const View = struct {
    screen_w: u32,
    screen_h: u32,
    /// Image to screen transform. `offset` is whole pixels.
    xf: geom.Xform,

    /// Fit the canvas rectangle `canvas` (image px) to the screen.
    pub fn fit(canvas: geom.Rect, screen_w: u32, screen_h: u32) View {
        const iw: f32 = @floatFromInt(@max(1, canvas.width()));
        const ih: f32 = @floatFromInt(@max(1, canvas.height()));
        const sw: f32 = @floatFromInt(screen_w);
        const sh: f32 = @floatFromInt(screen_h);
        const s = @min(1.0, @min(sw / iw, sh / ih));
        const dw: i32 = @max(1, @as(i32, @intFromFloat(@round(iw * s))));
        const dh: i32 = @max(1, @as(i32, @intFromFloat(@round(ih * s))));
        const ox = @divFloor(@as(i32, @intCast(screen_w)) - dw, 2);
        const oy = @divFloor(@as(i32, @intCast(screen_h)) - dh, 2);
        const scale = @as(f32, @floatFromInt(dw)) / iw;
        const x0: f32 = @floatFromInt(canvas.x0);
        const y0: f32 = @floatFromInt(canvas.y0);
        return .{
            .screen_w = screen_w,
            .screen_h = screen_h,
            .xf = .{ .scale = scale, .offset = .{ .x = @as(f32, @floatFromInt(ox)) - @round(x0 * scale), .y = @as(f32, @floatFromInt(oy)) - @round(y0 * scale) } },
        };
    }

    /// The whole screen.
    pub fn screen(v: View) geom.Rect {
        return geom.Rect.fromSize(0, 0, @intCast(v.screen_w), @intCast(v.screen_h));
    }

    /// Screen rectangle of the image rectangle `r`, edges rounded. Not clipped.
    pub fn rect(v: View, r: geom.Rect) geom.Rect {
        if (r.isEmpty()) return geom.Rect.empty;
        const s = v.xf.scale;
        const ox: i32 = @intFromFloat(v.xf.offset.x);
        const oy: i32 = @intFromFloat(v.xf.offset.y);
        return .{
            .x0 = round(r.x0, s) + ox,
            .y0 = round(r.y0, s) + oy,
            .x1 = round(r.x1, s) + ox,
            .y1 = round(r.y1, s) + oy,
        };
    }

    fn round(x: i32, s: f32) i32 {
        const lim = 1e8;
        return @intFromFloat(std.math.clamp(@round(@as(f32, @floatFromInt(x)) * s), -lim, lim));
    }

    /// Scale `scale` with the image point under the screen point `p` fixed.
    pub fn zoomAt(v: View, scale: f32, p: geom.Vec2) View {
        const k = scale / v.xf.scale;
        const o = p.sub(p.sub(v.xf.offset).scale(k));
        var out = v;
        out.xf = .{ .scale = scale, .offset = .{ .x = @round(o.x), .y = @round(o.y) } };
        return out;
    }

    /// Move the image by whole screen pixels.
    pub fn panBy(v: View, dx: i32, dy: i32) View {
        var out = v;
        out.xf.offset = out.xf.offset.add(.{ .x = @floatFromInt(dx), .y = @floatFromInt(dy) });
        return out;
    }

    pub fn toImage(v: View, p: geom.Vec2) geom.Vec2 {
        return v.xf.invert(p);
    }

    pub fn toScreen(v: View, p: geom.Vec2) geom.Vec2 {
        return v.xf.apply(p);
    }
};

/// Zoom steps. Whole and simple fractions keep image pixels even on screen.
pub const levels = [_]f32{ 1.0 / 16.0, 1.0 / 12.0, 1.0 / 8.0, 1.0 / 6.0, 1.0 / 4.0, 1.0 / 3.0, 1.0 / 2.0, 2.0 / 3.0, 1, 1.5, 2, 3, 4, 6, 8 };

/// The zoom level `steps` levels above (or below) the scale `s`; a scale
/// between two levels goes to the next one in that direction.
pub fn zoomStep(s: f32, steps: i32) f32 {
    var cur = s;
    var n = steps;
    while (n > 0) : (n -= 1) {
        for (levels) |l| if (l > cur * 1.001) {
            cur = l;
            break;
        };
    }
    while (n < 0) : (n += 1) {
        var i: usize = levels.len;
        while (i > 0) {
            i -= 1;
            if (levels[i] < cur * 0.999) {
                cur = levels[i];
                break;
            }
        }
    }
    return cur;
}

test "zoom steps snap to levels and stop at the ends" {
    try std.testing.expectEqual(@as(f32, 1), zoomStep(0.8, 1));
    try std.testing.expectEqual(@as(f32, 2.0 / 3.0), zoomStep(0.8, -1));
    try std.testing.expectEqual(@as(f32, 2), zoomStep(1, 2));
    try std.testing.expectEqual(levels[0], zoomStep(levels[0], -1));
    try std.testing.expectEqual(levels[levels.len - 1], zoomStep(8, 3));
}

test "zoomAt keeps the point under the pointer; panBy moves whole pixels" {
    const v = View.fit(geom.Rect.fromSize(0, 0, 100, 50), 1000, 1000);
    const p = geom.Vec2.init(470, 490);
    const z = v.zoomAt(2, p);
    const a = v.toImage(p);
    const b = z.toImage(p);
    try std.testing.expectApproxEqAbs(a.x, b.x, 0.5);
    try std.testing.expectApproxEqAbs(a.y, b.y, 0.5);
    const m = z.panBy(7, -3);
    try std.testing.expectEqual(z.xf.offset.add(.{ .x = 7, .y = -3 }), m.xf.offset);
}

test "fit scales down, centers, never up" {
    const v = View.fit(geom.Rect.fromSize(0, 0, 2000, 1000), 1000, 1000);
    try std.testing.expectEqual(@as(f32, 0.5), v.xf.scale);
    try std.testing.expectEqual(geom.Rect.fromSize(0, 250, 1000, 500), v.rect(geom.Rect.fromSize(0, 0, 2000, 1000)));
    const small = View.fit(geom.Rect.fromSize(0, 0, 100, 50), 1000, 1000);
    try std.testing.expectEqual(@as(f32, 1), small.xf.scale);
    try std.testing.expectEqual(geom.Rect.fromSize(450, 475, 100, 50), small.rect(geom.Rect.fromSize(0, 0, 100, 50)));
}

test "a crop or a grown canvas fits its own rectangle and keeps image coordinates" {
    const v = View.fit(geom.Rect.fromSize(500, 200, 100, 50), 1000, 1000);
    try std.testing.expectEqual(@as(f32, 1), v.xf.scale);
    try std.testing.expectEqual(geom.Rect.fromSize(450, 475, 100, 50), v.rect(geom.Rect.fromSize(500, 200, 100, 50)));
    try std.testing.expectEqual(geom.Vec2.init(450, 475), v.toScreen(.{ .x = 500, .y = 200 }));
    const g = View.fit(geom.Rect.fromSize(-50, -10, 200, 100), 1000, 1000);
    try std.testing.expectEqual(geom.Vec2.init(400, 450), g.toScreen(.{ .x = -50, .y = -10 }));
}
