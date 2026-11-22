//! View: where the image (or its kept part after a crop) sits on screen.
//! Fit inside the screen, never scale above 1:1, centered on whole pixels.
const std = @import("std");
const geom = @import("geom.zig");

pub const View = struct {
    screen_w: u32,
    screen_h: u32,
    /// Full image size.
    image_w: u32,
    image_h: u32,
    /// Part of the image on screen (image px): the crop, or all of it.
    src: geom.Rect,
    /// Image to screen transform.
    xf: geom.Xform,
    /// Screen rectangle covered by the image.
    dst: geom.Rect,

    pub fn fit(image_w: u32, image_h: u32, screen_w: u32, screen_h: u32) View {
        return fitRect(image_w, image_h, geom.Rect.fromSize(0, 0, @intCast(image_w), @intCast(image_h)), screen_w, screen_h);
    }

    /// Fit the part `src` of an image_w x image_h image.
    pub fn fitRect(image_w: u32, image_h: u32, src: geom.Rect, screen_w: u32, screen_h: u32) View {
        const iw: f32 = @floatFromInt(src.width());
        const ih: f32 = @floatFromInt(src.height());
        const sw: f32 = @floatFromInt(screen_w);
        const sh: f32 = @floatFromInt(screen_h);
        const s = @min(1.0, @min(sw / iw, sh / ih));
        const dw: i32 = @max(1, @as(i32, @intFromFloat(@round(iw * s))));
        const dh: i32 = @max(1, @as(i32, @intFromFloat(@round(ih * s))));
        const ox = @divFloor(@as(i32, @intCast(screen_w)) - dw, 2);
        const oy = @divFloor(@as(i32, @intCast(screen_h)) - dh, 2);
        const scale = @as(f32, @floatFromInt(dw)) / iw;
        return .{
            .screen_w = screen_w,
            .screen_h = screen_h,
            .image_w = image_w,
            .image_h = image_h,
            .src = src,
            .xf = .{ .scale = scale, .offset = .{ .x = @as(f32, @floatFromInt(ox)) - @as(f32, @floatFromInt(src.x0)) * scale, .y = @as(f32, @floatFromInt(oy)) - @as(f32, @floatFromInt(src.y0)) * scale } },
            .dst = geom.Rect.fromSize(ox, oy, dw, dh),
        };
    }

    pub fn toImage(v: View, p: geom.Vec2) geom.Vec2 {
        return v.xf.invert(p);
    }

    pub fn toScreen(v: View, p: geom.Vec2) geom.Vec2 {
        return v.xf.apply(p);
    }
};

test "fit scales down, centers, never up" {
    const v = View.fit(2000, 1000, 1000, 1000);
    try std.testing.expectEqual(@as(f32, 0.5), v.xf.scale);
    try std.testing.expectEqual(geom.Rect.fromSize(0, 250, 1000, 500), v.dst);
    const small = View.fit(100, 50, 1000, 1000);
    try std.testing.expectEqual(@as(f32, 1), small.xf.scale);
    try std.testing.expectEqual(geom.Rect.fromSize(450, 475, 100, 50), small.dst);
}

test "a crop fits its own part and keeps image coordinates" {
    const v = View.fitRect(2000, 1000, geom.Rect.fromSize(500, 200, 100, 50), 1000, 1000);
    try std.testing.expectEqual(@as(f32, 1), v.xf.scale);
    try std.testing.expectEqual(geom.Rect.fromSize(450, 475, 100, 50), v.dst);
    const p = v.toScreen(.{ .x = 500, .y = 200 });
    try std.testing.expectEqual(geom.Vec2.init(450, 475), p);
}
