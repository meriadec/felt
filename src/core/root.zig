//! The core module: everything that does not talk to a window system.
//! Backends (src/backend/) import this module; this module imports no backend.
pub const c = @import("c.zig").c;
pub const font_ttf = @embedFile("font_ttf");

test {
    @import("std").testing.refAllDecls(@This());
}
