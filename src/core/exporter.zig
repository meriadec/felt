//! Export: render the document on top of the original image at full
//! resolution (identity transform). This is what Ctrl+S and Ctrl+C produce.
const std = @import("std");
const draw = @import("draw.zig");
const Canvas = @import("canvas.zig").Canvas;
const Document = @import("document.zig").Document;

pub fn render(ctx: draw.Ctx, image: *const Canvas, doc: *const Document) !Canvas {
    var out = try image.clone(ctx.gpa);
    errdefer out.deinit(ctx.gpa);
    const all = out.bounds();
    for (doc.items.items) |a| try draw.annotation(ctx, &out, all, a, .identity, .{});
    return out;
}
