//! Settings: user choices that are not part of the document and not undo
//! steps (they change how the canvas looks, not what was drawn). Today one:
//! the canvas background, the color of the canvas outside the image (on
//! screen and in the export).
const std = @import("std");
const color = @import("color.zig");

const Color = color.Color;

/// Color of the canvas where annotations grew it past the image.
pub const CanvasBg = enum {
    light,
    dark,

    /// Light: nord4, a clear light grey: a white (nord6) mark and the white
    /// of a screenshot both stand out on it. Dark: nord3, a mid-dark grey a
    /// step above the panels (nord1) and the screen background (nord0)
    /// around the canvas, so the canvas edge, the dock and the dark (nord0)
    /// marks all stay visible.
    pub fn color(bg: CanvasBg) Color {
        return switch (bg) {
            .light => color_light,
            .dark => color_dark,
        };
    }

    pub fn other(bg: CanvasBg) CanvasBg {
        return if (bg == .light) .dark else .light;
    }
};

pub const color_light = color.nord.n4;
pub const color_dark = color.nord.n3;

pub const Settings = struct {
    canvas_bg: CanvasBg = .light,
};

test "other switches" {
    try std.testing.expectEqual(CanvasBg.dark, CanvasBg.light.other());
    try std.testing.expectEqual(CanvasBg.light, CanvasBg.dark.other());
}
