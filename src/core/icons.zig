//! Tool icons: small vector drawings built from signed distance shapes and
//! filled by the anti-aliased rasterizer, so they stay crisp at any UI scale.
//! Each icon is designed in a unit box [-1, 1]^2 and mapped to `size` px.
const std = @import("std");
const geom = @import("geom.zig");
const sdf = @import("sdf.zig");
const raster = @import("raster.zig");
const Canvas = @import("canvas.zig").Canvas;
const Color = @import("color.zig").Color;
const Tool = @import("keymap.zig").Tool;

const Vec2 = geom.Vec2;
const Rect = geom.Rect;

/// Maps unit-box coordinates to the screen.
const Pen = struct {
    cv: *Canvas,
    clip: Rect,
    c: Vec2,
    /// Half the icon edge in px.
    k: f32,
    color: Color,
    /// Stroke width in px.
    w: f32,
    /// -1 mirrors the icon left to right.
    sx: f32 = 1,

    fn p(pen: Pen, x: f32, y: f32) Vec2 {
        return .{ .x = pen.c.x + x * pen.sx * pen.k, .y = pen.c.y + y * pen.k };
    }
    fn fill(pen: Pen, shape: anytype, alpha: f32) void {
        const a: u8 = @intFromFloat(@as(f32, @floatFromInt(pen.color.a)) * alpha);
        raster.fill(pen.cv, pen.clip, shape, .{ .solid = pen.color.withAlpha(a) }, .{});
    }
    fn line(pen: Pen, x0: f32, y0: f32, x1: f32, y1: f32) void {
        pen.fill(sdf.Capsule{ .a = pen.p(x0, y0), .b = pen.p(x1, y1), .r = pen.w * 0.5 }, 1);
    }
    fn box(pen: Pen, x0: f32, y0: f32, x1: f32, y1: f32, radius: f32) sdf.RoundRect {
        const a = pen.p(x0, y0);
        const b = pen.p(x1, y1);
        return .{ .min = a.min(b), .max = a.max(b), .radius = radius * pen.k };
    }
    fn tri(pen: Pen, a: [2]f32, b: [2]f32, c: [2]f32) sdf.Triangle {
        return .{ .a = pen.p(a[0], a[1]), .b = pen.p(b[0], b[1]), .c = pen.p(c[0], c[1]) };
    }
};

/// Draw the icon of `tool` centered on `c`, `size` px wide and high.
pub fn draw(cv: *Canvas, clip: Rect, tool: Tool, c: Vec2, size: f32, color: Color) void {
    const pen = Pen{ .cv = cv, .clip = clip, .c = c, .k = size * 0.5, .color = color, .w = @max(1.5, size * 0.11) };
    switch (tool) {
        .arrow => {
            pen.line(-0.7, 0.7, 0.3, -0.3);
            pen.fill(pen.tri(.{ 0.8, -0.8 }, .{ 0.62, 0.02 }, .{ -0.02, -0.62 }), 1);
        },
        .text => {
            pen.line(-0.65, -0.7, 0.65, -0.7);
            pen.line(0, -0.7, 0, 0.75);
            pen.line(-0.3, 0.75, 0.3, 0.75);
        },
        .rect => pen.fill(sdf.ring(pen.box(-0.78, -0.6, 0.78, 0.6, 0.18), pen.w), 1),
        .number => {
            pen.fill(sdf.ring(sdf.Disc{ .c = c, .r = 0.8 * pen.k }, pen.w), 1);
            pen.line(0.04, -0.4, 0.04, 0.42);
            pen.line(-0.22, -0.2, 0.04, -0.4);
        },
        .callout => {
            const bubble = sdf.unite(pen.box(-0.8, -0.72, 0.8, 0.38, 0.28), pen.tri(.{ -0.42, 0.3 }, .{ 0.02, 0.3 }, .{ -0.5, 0.8 }));
            pen.fill(sdf.ring(bubble, pen.w), 1);
            pen.line(-0.42, -0.3, 0.42, -0.3);
            pen.line(-0.42, 0.0, 0.15, 0.0);
        },
        .pixelate => {
            const cell = 0.5;
            const gap = 0.08;
            for (0..3) |iy| for (0..3) |ix| {
                const x0 = -0.79 + @as(f32, @floatFromInt(ix)) * (cell + gap);
                const y0 = -0.79 + @as(f32, @floatFromInt(iy)) * (cell + gap);
                pen.fill(pen.box(x0, y0, x0 + cell, y0 + cell, 0.06), if ((ix + iy) % 2 == 0) 1 else 0.4);
            };
        },
        .move => {
            // Four-way arrow: a cross with a head on each end.
            pen.line(-0.55, 0, 0.55, 0);
            pen.line(0, -0.55, 0, 0.55);
            const e = 0.88;
            const b = 0.5;
            const h = 0.3;
            pen.fill(pen.tri(.{ 0, -e }, .{ -h, -b }, .{ h, -b }), 1);
            pen.fill(pen.tri(.{ 0, e }, .{ -h, b }, .{ h, b }), 1);
            pen.fill(pen.tri(.{ -e, 0 }, .{ -b, -h }, .{ -b, h }), 1);
            pen.fill(pen.tri(.{ e, 0 }, .{ b, -h }, .{ b, h }), 1);
        },
        .crop => {
            pen.line(-0.45, -0.85, -0.45, 0.45);
            pen.line(-0.45, 0.45, 0.85, 0.45);
            pen.line(-0.85, -0.45, 0.45, -0.45);
            pen.line(0.45, -0.45, 0.45, 0.85);
        },
    }
}

/// Undo (curved arrow to the left) or, with `redo`, its mirror.
pub fn drawUndo(cv: *Canvas, clip: Rect, redo: bool, c: Vec2, size: f32, color: Color) void {
    const pen = Pen{ .cv = cv, .clip = clip, .c = c, .k = size * 0.5, .color = color, .w = @max(1.5, size * 0.11), .sx = if (redo) -1 else 1 };
    // U-turn: the head points left at the top, the path runs right, turns
    // down a half circle and comes back left at the bottom.
    const o = pen.p(0.18, 0.12);
    const left_half = pen.box(-2, -2, 0.18, 2, 0);
    pen.fill(sdf.Subtract(sdf.Ring(sdf.Disc), sdf.RoundRect){ .a = sdf.ring(sdf.Disc{ .c = o, .r = 0.42 * pen.k }, pen.w), .b = left_half }, 1);
    pen.line(-0.35, -0.3, 0.18, -0.3);
    pen.line(0.18, 0.54, -0.45, 0.54);
    pen.fill(pen.tri(.{ -0.85, -0.3 }, .{ -0.32, -0.7 }, .{ -0.32, 0.1 }), 1);
}

test "every icon draws inside its box" {
    const gpa = std.testing.allocator;
    var cv = try Canvas.init(gpa, 40, 40);
    defer cv.deinit(gpa);
    inline for (std.meta.fields(Tool)) |f| {
        cv.fill(.{ .r = 0, .g = 0, .b = 0 });
        draw(&cv, cv.bounds(), @enumFromInt(f.value), .{ .x = 20, .y = 20 }, 24, .{ .r = 255, .g = 255, .b = 255 });
        var ink: usize = 0;
        for (cv.pixels, 0..) |px, i| if (px != 0xff000000) {
            ink += 1;
            const x = i % 40;
            const y = i / 40;
            try std.testing.expect(x >= 6 and x < 34 and y >= 6 and y < 34);
        };
        try std.testing.expect(ink > 20);
    }
    for ([_]bool{ false, true }) |redo| {
        cv.fill(.{ .r = 0, .g = 0, .b = 0 });
        drawUndo(&cv, cv.bounds(), redo, .{ .x = 20, .y = 20 }, 24, .{ .r = 255, .g = 255, .b = 255 });
        for (cv.pixels, 0..) |px, i| if (px != 0xff000000) {
            try std.testing.expect(i % 40 >= 6 and i % 40 < 34 and i / 40 >= 6 and i / 40 < 34);
        };
    }
}
