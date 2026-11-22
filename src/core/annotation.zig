//! Annotation model. All coordinates and lengths are in image pixels, so the
//! export at full resolution renders exactly what the screen shows.
const std = @import("std");
const geom = @import("geom.zig");
const Color = @import("color.zig").Color;

const Vec2 = geom.Vec2;

pub const Arrow = struct { tail: Vec2, head: Vec2, width: f32, color: Color };

/// Rectangle outline.
pub const Box = struct { a: Vec2, b: Vec2, width: f32, color: Color };

/// Free text; `pos` is the top-left of the first line.
pub const Text = struct { pos: Vec2, text: []const u8, size: f32, color: Color };

/// Numbered bubble centered on `center`; `size` is the font size.
pub const Number = struct { center: Vec2, value: u32, size: f32, color: Color };

/// Text box attached at `anchor`, with a pointer to `target` (none = label).
pub const Callout = struct { target: ?Vec2, anchor: Vec2, text: []const u8, size: f32, color: Color };

/// Highlighter marker (multiply blend) over the rectangle a..b.
pub const Highlight = struct { a: Vec2, b: Vec2, color: Color };

/// Pixelated rectangle a..b with square blocks of `block` pixels.
pub const Pixelate = struct { a: Vec2, b: Vec2, block: f32 };

pub const Annotation = union(enum) {
    arrow: Arrow,
    rect: Box,
    text: Text,
    number: Number,
    callout: Callout,
    highlight: Highlight,
    pixelate: Pixelate,

    /// Text owned by the annotation, if any.
    pub fn ownedText(self: Annotation) ?[]const u8 {
        return switch (self) {
            .text => |t| t.text,
            .callout => |c| c.text,
            else => null,
        };
    }

    pub fn deinit(self: Annotation, gpa: std.mem.Allocator) void {
        if (self.ownedText()) |t| gpa.free(t);
    }
};
