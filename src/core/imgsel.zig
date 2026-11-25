//! Selection outline of an image in a montage (move tool): a flat accent
//! frame just outside the image, 2 px at 1080p (scaled with the screen like
//! the other outlines, not with the zoom), drawn above the scene and never
//! exported. Pure: `frame` gives the screen rectangle, `paint` draws it.
const color = @import("color.zig");
const geom = @import("geom.zig");
const style = @import("style.zig");
const Canvas = @import("canvas.zig").Canvas;
const View = @import("view.zig").View;

const Rect = geom.Rect;

/// Accent of the selection: the same as the annotation outline.
pub const line = color.nord.n8;

/// Frame width in screen px.
pub fn width(screen_h: u32) i32 {
    return @max(2, @as(i32, @intFromFloat(@round(2 * style.uiScale(screen_h)))));
}

/// The screen rectangle the frame covers: the image rectangle plus the band.
pub fn frame(view: View, im: Rect) Rect {
    return view.rect(im).expand(width(view.screen_h));
}

/// Draw the frame of `outer` (from `frame`) in `clip`.
pub fn paint(cv: *Canvas, clip: Rect, outer: Rect, screen_h: u32) void {
    const w = width(screen_h);
    const inner = outer.expand(-w);
    for (outer.minus(inner)) |b| cv.fillRect(b.intersect(clip), line);
}
