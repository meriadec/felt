//! The core module: everything that does not talk to a window system.
//! Backends (src/backend/) import this module; this module imports no backend.
pub const c = @import("c.zig").c;
pub const font_ttf = @embedFile("font_ttf");
pub const color = @import("color.zig");
pub const geom = @import("geom.zig");
pub const canvas = @import("canvas.zig");
pub const sdf = @import("sdf.zig");
pub const raster = @import("raster.zig");
pub const image_io = @import("image_io.zig");
pub const resample = @import("resample.zig");
pub const view = @import("view.zig");
pub const font = @import("font.zig");
pub const text = @import("text.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
