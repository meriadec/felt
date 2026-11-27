//! Export: render the document at full resolution. The output is the
//! canvas (extent.zig): the kept part of the image at 1:1 (with the border and shadow of the screen when the canvas is larger), `bg` (the canvas
//! background setting) where the annotations grew it, and every annotation shifted by the canvas origin
//! and cut to its clip. This is what Ctrl+S and Ctrl+C produce.
const std = @import("std");
const draw = @import("draw.zig");
const extent = @import("extent.zig");
const geom = @import("geom.zig");
const shadow = @import("shadow.zig");
const Canvas = @import("canvas.zig").Canvas;
const Color = @import("color.zig").Color;
const Document = @import("document.zig").Document;

pub fn render(ctx: draw.Ctx, doc: *const Document, bg: Color) !Canvas {
    const cr = extent.canvas(ctx, doc);
    var out = try Canvas.init(ctx.gpa, @intCast(cr.width()), @intCast(cr.height()));
    errdefer out.deinit(ctx.gpa);
    // The canvas background everywhere, then each placed image (cut by the
    // kept rectangle) over it. One image: only the bands outside it are
    // filled.
    const single = doc.scene.count() == 1;
    const kept = doc.kept();
    if (single) {
        const pic_out = kept.intersect(doc.base()).offset(-cr.x0, -cr.y0);
        for (out.bounds().minus(pic_out)) |b| out.fillRect(b, bg);
        // An extended canvas: the same border and shadow as on screen.
        if (!std.meta.eql(out.bounds(), pic_out)) {
            const theme: shadow.Theme = if (bg.luminance() > 0.5) .light else .dark;
            shadow.paint(&out, out.bounds(), pic_out, theme, shadow.unitFor(pic_out), .{ 0, 0 });
        }
    } else {
        out.fill(bg);
    }
    for (doc.scene.images.items) |p| {
        const image = p.canvas orelse continue;
        const pic = kept.intersect(p.rect());
        if (pic.isEmpty()) continue;
        out.blitRect(image, pic.offset(-p.x, -p.y), pic.x0 - cr.x0, pic.y0 - cr.y0);
    }
    const xf = geom.Xform{ .offset = .{ .x = -@as(f32, @floatFromInt(cr.x0)), .y = -@as(f32, @floatFromInt(cr.y0)) } };
    for (doc.items.items, 0..) |a, i| {
        const clip = extent.itemClip(ctx, doc, i).offset(-cr.x0, -cr.y0).intersect(out.bounds());
        try draw.annotation(ctx, &out, clip, a, xf, .{ .area = clip });
    }
    return out;
}

test "export size grows by the padding on every side and the margin is the background" {
    const gpa = std.testing.allocator;
    var font = try @import("font.zig").Font.init(gpa, @import("root.zig").font_ttf);
    defer font.deinit();
    var image = try Canvas.init(gpa, 50, 30);
    defer image.deinit(gpa);
    image.fillRect(image.bounds(), .{ .r = 255, .g = 0, .b = 0 });
    var doc = Document{};
    defer doc.deinit(gpa);
    try doc.seed(gpa, 50, 30, &image);
    const bg = Color{ .r = 1, .g = 2, .b = 3 };
    for (@import("settings.zig").padding_steps) |p| {
        var out = try render(.{ .gpa = gpa, .font = &font, .pad = p }, &doc, bg);
        defer out.deinit(gpa);
        try std.testing.expectEqual(@as(u32, 50 + 2 * p), out.width);
        try std.testing.expectEqual(@as(u32, 30 + 2 * p), out.height);
        if (p > 0) {
            try std.testing.expectEqual(bg.toPixel(), out.pixels[0]);
            const red = (Color{ .r = 255, .g = 0, .b = 0 }).toPixel();
            try std.testing.expectEqual(red, out.pixels[p * out.width + p]);
        }
    }
}
