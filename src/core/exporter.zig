//! Export: render the document at full resolution. The output is the
//! canvas (extent.zig): the kept part of the image at 1:1, `bg` (the canvas
//! background setting) where the annotations grew it, and every annotation shifted by the canvas origin
//! and cut to its clip. This is what Ctrl+S and Ctrl+C produce.
const std = @import("std");
const draw = @import("draw.zig");
const extent = @import("extent.zig");
const geom = @import("geom.zig");
const Canvas = @import("canvas.zig").Canvas;
const Color = @import("color.zig").Color;
const Document = @import("document.zig").Document;

pub fn render(ctx: draw.Ctx, image: *const Canvas, doc: *const Document, bg: Color) !Canvas {
    const iw = image.width;
    const ih = image.height;
    const cr = extent.canvas(ctx, doc, iw, ih);
    var out = try Canvas.init(ctx.gpa, @intCast(cr.width()), @intCast(cr.height()));
    errdefer out.deinit(ctx.gpa);
    const pic = doc.kept(iw, ih).intersect(image.bounds());
    const pic_out = pic.offset(-cr.x0, -cr.y0);
    for (out.bounds().minus(pic_out)) |b| out.fillRect(b, bg);
    if (!pic.isEmpty()) out.blitRect(image, pic, pic_out.x0, pic_out.y0);
    const xf = geom.Xform{ .offset = .{ .x = -@as(f32, @floatFromInt(cr.x0)), .y = -@as(f32, @floatFromInt(cr.y0)) } };
    for (doc.items.items, 0..) |a, i| {
        const clip = extent.itemClip(ctx, doc, iw, ih, i).offset(-cr.x0, -cr.y0).intersect(out.bounds());
        try draw.annotation(ctx, &out, clip, a, xf, .{ .area = clip });
    }
    return out;
}
