//! File browser drawing, in the chrome style (flat Nord surfaces): the header
//! (the up button and the path, cut on the left when too long), the rows
//! (thumbnail or folder icon, the name cut with an ellipsis, a line with the
//! date and the image size), the hover, the scrollbar, and a line for the
//! loading and error states. Also the ghost thumbnail that follows a drag.
//! chrome.zig runs `draw` after the panel fill; geometry is browsergeo.zig.
const std = @import("std");
const geom = @import("geom.zig");
const sdf = @import("sdf.zig");
const raster = @import("raster.zig");
const text = @import("text.zig");
const icons = @import("icons.zig");
const dirlist = @import("dirlist.zig");
const color = @import("color.zig");
const Canvas = @import("canvas.zig").Canvas;
const Ctx = @import("draw.zig").Ctx;
const Browser = @import("browser.zig").Browser;
const browsergeo = @import("browsergeo.zig");
const Geo = browsergeo.Geo;

const Vec2 = geom.Vec2;
const Bounds = geom.Bounds;
const Rect = geom.Rect;
const Color = color.Color;
const nord = color.nord;

const ellipsis = "\u{2026}";

fn px(v: f32) u16 {
    return text.pxOf(v);
}

fn textW(ctx: Ctx, s: []const u8, size: u16) f32 {
    return text.measure(ctx.font, s, size).width;
}

fn drawText(ctx: Ctx, cv: *Canvas, clip: Rect, pos: Vec2, s: []const u8, size: u16, col: Color) !void {
    if (s.len == 0) return;
    var mask = try text.render(ctx.gpa, ctx.font, s, size, 0, 0, null);
    defer mask.deinit(ctx.gpa);
    cv.blendMask(mask.data, mask.w, mask.h, @intFromFloat(@round(pos.x)), @intFromFloat(@round(pos.y)), col, clip);
}

/// The longest start of `s` that fits `max_w`; with an ellipsis after it when cut.
/// Returns the byte length kept and whether it was cut.
pub fn fitStart(ctx: Ctx, s: []const u8, size: u16, max_w: f32) struct { n: usize, cut: bool } {
    if (textW(ctx, s, size) <= max_w) return .{ .n = s.len, .cut = false };
    const room = max_w - textW(ctx, ellipsis, size);
    var n = s.len;
    while (n > 0) {
        n -= 1;
        while (n > 0 and (s[n] & 0xc0) == 0x80) n -= 1; // on a character start
        if (textW(ctx, s[0..n], size) <= room) break;
    }
    return .{ .n = n, .cut = true };
}

/// The longest end of `s` that fits `max_w` (room kept for an ellipsis in
/// front when cut): the byte where it starts, and whether it was cut.
pub fn fitEnd(ctx: Ctx, s: []const u8, size: u16, max_w: f32) struct { from: usize, cut: bool } {
    if (textW(ctx, s, size) <= max_w) return .{ .from = 0, .cut = false };
    const room = max_w - textW(ctx, ellipsis, size);
    var i: usize = 0;
    while (i < s.len) {
        i += 1;
        while (i < s.len and (s[i] & 0xc0) == 0x80) i += 1;
        if (textW(ctx, s[i..], size) <= room) break;
    }
    return .{ .from = i, .cut = true };
}

fn rr(cv: *Canvas, clip: Rect, b: Bounds, radius: f32, col: Color) void {
    raster.fill(cv, clip, sdf.RoundRect{ .min = b.min, .max = b.max, .radius = radius }, .{ .solid = col }, .{});
}

fn ring(cv: *Canvas, clip: Rect, b: Bounds, radius: f32, w: f32, col: Color) void {
    raster.fill(cv, clip, sdf.ring(sdf.RoundRect{ .min = b.min, .max = b.max, .radius = radius }, w), .{ .solid = col }, .{});
}

fn center(b: Bounds) Vec2 {
    return b.min.add(b.max).scale(0.5);
}

/// Copy `src` with its top-left at (dx, dy), blended with `alpha` (0..255).
pub fn blitAlpha(cv: *Canvas, clip: Rect, src: *const Canvas, dx: i32, dy: i32, alpha: u8) void {
    const r = Rect.fromSize(dx, dy, @intCast(src.width), @intCast(src.height)).intersect(clip).intersect(cv.bounds());
    if (r.isEmpty()) return;
    var y = r.y0;
    while (y < r.y1) : (y += 1) {
        const sy: usize = @intCast(y - dy);
        const srow = src.pixels[sy * src.width ..][0..src.width];
        const drow = cv.row(y, r.x0, r.x1);
        for (drow, 0..) |*d, i| {
            const sp = srow[@as(usize, @intCast(r.x0 - dx)) + i];
            if (alpha == 255) {
                d.* = sp;
                continue;
            }
            const a: u32 = alpha;
            const ia = 255 - a;
            const rch = (((sp >> 16) & 0xff) * a + ((d.* >> 16) & 0xff) * ia + 127) / 255;
            const gch = (((sp >> 8) & 0xff) * a + ((d.* >> 8) & 0xff) * ia + 127) / 255;
            const bch = ((sp & 0xff) * a + (d.* & 0xff) * ia + 127) / 255;
            d.* = 0xff000000 | (rch << 16) | (gch << 8) | bch;
        }
    }
}

/// The ghost of a dragged image: its thumbnail (a plain box until it is
/// ready) centered on `at`, half see-through, a thin border.
pub fn ghostRect(g: Geo, b: *const Browser, row: usize, at: Vec2) Rect {
    const sz = ghostSize(g, b, row);
    const x: i32 = @intFromFloat(@round(at.x - sz[0] / 2));
    const y: i32 = @intFromFloat(@round(at.y - sz[1] / 2));
    return Rect.fromSize(x, y, @intFromFloat(sz[0]), @intFromFloat(sz[1]));
}

fn ghostSize(g: Geo, b: *const Browser, row: usize) [2]f32 {
    if (b.entryOf(row)) |e| if (b.thumbOf(e)) |s| if (s.thumb) |t| return .{ @floatFromInt(t.canvas.width), @floatFromInt(t.canvas.height) };
    return .{ g.thumb_w * 0.7, g.thumb_h };
}

pub fn drawGhost(cv: *Canvas, clip: Rect, b: *const Browser, row: usize, at: Vec2) void {
    const g = b.geo();
    const r = ghostRect(g, b, row, at);
    var drawn = false;
    if (b.entryOf(row)) |e| if (b.thumbOf(e)) |s| if (s.thumb) |*t| {
        blitAlpha(cv, clip, &t.canvas, r.x0, r.y0, 200);
        drawn = true;
    };
    if (!drawn) cv.blendRect(r.intersect(clip), nord.n8.withAlpha(150));
    ring(cv, clip, r.toBounds(), 0, 1.5 * g.s, nord.n8);
}

pub fn draw(ctx: Ctx, cv: *Canvas, clip: Rect, b: *const Browser) !void {
    const g = b.geo();
    const s = g.s;
    const panel_clip = clip.intersect(g.panel.toRect());
    if (panel_clip.isEmpty()) return;

    // ---- header
    const has_parent = b.hasParent();
    const up_hover = if (b.hover) |h| h.eql(.up) else false;
    if (has_parent and up_hover) rr(cv, panel_clip, g.up, 3 * s, nord.n2);
    icons.drawUp(cv, panel_clip, center(g.up), 18 * s, if (!has_parent) nord.n3 else if (up_hover) nord.n6 else nord.n4);
    {
        var tbuf: [std.fs.max_path_bytes]u8 = undefined;
        const shown = dirlist.tildePath(&tbuf, b.path, b.home);
        const size = px(13 * s);
        const max_w = g.path.max.x - g.path.min.x;
        const f = fitEnd(ctx, shown, size, max_w);
        const ty = g.path.min.y + (g.path.max.y - g.path.min.y) / 2 - @as(f32, @floatFromInt(size)) * 0.6;
        var x = g.path.min.x;
        if (f.cut) {
            try drawText(ctx, cv, panel_clip, .{ .x = x, .y = ty }, ellipsis, size, nord.n4);
            x += textW(ctx, ellipsis, size);
        }
        try drawText(ctx, cv, panel_clip, .{ .x = x, .y = ty }, shown[f.from..], size, nord.n6);
    }
    cv.blendRect(Rect.fromSize(@intFromFloat(g.panel.min.x + 6 * s), @intFromFloat(g.list.min.y - 1), @intFromFloat(g.panel.max.x - g.panel.min.x - 12 * s), 1).intersect(panel_clip), nord.n2);

    // ---- list
    const list_clip = clip.intersect(g.list.toRect());
    const n = b.rowCount();
    const name_px = px(13 * s);
    const sub_px = px(11 * s);
    const v = g.visible(b.scroll, n);
    var i = v[0];
    while (i < v[1]) : (i += 1) {
        const r = g.row(i, b.scroll);
        if (r.max.y <= g.list.min.y or r.min.y >= g.list.max.y) continue;
        const hovered = if (b.hover) |h| h.eql(.{ .row = i }) else false;
        if (hovered) rr(cv, list_clip, r, 3 * s, nord.n2);
        const box = g.thumbBox(r);
        const tx = g.textX(r);
        const max_w = g.textRight() - tx;
        const mid = r.min.y + g.row_h / 2;
        if (b.entryOf(i)) |e| {
            var date_buf: [16]u8 = undefined;
            const date = dirlist.formatDate(&date_buf, e.mtime, b.tz_off);
            if (e.is_dir) {
                icons.drawFolder(cv, list_clip, center(box), 30 * s, nord.n13, true);
            } else try drawThumb(cv, list_clip, b, e, box, s, ctx, name_px);
            const f = fitStart(ctx, e.name, name_px, max_w);
            const ny = mid - 15 * s;
            try drawText(ctx, cv, list_clip, .{ .x = tx, .y = ny }, e.name[0..f.n], name_px, nord.n6);
            if (f.cut) try drawText(ctx, cv, list_clip, .{ .x = tx + textW(ctx, e.name[0..f.n], name_px), .y = ny }, ellipsis, name_px, nord.n6);
            const sy = mid + 3 * s;
            try drawText(ctx, cv, list_clip, .{ .x = tx, .y = sy }, date, sub_px, nord.n9);
            if (b.thumbOf(e)) |sl| if (sl.thumb) |t| {
                var dims: [24]u8 = undefined;
                const d = std.fmt.bufPrint(&dims, "{d}x{d}", .{ t.w, t.h }) catch "";
                try drawText(ctx, cv, list_clip, .{ .x = tx + textW(ctx, date, sub_px) + 10 * s, .y = sy }, d, sub_px, nord.n9);
            };
        } else { // the `..` row
            icons.drawFolder(cv, list_clip, center(box), 30 * s, nord.n9, false);
            try drawText(ctx, cv, list_clip, .{ .x = tx, .y = mid - @as(f32, @floatFromInt(name_px)) * 0.6 }, "..", name_px, nord.n4);
        }
    }

    // ---- states
    if (b.status != .ready) {
        const msg: []const u8 = switch (b.status) {
            .loading, .empty => "Loading\u{2026}",
            .failed => b.err,
            .ready => "",
        };
        const y = g.list.min.y + @as(f32, @floatFromInt(@intFromBool(has_parent))) * g.row_h + 10 * s;
        if (b.status == .failed) {
            try drawText(ctx, cv, list_clip, .{ .x = g.list.min.x + 8 * s, .y = y }, "Cannot read this folder:", name_px, nord.n11);
            try drawText(ctx, cv, list_clip, .{ .x = g.list.min.x + 8 * s, .y = y + 20 * s }, msg, sub_px, nord.n4);
        } else try drawText(ctx, cv, list_clip, .{ .x = g.list.min.x + 8 * s, .y = y }, msg, name_px, nord.n4);
    } else if (n - @intFromBool(has_parent) == 0) {
        const y = g.list.min.y + @as(f32, @floatFromInt(@intFromBool(has_parent))) * g.row_h + 10 * s;
        try drawText(ctx, cv, list_clip, .{ .x = g.list.min.x + 8 * s, .y = y }, "No folders or images here", name_px, nord.n4);
    }

    // ---- scrollbar
    if (g.scrollbar(b.scroll, n)) |sb| rr(cv, list_clip, sb, 1.5 * s, nord.n3);
}

fn drawThumb(cv: *Canvas, clip: Rect, b: *const Browser, e: anytype, box: Bounds, s: f32, ctx: Ctx, size: u16) !void {
    if (b.thumbOf(e)) |sl| {
        if (sl.thumb) |*t| {
            const w: f32 = @floatFromInt(t.canvas.width);
            const h: f32 = @floatFromInt(t.canvas.height);
            const c = center(box);
            const x: i32 = @intFromFloat(@round(c.x - w / 2));
            const y: i32 = @intFromFloat(@round(c.y - h / 2));
            blitAlpha(cv, clip, &t.canvas, x, y, 255);
            ring(cv, clip, .{ .min = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) }, .max = .{ .x = @floatFromInt(x + @as(i32, @intCast(t.canvas.width))), .y = @floatFromInt(y + @as(i32, @intCast(t.canvas.height))) } }, 0, s, nord.n3);
            return;
        }
        // failed: a dim box with a question mark
        rr(cv, clip, box, 3 * s, nord.n0);
        const qs = "?";
        try drawText(ctx, cv, clip, .{ .x = center(box).x - textW(ctx, qs, size) / 2, .y = center(box).y - @as(f32, @floatFromInt(size)) * 0.6 }, qs, size, nord.n3);
        return;
    }
    rr(cv, clip, box, 3 * s, nord.n2); // not ready yet
}

test "long names and paths are cut with an ellipsis, short ones stay whole" {
    const gpa = std.testing.allocator;
    var font = try @import("font.zig").Font.init(gpa, @import("root.zig").font_ttf);
    defer font.deinit();
    const ctx = Ctx{ .gpa = gpa, .font = &font };
    const name = "a-very-long-screenshot-name-2025-03-14.png";
    const whole = textW(ctx, name, 13);
    const a = fitStart(ctx, name, 13, whole + 1);
    try std.testing.expect(!a.cut and a.n == name.len);
    const b = fitStart(ctx, name, 13, whole / 2);
    try std.testing.expect(b.cut and b.n > 3 and b.n < name.len);
    try std.testing.expect(textW(ctx, name[0..b.n], 13) + textW(ctx, ellipsis, 13) <= whole / 2);
    const c = fitEnd(ctx, name, 13, whole / 2);
    try std.testing.expect(c.cut and c.from > 3 and c.from < name.len);
    try std.testing.expect(textW(ctx, name[c.from..], 13) + textW(ctx, ellipsis, 13) <= whole / 2);
    try std.testing.expectEqualStrings(".png", name[c.from..][name[c.from..].len - 4 ..]); // the tail stays
    // Multi-byte names are cut on a character start.
    const u = "caf\u{e9}-\u{e9}t\u{e9}-photo.png";
    const d = fitStart(ctx, u, 13, textW(ctx, u, 13) / 2);
    try std.testing.expect(std.unicode.utf8ValidateSlice(u[0..d.n]));
}
