//! Size levels and the UI scale. Size values are screen pixels at 1080p at
//! the moment a shape is made; the editor multiplies them by the UI scale and
//! divides by the view scale, so shapes keep their look in the export.
const std = @import("std");

/// UI scale for a screen height: 1 at 1080p and below, 2 at 2160p (4K).
/// Chrome and annotation sizes follow it, so a 4K screen looks like 1080p.
pub fn uiScale(screen_h: u32) f32 {
    return std.math.clamp(@as(f32, @floatFromInt(screen_h)) / 1080, 1, 4);
}

pub const Size = struct { stroke: f32, font: f32 };

pub const sizes = [_]Size{
    .{ .stroke = 2, .font = 14 },
    .{ .stroke = 3, .font = 18 },
    .{ .stroke = 5, .font = 22 },
    .{ .stroke = 7, .font = 28 },
    .{ .stroke = 10, .font = 36 },
    .{ .stroke = 14, .font = 46 },
    .{ .stroke = 20, .font = 60 },
};

pub const default_size = 2;

/// Pixelate block edge, screen pixels at 1080p at creation.
pub const pixelate_block = 10;

test "ui scale" {
    try std.testing.expectEqual(@as(f32, 1), uiScale(500));
    try std.testing.expectEqual(@as(f32, 1), uiScale(1080));
    try std.testing.expectEqual(@as(f32, 2), uiScale(2160));
}
