//! The layout grid of the screen: where the background grid lines run and
//! where the panels (dock, top bar, padding widget, folder button, browser)
//! sit on them. Lines are 1 px wide, `step` px apart, and one vertical and
//! one horizontal line cross the screen center, so a panel with an even
//! number of cells is centered on the screen. A panel edge is a line: the
//! 3 px panel border is centered on its middle pixel. Pure functions of the
//! screen size; compositor.zig paints the lines, the geometry files place
//! panels with `panel`, `atLeast` and `atMost`.
const std = @import("std");
const geom = @import("geom.zig");
const style = @import("style.zig");

const Bounds = geom.Bounds;

/// Distance between lines (px): 32 at 1080p, scaled with the UI.
pub fn step(h: u32) f32 {
    return @max(8, @round(32 * style.uiScale(h)));
}

/// Pixel column of the vertical line through the screen center.
pub fn centerX(w: u32) f32 {
    return @floatFromInt(w / 2);
}

/// Pixel row of the horizontal line through the screen center.
pub fn centerY(h: u32) f32 {
    return @floatFromInt(h / 2);
}

/// The first line at or after `v` (lines at `c + k * st`).
pub fn atLeast(c: f32, st: f32, v: f32) f32 {
    return c + st * @ceil((v - c) / st);
}

/// The last line at or before `v`.
pub fn atMost(c: f32, st: f32, v: f32) f32 {
    return c + st * @floor((v - c) / st);
}

/// `width` rounded up to whole cells, an even number of them (a panel that
/// is centered on a line has even width).
pub fn evenCells(width: f32, st: f32) f32 {
    return 2 * st * @ceil(width / (2 * st));
}

/// `width` rounded up to whole cells.
pub fn cells(width: f32, st: f32) f32 {
    return st * @ceil(width / st);
}

/// The outer bounds of a panel whose edges are the lines `x0`, `y0`, `x1`
/// and `y1` (pixel columns and rows): the 3 px border is centered on them.
pub fn panel(x0: f32, y0: f32, x1: f32, y1: f32) Bounds {
    return .{ .min = .{ .x = x0 - 1, .y = y0 - 1 }, .max = .{ .x = x1 + 2, .y = y1 + 2 } };
}

/// The border width of a panel (px).
pub const border: f32 = 3;

test "lines and panels" {
    try std.testing.expectEqual(@as(f32, 32), step(1080));
    try std.testing.expectEqual(@as(f32, 64), step(2160));
    try std.testing.expectEqual(@as(f32, 28), atLeast(540, 32, 14));
    try std.testing.expectEqual(@as(f32, 1052), atMost(540, 32, 1066));
    try std.testing.expectEqual(@as(f32, 192), evenCells(152, 32));
    const b = panel(10, 20, 74, 84);
    try std.testing.expectEqual(@as(f32, 9), b.min.x);
    try std.testing.expectEqual(@as(f32, 76), b.max.x);
}
