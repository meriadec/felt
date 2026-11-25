//! Dashed rectangle outline: dashes and gaps run along each side, starting
//! at a corner. The outline lies inside the rectangle. Alpha blends.
const geom = @import("geom.zig");
const color = @import("color.zig");
const Canvas = @import("canvas.zig").Canvas;

const Rect = geom.Rect;

pub const Style = struct {
    /// Line width, dash length and gap length (px).
    w: i32,
    dash: i32,
    gap: i32,
    color: color.Color,
};

/// Draw the outline of `r`, only in `clip`.
pub fn rect(cv: *Canvas, clip: Rect, r: Rect, st: Style) void {
    if (r.isEmpty() or !r.intersects(clip)) return;
    const w = @max(st.w, 1);
    const step = @max(st.dash + st.gap, 1);
    const dash = @max(st.dash, 1);
    // Top and bottom: the full width.
    var x = r.x0;
    while (x < r.x1) : (x += step) {
        const x1 = @min(x + dash, r.x1);
        cv.blendRect((Rect{ .x0 = x, .y0 = r.y0, .x1 = x1, .y1 = r.y0 + w }).intersect(clip), st.color);
        cv.blendRect((Rect{ .x0 = x, .y0 = r.y1 - w, .x1 = x1, .y1 = r.y1 }).intersect(clip), st.color);
    }
    // Left and right: between them.
    var y = r.y0 + w;
    while (y < r.y1 - w) : (y += step) {
        const y1 = @min(y + dash, r.y1 - w);
        cv.blendRect((Rect{ .x0 = r.x0, .y0 = y, .x1 = r.x0 + w, .y1 = y1 }).intersect(clip), st.color);
        cv.blendRect((Rect{ .x0 = r.x1 - w, .y0 = y, .x1 = r.x1, .y1 = y1 }).intersect(clip), st.color);
    }
}

test "dashes leave gaps and stay in the clip" {
    const std = @import("std");
    var cv = try Canvas.init(std.testing.allocator, 40, 20);
    defer cv.deinit(std.testing.allocator);
    cv.fillRect(cv.bounds(), color.Color.rgb(0));
    const white = color.Color.rgb(0xFFFFFF);
    rect(&cv, cv.bounds(), Rect.fromSize(0, 0, 40, 20), .{ .w = 1, .dash = 4, .gap = 4, .color = white });
    const black = cv.at(20, 10);
    try std.testing.expect(cv.at(1, 0) != black); // dash
    try std.testing.expect(cv.at(5, 0) == black); // gap
    try std.testing.expect(cv.at(0, 2) != black); // left side
    cv.fillRect(cv.bounds(), color.Color.rgb(0));
    rect(&cv, Rect.fromSize(0, 0, 40, 1), Rect.fromSize(0, 0, 40, 20), .{ .w = 1, .dash = 4, .gap = 4, .color = white });
    try std.testing.expect(cv.at(0, 19) == black); // clipped
}
