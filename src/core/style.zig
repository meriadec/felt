//! Size levels. Values are screen pixels at the moment a shape is made; the
//! editor divides by the view scale so shapes keep their look in the export.
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

/// Pixelate block edge, screen pixels at creation.
pub const pixelate_block = 10;
