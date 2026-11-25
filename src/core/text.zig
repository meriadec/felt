//! Text layout and coverage masks. A mask holds the text block (all lines)
//! with `pad` pixels of margin.
//! Lines are separated by '\n'. Sizes are whole pixels (see font.zig).
const std = @import("std");
const font_mod = @import("font.zig");
const Font = font_mod.Font;

pub const Layout = struct {
    width: f32,
    height: f32,
    line_h: f32,
    ascent: f32,
    lines: u32,
    last_line_w: f32,
};

pub fn pxOf(size: f32) u16 {
    return @intFromFloat(std.math.clamp(@round(size), 4, 1000));
}

fn lineWidth(font: *Font, line: []const u8, px: u16) f32 {
    var w: f32 = 0;
    var prev: ?u21 = null;
    var it = (std.unicode.Utf8View.init(line) catch return 0).iterator();
    while (it.nextCodepoint()) |cp| {
        if (prev) |p| w += font.kern(p, cp, px);
        w += font.advance(cp, px);
        prev = cp;
    }
    return w;
}

pub fn measure(font: *Font, text: []const u8, px: u16) Layout {
    var lay = Layout{ .width = 0, .height = 0, .line_h = font.lineHeight(px), .ascent = font.ascentPx(px), .lines = 0, .last_line_w = 0 };
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const w = lineWidth(font, line, px);
        lay.width = @max(lay.width, w);
        lay.last_line_w = w;
        lay.lines += 1;
    }
    lay.height = lay.line_h * @as(f32, @floatFromInt(lay.lines));
    return lay;
}

/// A selected stretch of one line: [x0, x1) from the block's left edge.
pub const Span = struct { line: u32, x0: f32, x1: f32 };

/// Where byte `at` of `text` sits: its line and its x from the block's left edge.
pub fn caretAt(font: *Font, text: []const u8, px: u16, at: usize) struct { line: u32, x: f32 } {
    const a = @min(at, text.len);
    const line: u32 = @intCast(std.mem.count(u8, text[0..a], "\n"));
    const ls = if (std.mem.lastIndexOfScalar(u8, text[0..a], '\n')) |i| i + 1 else 0;
    return .{ .line = line, .x = lineWidth(font, text[ls..a], px) };
}

/// The stretches of each line covered by the selection bytes [a, b): a
/// selected line break shows as one space more. At most `out.len` spans.
pub fn selectionSpans(font: *Font, text: []const u8, px: u16, a: usize, b: usize, out: []Span) []Span {
    var n: usize = 0;
    var ls: usize = 0;
    var line: u32 = 0;
    while (ls <= text.len and n < out.len) : (line += 1) {
        const le = std.mem.indexOfScalarPos(u8, text, ls, '\n') orelse text.len;
        const lo = @max(a, ls);
        const hi = @min(b, le);
        const breaks = b > le and a <= le and le < text.len; // the line break is selected
        if (lo < hi or breaks) {
            const x0 = lineWidth(font, text[ls..@min(lo, le)], px);
            const x1 = lineWidth(font, text[ls..@max(hi, @min(lo, le))], px) + if (breaks) font.advance(' ', px) else 0;
            out[n] = .{ .line = line, .x0 = x0, .x1 = x1 };
            n += 1;
        }
        if (le >= text.len) break;
        ls = le + 1;
    }
    return out[0..n];
}

pub const Mask = struct {
    w: u32,
    h: u32,
    data: []u8,
    pad: u32,
    layout: Layout,

    pub fn deinit(self: *Mask, gpa: std.mem.Allocator) void {
        gpa.free(self.data);
    }

    /// Rows/cols that hold ink: [x0, x1) x [y0, y1) in mask pixels.
    pub fn inkBounds(self: *const Mask) [4]u32 {
        var x0: u32 = self.w;
        var y0: u32 = self.h;
        var x1: u32 = 0;
        var y1: u32 = 0;
        for (0..self.h) |y| for (0..self.w) |x| {
            if (self.data[y * self.w + x] > 32) {
                x0 = @min(x0, @as(u32, @intCast(x)));
                x1 = @max(x1, @as(u32, @intCast(x + 1)));
                y0 = @min(y0, @as(u32, @intCast(y)));
                y1 = @max(y1, @as(u32, @intCast(y + 1)));
            }
        };
        return .{ x0, y0, x1, y1 };
    }
};

/// Render `text` at `px` into a new mask. The text block top-left is at
/// (pad + frac_x, pad) in mask pixels, frac_x in [0, 1) for subpixel placement.
/// With `caret` (a byte offset), a bar is drawn there.
pub fn render(gpa: std.mem.Allocator, font: *Font, text: []const u8, px: u16, pad: u32, frac_x: f32, caret: ?usize) !Mask {
    const lay = measure(font, text, px);
    const caret_w: f32 = if (caret != null) @max(2, @as(f32, @floatFromInt(px)) * 0.08) + 2 else 0;
    const w: u32 = @as(u32, @intFromFloat(@ceil(lay.width + caret_w + frac_x))) + 2 * pad + 2;
    const h: u32 = @as(u32, @intFromFloat(@ceil(lay.height))) + 2 * pad;
    const data = try gpa.alloc(u8, @as(usize, w) * h);
    @memset(data, 0);
    var mask = Mask{ .w = w, .h = h, .data = data, .pad = pad, .layout = lay };
    errdefer mask.deinit(gpa);

    const padf: f32 = @floatFromInt(pad);
    var line_no: u32 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| : (line_no += 1) {
        const baseline: i32 = @intFromFloat(@round(padf + lay.ascent + lay.line_h * @as(f32, @floatFromInt(line_no))));
        var pen: f32 = padf + frac_x;
        var prev: ?u21 = null;
        var cps = (std.unicode.Utf8View.init(line) catch continue).iterator();
        while (cps.nextCodepoint()) |cp| {
            if (prev) |p| pen += font.kern(p, cp, px);
            const ipen = @floor(pen);
            const sub: u2 = @intFromFloat(@floor((pen - ipen) * font_mod.subpixel_steps));
            const g = try font.glyph(cp, px, sub);
            blitMax(&mask, g, @as(i32, @intFromFloat(ipen)) + g.xoff, baseline + g.yoff);
            pen += font.advance(cp, px);
            prev = cp;
        }
    }
    if (caret) |at| {
        const cp = caretAt(font, text, px, at);
        const cw: u32 = @intFromFloat(@max(2, @as(f32, @floatFromInt(px)) * 0.08));
        const cx: u32 = @min(w - 1, @as(u32, @intFromFloat(@round(padf + frac_x + cp.x + 1))));
        const top: u32 = @intFromFloat(@round(padf + lay.line_h * @as(f32, @floatFromInt(cp.line))));
        const bot: u32 = @min(h, top + @as(u32, @intFromFloat(@round(lay.line_h))));
        for (top..bot) |y| @memset(data[y * w + cx ..][0..@min(cw, w - cx)], 255);
    }
    return mask;
}

fn blitMax(mask: *Mask, g: font_mod.Glyph, x: i32, y: i32) void {
    for (0..g.h) |gy| {
        const my = y + @as(i32, @intCast(gy));
        if (my < 0 or my >= mask.h) continue;
        for (0..g.w) |gx| {
            const mx = x + @as(i32, @intCast(gx));
            if (mx < 0 or mx >= mask.w) continue;
            const d = &mask.data[@as(usize, @intCast(my)) * mask.w + @as(usize, @intCast(mx))];
            d.* = @max(d.*, g.bitmap[gy * g.w + gx]);
        }
    }
}

test "render" {
    const gpa = std.testing.allocator;
    var f = try Font.init(gpa, @embedFile("font_ttf"));
    defer f.deinit();
    var m = try render(gpa, &f, "Hi\nthere", 20, 3, 0, 4);
    defer m.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), m.layout.lines);
    var sum: u64 = 0;
    for (m.data) |a| sum += a;
    try std.testing.expect(sum > 0);
}
