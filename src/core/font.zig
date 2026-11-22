//! Font: stb_truetype wrapper with a glyph bitmap cache keyed by
//! (codepoint, pixel size, 1/4 pixel x offset). Sizes are whole pixels.
const std = @import("std");
const c = @import("c.zig").c;

pub const Glyph = struct {
    w: u16,
    h: u16,
    /// Bitmap top-left relative to the pen position on the baseline.
    xoff: i16,
    yoff: i16,
    bitmap: []const u8,
};

pub const subpixel_steps = 4;

pub const Font = struct {
    gpa: std.mem.Allocator,
    info: c.stbtt_fontinfo,
    ascent: f32,
    descent: f32,
    line_gap: f32,
    bitmaps: std.heap.ArenaAllocator,
    glyphs: std.AutoHashMapUnmanaged(u64, Glyph) = .empty,

    /// `ttf` must outlive the font.
    pub fn init(gpa: std.mem.Allocator, ttf: []const u8) !Font {
        var info: c.stbtt_fontinfo = undefined;
        if (c.stbtt_InitFont(&info, ttf.ptr, c.stbtt_GetFontOffsetForIndex(ttf.ptr, 0)) == 0) return error.BadFont;
        var a: c_int = 0;
        var d: c_int = 0;
        var g: c_int = 0;
        c.stbtt_GetFontVMetrics(&info, &a, &d, &g);
        return .{
            .gpa = gpa,
            .info = info,
            .ascent = @floatFromInt(a),
            .descent = @floatFromInt(d),
            .line_gap = @floatFromInt(g),
            .bitmaps = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *Font) void {
        self.glyphs.deinit(self.gpa);
        self.bitmaps.deinit();
    }

    /// Font units to pixels for a size where ascent - descent = px.
    pub fn scale(self: *const Font, px: u16) f32 {
        return c.stbtt_ScaleForPixelHeight(&self.info, @floatFromInt(px));
    }

    pub fn ascentPx(self: *const Font, px: u16) f32 {
        return self.ascent * self.scale(px);
    }

    pub fn lineHeight(self: *const Font, px: u16) f32 {
        return (self.ascent - self.descent + self.line_gap) * self.scale(px);
    }

    pub fn advance(self: *const Font, cp: u21, px: u16) f32 {
        var adv: c_int = 0;
        var lsb: c_int = 0;
        c.stbtt_GetCodepointHMetrics(&self.info, cp, &adv, &lsb);
        return @as(f32, @floatFromInt(adv)) * self.scale(px);
    }

    pub fn kern(self: *const Font, a: u21, b: u21, px: u16) f32 {
        return @as(f32, @floatFromInt(c.stbtt_GetCodepointKernAdvance(&self.info, a, b))) * self.scale(px);
    }

    /// Cached glyph bitmap for `cp` at `px`, shifted right by sub/4 pixel.
    pub fn glyph(self: *Font, cp: u21, px: u16, sub: u2) !Glyph {
        const key = (@as(u64, cp) << 24) | (@as(u64, px) << 8) | sub;
        const gop = try self.glyphs.getOrPut(self.gpa, key);
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer _ = self.glyphs.remove(key);

        const s = self.scale(px);
        const shift = @as(f32, @floatFromInt(sub)) / subpixel_steps;
        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        c.stbtt_GetCodepointBitmapBoxSubpixel(&self.info, cp, s, s, shift, 0, &x0, &y0, &x1, &y1);
        const w: usize = @intCast(@max(0, x1 - x0));
        const h: usize = @intCast(@max(0, y1 - y0));
        const bmp = try self.bitmaps.allocator().alloc(u8, w * h);
        if (w > 0 and h > 0) {
            c.stbtt_MakeCodepointBitmapSubpixel(&self.info, bmp.ptr, @intCast(w), @intCast(h), @intCast(w), s, s, shift, 0, cp);
        }
        gop.value_ptr.* = .{ .w = @intCast(w), .h = @intCast(h), .xoff = @intCast(x0), .yoff = @intCast(y0), .bitmap = bmp };
        return gop.value_ptr.*;
    }
};

test "glyph cache" {
    var f = try Font.init(std.testing.allocator, @embedFile("font_ttf"));
    defer f.deinit();
    const g = try f.glyph('A', 20, 0);
    try std.testing.expect(g.w > 5 and g.h > 5);
    const g2 = try f.glyph('A', 20, 0);
    try std.testing.expectEqual(g.bitmap.ptr, g2.bitmap.ptr);
    try std.testing.expect(f.lineHeight(20) >= 20);
}
