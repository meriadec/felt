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
const ArrowStyle = @import("annotation.zig").ArrowStyle;
const TextStyle = @import("annotation.zig").TextStyle;
const stairs = @import("stairs.zig");

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

fn straightArrow(pen: Pen) void {
    pen.line(-0.7, 0.7, 0.3, -0.3);
    pen.fill(pen.tri(.{ 0.8, -0.8 }, .{ 0.62, 0.02 }, .{ -0.02, -0.62 }), 1);
}

/// An arrow style: a straight arrow, or a stairs arrow (elbow with
/// round corners, the real stairs path).
pub fn drawArrowStyle(cv: *Canvas, clip: Rect, st: ArrowStyle, c: Vec2, size: f32, color: Color) void {
    switch (st) {
        .straight => straightArrow(Pen{ .cv = cv, .clip = clip, .c = c, .k = size * 0.5, .color = color, .w = @max(1.5, size * 0.11) }),
        .stairs => {
            const pen = Pen{ .cv = cv, .clip = clip, .c = c, .k = size * 0.5, .color = color, .w = @max(1.5, size * 0.11) };
            const head = 0.62 * pen.k;
            const rt = stairs.Route.of(pen.p(-0.9, 0.8), pen.p(0.95, -0.55));
            pen.fill(stairs.Path.init(rt, head * 0.5, head, 0.4 * pen.k, pen.w * 0.5), 1);
            pen.fill(pen.tri(.{ 0.95, -0.55 }, .{ 0.33, -0.95 }, .{ 0.33, -0.15 }), 1);
        },
    }
}

/// A text style: the letter T alone (plain), or a T cut out of a filled
/// rounded box (boxed).
pub fn drawTextStyle(cv: *Canvas, clip: Rect, st: TextStyle, c: Vec2, size: f32, color: Color) void {
    const pen = Pen{ .cv = cv, .clip = clip, .c = c, .k = size * 0.5, .color = color, .w = @max(1.5, size * 0.11) };
    switch (st) {
        .plain => draw(cv, clip, .text, c, size, color),
        .boxed => {
            const letter = sdf.unite(sdf.unite(
                sdf.Capsule{ .a = pen.p(-0.4, -0.3), .b = pen.p(0.4, -0.3), .r = pen.w * 0.5 },
                sdf.Capsule{ .a = pen.p(0, -0.3), .b = pen.p(0, 0.4), .r = pen.w * 0.5 },
            ), sdf.Capsule{ .a = pen.p(-0.2, 0.4), .b = pen.p(0.2, 0.4), .r = pen.w * 0.5 });
            pen.fill(sdf.Subtract(sdf.RoundRect, @TypeOf(letter)){ .a = pen.box(-0.85, -0.7, 0.85, 0.7, 0.25), .b = letter }, 1);
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

/// The canvas background switch: a circle with its left half filled
/// (light and dark side by side).
pub fn drawCanvasBg(cv: *Canvas, clip: Rect, c: Vec2, size: f32, color: Color) void {
    const pen = Pen{ .cv = cv, .clip = clip, .c = c, .k = size * 0.5, .color = color, .w = @max(1.5, size * 0.1) };
    const r = 0.78 * pen.k;
    pen.fill(sdf.ring(sdf.Disc{ .c = c, .r = r }, pen.w), 1);
    pen.fill(sdf.Subtract(sdf.Disc, sdf.RoundRect){ .a = .{ .c = c, .r = r }, .b = pen.box(0, -2, 2, 2, 0) }, 1);
}

/// A folder: a tab and a body, outlined (`filled`: solid, for the file list).
pub fn drawFolder(cv: *Canvas, clip: Rect, c: Vec2, size: f32, color: Color, filled: bool) void {
    const pen = Pen{ .cv = cv, .clip = clip, .c = c, .k = size * 0.5, .color = color, .w = @max(1.5, size * 0.11) };
    const body = pen.box(-0.8, -0.38, 0.8, 0.66, 0.14);
    const tab = pen.box(-0.8, -0.68, -0.1, -0.2, 0.12);
    const shape = sdf.unite(body, tab);
    if (filled) pen.fill(shape, 1) else pen.fill(sdf.ring(shape, pen.w), 1);
}

/// The up button: an arrow that points up.
pub fn drawUp(cv: *Canvas, clip: Rect, c: Vec2, size: f32, color: Color) void {
    const pen = Pen{ .cv = cv, .clip = clip, .c = c, .k = size * 0.5, .color = color, .w = @max(1.5, size * 0.12) };
    pen.line(0, 0.7, 0, -0.45);
    pen.line(0, -0.7, -0.55, -0.12);
    pen.line(0, -0.7, 0.55, -0.12);
}

test "folder and up icons draw inside their box" {
    const gpa = std.testing.allocator;
    var cv = try Canvas.init(gpa, 40, 40);
    defer cv.deinit(gpa);
    for ([_]u8{ 0, 1, 2 }) |kind| {
        cv.fill(.{ .r = 0, .g = 0, .b = 0 });
        const white = Color{ .r = 255, .g = 255, .b = 255 };
        switch (kind) {
            0 => drawFolder(&cv, cv.bounds(), .{ .x = 20, .y = 20 }, 24, white, false),
            1 => drawFolder(&cv, cv.bounds(), .{ .x = 20, .y = 20 }, 24, white, true),
            else => drawUp(&cv, cv.bounds(), .{ .x = 20, .y = 20 }, 24, white),
        }
        var ink: usize = 0;
        for (cv.pixels, 0..) |px, i| if (px != 0xff000000) {
            ink += 1;
            const x = i % 40;
            const y = i / 40;
            try std.testing.expect(x >= 6 and x < 34 and y >= 6 and y < 34);
        };
        try std.testing.expect(ink > 20);
    }
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
    for ([_]ArrowStyle{ .straight, .stairs }) |st| {
        cv.fill(.{ .r = 0, .g = 0, .b = 0 });
        drawArrowStyle(&cv, cv.bounds(), st, .{ .x = 20, .y = 20 }, 24, .{ .r = 255, .g = 255, .b = 255 });
        var ink: usize = 0;
        for (cv.pixels, 0..) |px, i| if (px != 0xff000000) {
            ink += 1;
            try std.testing.expect(i % 40 >= 6 and i % 40 < 34 and i / 40 >= 6 and i / 40 < 34);
        };
        try std.testing.expect(ink > 20);
    }
    for ([_]TextStyle{ .plain, .boxed }) |st| {
        cv.fill(.{ .r = 0, .g = 0, .b = 0 });
        drawTextStyle(&cv, cv.bounds(), st, .{ .x = 20, .y = 20 }, 24, .{ .r = 255, .g = 255, .b = 255 });
        var ink: usize = 0;
        for (cv.pixels, 0..) |px, i| if (px != 0xff000000) {
            ink += 1;
            try std.testing.expect(i % 40 >= 6 and i % 40 < 34 and i / 40 >= 6 and i / 40 < 34);
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
    cv.fill(.{ .r = 0, .g = 0, .b = 0 });
    drawCanvasBg(&cv, cv.bounds(), .{ .x = 20, .y = 20 }, 24, .{ .r = 255, .g = 255, .b = 255 });
    var ink: usize = 0;
    for (cv.pixels, 0..) |px, i| if (px != 0xff000000) {
        ink += 1;
        try std.testing.expect(i % 40 >= 6 and i % 40 < 34 and i / 40 >= 6 and i / 40 < 34);
    };
    try std.testing.expect(ink > 100);
    // The left half is filled, the middle of the right half is not.
    try std.testing.expectEqual(@as(u32, 0xffffffff), cv.at(15, 20));
    try std.testing.expectEqual(@as(u32, 0xff000000), cv.at(25, 20));
}
