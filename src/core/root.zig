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
pub const png = @import("png.zig");
pub const resample = @import("resample.zig");
pub const view = @import("view.zig");
pub const font = @import("font.zig");
pub const text = @import("text.zig");
pub const style = @import("style.zig");
pub const annotation = @import("annotation.zig");
pub const document = @import("document.zig");
pub const input = @import("input.zig");
pub const keymap = @import("keymap.zig");
pub const draw = @import("draw.zig");
pub const extent = @import("extent.zig");
pub const editor = @import("editor.zig");
pub const icons = @import("icons.zig");
pub const dock = @import("dock.zig");
pub const topbar = @import("topbar.zig");
pub const chrome = @import("chrome.zig");
pub const compositor = @import("compositor.zig");
pub const exporter = @import("exporter.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
