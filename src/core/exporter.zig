//! Export: render the document on top of the original image at full
//! resolution. The output is the kept part of the image (the crop); the
//! annotations shift by the crop origin and are clipped at its edges.
//! This is what Ctrl+S and Ctrl+C produce.
const std = @import("std");
const draw = @import("draw.zig");
const Canvas = @import("canvas.zig").Canvas;
const Document = @import("document.zig").Document;

pub fn render(ctx: draw.Ctx, image: *const Canvas, doc: *const Document) !Canvas {
    const keep = doc.visible(image.width, image.height);
    var out = try image.copyOut(ctx.gpa, keep);
    errdefer out.deinit(ctx.gpa);
    const all = out.bounds();
    const xf = @import("geom.zig").Xform{ .offset = .{ .x = -@as(f32, @floatFromInt(keep.x0)), .y = -@as(f32, @floatFromInt(keep.y0)) } };
    for (doc.items.items) |a| try draw.annotation(ctx, &out, all, a, xf, .{});
    return out;
}
