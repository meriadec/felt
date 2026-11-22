//! Colors. A `Pixel` is a packed 0xAARRGGBB u32 (native endian), the layout of
//! a 24/32-bit X11 TrueColor visual, so frames blit to X11 without conversion.
const std = @import("std");

pub const Pixel = u32;

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn rgb(hex: u24) Color {
        return .{ .r = @truncate(hex >> 16), .g = @truncate(hex >> 8), .b = @truncate(hex) };
    }

    pub fn withAlpha(c: Color, a: u8) Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
    }

    pub fn toPixel(c: Color) Pixel {
        return (@as(u32, c.a) << 24) | (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b;
    }

    pub fn fromPixel(p: Pixel) Color {
        return .{ .a = @truncate(p >> 24), .r = @truncate(p >> 16), .g = @truncate(p >> 8), .b = @truncate(p) };
    }

    /// Relative luminance in 0..1 (sRGB weights, no gamma: good enough to pick contrast).
    pub fn luminance(c: Color) f32 {
        return (0.2126 * @as(f32, @floatFromInt(c.r)) + 0.7152 * @as(f32, @floatFromInt(c.g)) + 0.0722 * @as(f32, @floatFromInt(c.b))) / 255.0;
    }

    /// Dark (nord0) or light (nord6), whichever reads best on top of `c`.
    pub fn contrast(c: Color) Color {
        return if (c.luminance() > 0.6) nord.n0 else nord.n6;
    }
};

pub const white = Color.rgb(0xffffff);
pub const black = Color.rgb(0x000000);

/// The Nord palette (nordtheme.com): the chrome uses it as is.
pub const nord = struct {
    // Polar Night
    pub const n0 = Color.rgb(0x2E3440);
    pub const n1 = Color.rgb(0x3B4252);
    pub const n2 = Color.rgb(0x434C5E);
    pub const n3 = Color.rgb(0x4C566A);
    // Snow Storm
    pub const n4 = Color.rgb(0xD8DEE9);
    pub const n5 = Color.rgb(0xE5E9F0);
    pub const n6 = Color.rgb(0xECEFF4);
    // Frost
    pub const n7 = Color.rgb(0x8FBCBB);
    pub const n8 = Color.rgb(0x88C0D0);
    pub const n9 = Color.rgb(0x81A1C1);
    pub const n10 = Color.rgb(0x5E81AC);
    // Aurora
    pub const n11 = Color.rgb(0xBF616A);
    pub const n12 = Color.rgb(0xD08770);
    pub const n13 = Color.rgb(0xEBCB8B);
    pub const n14 = Color.rgb(0xA3BE8C);
    pub const n15 = Color.rgb(0xB48EAD);
};

pub const Named = struct { name: []const u8, color: Color };

/// Annotation palette, selected with keys 1..8 (index 0 = key 1). Nord hues
/// (Aurora, Frost, Snow Storm, Polar Night), more saturated than Nord's
/// pastels so marks pop on bright screenshots.
pub const palette = [_]Named{
    .{ .name = "red", .color = Color.rgb(0xE04B5A) },
    .{ .name = "orange", .color = Color.rgb(0xEE8A4F) },
    .{ .name = "yellow", .color = Color.rgb(0xF5C85C) },
    .{ .name = "green", .color = Color.rgb(0x8FC46A) },
    .{ .name = "blue", .color = Color.rgb(0x4C9BD6) },
    .{ .name = "purple", .color = Color.rgb(0xB77BC0) },
    .{ .name = "white", .color = nord.n6 },
    .{ .name = "dark", .color = nord.n0 },
};

test "pixel round trip" {
    const c = Color{ .r = 1, .g = 2, .b = 3, .a = 4 };
    try std.testing.expectEqual(@as(u32, 0x04010203), c.toPixel());
    try std.testing.expectEqual(c, Color.fromPixel(c.toPixel()));
    try std.testing.expectEqual(nord.n6, palette[0].color.contrast());
    try std.testing.expectEqual(nord.n0, palette[2].color.contrast());
}
