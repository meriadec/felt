//! The core module: everything that does not talk to a window system.
//! Backends (src/backend/) import this module; this module imports no backend.
pub const c = @import("c.zig").c;
pub const font_ttf = @embedFile("font_ttf");
pub const color = @import("color.zig");
pub const geom = @import("geom.zig");
pub const canvas = @import("canvas.zig");
pub const shadow = @import("shadow.zig");
pub const sdf = @import("sdf.zig");
pub const stairs = @import("stairs.zig");
pub const raster = @import("raster.zig");
pub const image_io = @import("image_io.zig");
pub const png = @import("png.zig");
pub const resample = @import("resample.zig");
pub const view = @import("view.zig");
pub const font = @import("font.zig");
pub const ui_font = @import("ui_font.zig");
pub const text = @import("text.zig");
pub const style = @import("style.zig");
pub const settings = @import("settings.zig");
pub const annotation = @import("annotation.zig");
pub const scene = @import("scene.zig");
pub const magnet = @import("magnet.zig");
pub const dashed = @import("dashed.zig");
pub const dropzone = @import("dropzone.zig");
pub const imgsel = @import("imgsel.zig");
pub const dirlist = @import("dirlist.zig");
pub const thumbs = @import("thumbs.zig");
pub const loader = @import("loader.zig");
pub const browsergeo = @import("browsergeo.zig");
pub const browser = @import("browser.zig");
pub const browser_draw = @import("browser_draw.zig");
pub const document = @import("document.zig");
pub const input = @import("input.zig");
pub const keymap = @import("keymap.zig");
pub const draw = @import("draw.zig");
pub const extent = @import("extent.zig");
pub const route = @import("route.zig");
pub const editor = @import("editor.zig");
pub const icons = @import("icons.zig");
pub const grid = @import("grid.zig");
pub const dock = @import("dock.zig");
pub const topbar = @import("topbar.zig");
pub const padbar = @import("padbar.zig");
pub const chrome = @import("chrome.zig");
pub const compositor = @import("compositor.zig");
pub const exporter = @import("exporter.zig");
pub const picker = @import("picker.zig");
pub const picker_draw = @import("picker_draw.zig");
pub const ruler = @import("ruler.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
