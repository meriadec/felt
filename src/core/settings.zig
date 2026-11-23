//! Settings: user choices that are not part of the document and not undo
//! steps (they change how the canvas looks, not what was drawn). Today one:
//! the canvas background, the color of the canvas outside the image (on
//! screen and in the export). Also the config file text: `parse` reads it,
//! `write` prints it. Pure: the file IO lives in src/config.zig.
const std = @import("std");
const color = @import("color.zig");

const Color = color.Color;

/// Color of the canvas where annotations grew it past the image.
pub const CanvasBg = enum {
    light,
    dark,

    /// Light: nord4, a clear light grey: a white (nord6) mark and the white
    /// of a screenshot both stand out on it. Dark: nord3, a mid-dark grey a
    /// step above the panels (nord1) and the screen background (nord0)
    /// around the canvas, so the canvas edge, the dock and the dark (nord0)
    /// marks all stay visible.
    pub fn color(bg: CanvasBg) Color {
        return switch (bg) {
            .light => color_light,
            .dark => color_dark,
        };
    }

    pub fn other(bg: CanvasBg) CanvasBg {
        return if (bg == .light) .dark else .light;
    }
};

pub const color_light = color.Color.rgb(0xF5F7FA);
pub const color_dark = color.Color.rgb(0x2E3440);

/// Canvas padding steps (image px, every side): the one list the slider,
/// the keys and the config file use. The first is the default (no padding).
pub const padding_steps = [_]u16{ 0, 64, 96, 128, 192 };

/// Index of the step nearest to `px` (a value from a file or a flag).
pub fn paddingIndex(px: i64) usize {
    var best: usize = 0;
    for (padding_steps, 0..) |s, i| {
        if (@abs(@as(i64, s) - px) < @abs(@as(i64, padding_steps[best]) - px)) best = i;
    }
    return best;
}

/// The step `delta` steps from `px`'s step, clamped to the list.
pub fn stepPadding(px: u16, delta: i32) u16 {
    const i: i32 = @intCast(paddingIndex(px));
    return padding_steps[@intCast(std.math.clamp(i + delta, 0, padding_steps.len - 1))];
}

pub const Settings = struct {
    canvas_bg: CanvasBg = .light,
    /// Canvas padding in image px: one of `padding_steps`.
    padding: u16 = padding_steps[0],
};

/// The config file never gets this big: a bigger file is not ours.
pub const max_file = 4096;

/// Read config text: `key=value` lines, `#` comments, spaces around both
/// ignored. An unknown key, a bad value or a bad line is skipped: its
/// setting keeps the default (a broken file never stops the app).
pub fn parse(src: []const u8) Settings {
    var s = Settings{};
    if (src.len > max_file) return s;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "canvas_bg")) {
            if (std.meta.stringToEnum(CanvasBg, val)) |v| s.canvas_bg = v;
        }
    }
    return s;
}

/// Config text for `s`: every setting, so the file documents itself.
pub fn write(s: Settings, w: *std.Io.Writer) !void {
    try w.print(
        \\# felt settings (written by felt; `b` switches the canvas)
        \\# canvas_bg: light or dark, the canvas outside the image
        \\canvas_bg={s}
        \\
    , .{@tagName(s.canvas_bg)});
}

test "parse: good, defaults, bad lines" {
    try std.testing.expectEqual(CanvasBg.dark, parse("canvas_bg=dark\n").canvas_bg);
    try std.testing.expectEqual(CanvasBg.dark, parse("# c\n\n  canvas_bg = dark \r\nother=1\n").canvas_bg);
    try std.testing.expectEqual(CanvasBg.light, parse("").canvas_bg);
    try std.testing.expectEqual(CanvasBg.light, parse("canvas_bg=purple\n").canvas_bg);
    try std.testing.expectEqual(CanvasBg.light, parse("canvas_bg\n=dark\n\x00\xff\xfe garbage").canvas_bg);
    try std.testing.expectEqual(CanvasBg.light, parse("canvas_bg=DARK").canvas_bg);
    // The last good line wins.
    try std.testing.expectEqual(CanvasBg.light, parse("canvas_bg=dark\ncanvas_bg=light").canvas_bg);
    const big = [_]u8{' '} ** (max_file + 1);
    try std.testing.expectEqual(CanvasBg.light, parse(&big).canvas_bg);
}

test "padding steps: nearest, stepping, clamping" {
    try std.testing.expectEqual(@as(u16, 0), (Settings{}).padding);
    try std.testing.expectEqual(@as(u16, 96), stepPadding(64, 1));
    try std.testing.expectEqual(@as(u16, 64), stepPadding(96, -1));
    try std.testing.expectEqual(@as(u16, 0), stepPadding(0, -1));
    try std.testing.expectEqual(@as(u16, 192), stepPadding(192, 1));
    try std.testing.expectEqual(@as(u16, 128), stepPadding(100, 1)); // 100 reads as 96
    // The padding is not in the config file: every session starts at 0.
    try std.testing.expectEqual(@as(u16, 0), parse("padding=128\n").padding);
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(.{ .padding = 128 }, &w);
    try std.testing.expectEqual(@as(u16, 0), parse(w.buffered()).padding);
}

test "write then parse gives the same settings" {
    for ([_]CanvasBg{ .light, .dark }) |bg| {
        var buf: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try write(.{ .canvas_bg = bg }, &w);
        try std.testing.expectEqual(bg, parse(w.buffered()).canvas_bg);
    }
    try std.testing.expectEqual(CanvasBg.dark, CanvasBg.light.other());
}
