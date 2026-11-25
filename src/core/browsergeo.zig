//! File browser geometry: the folder button at the top left (a small panel
//! like the top bar) and, below it, the browser panel, an overlay on the left
//! (it never shrinks the canvas): a header (the up button and the path) and a
//! list of rows, each with a thumbnail box and two text lines, with a slim
//! scrollbar. Pure layout from the screen size and the scroll offset:
//! browser_draw.zig draws it and the editor hit-tests with the same numbers.
const std = @import("std");
const geom = @import("geom.zig");
const style = @import("style.zig");

const Vec2 = geom.Vec2;
const Bounds = geom.Bounds;

// Metrics in px at UI scale 1.
const slot = 40.0;
const pad = 2.0;
const margin = 14.0;
const gap = 8.0;
const panel_w = 340.0;
const header_h = 44.0;
const row_h_1 = 64.0;
const thumb_w_1 = 96.0;
const thumb_h_1 = 56.0;
const inner = 6.0;

pub const Hit = union(enum) {
    /// The folder button (opens and closes the panel).
    folder,
    /// The up button of the header.
    up,
    /// A row of the list: `..` first (when there is a parent), then the entries.
    row: usize,
    /// On the panel, on nothing that does something.
    panel,

    pub fn eql(a: Hit, b: Hit) bool {
        return std.meta.eql(a, b);
    }
};

pub const Geo = struct {
    s: f32,
    /// The folder button panel.
    folder: Bounds,
    /// The browser panel (below the button).
    panel: Bounds,
    up: Bounds,
    /// The path text: its box.
    path: Bounds,
    /// The list area (rows are clipped to it).
    list: Bounds,
    row_h: f32,
    thumb_w: f32,
    thumb_h: f32,

    pub fn of(w: u32, h: u32) Geo {
        const W: f32 = @floatFromInt(w);
        const H: f32 = @floatFromInt(h);
        const s = style.uiScale(h);
        const fx = @round(margin * s);
        const fy = @round(margin * s);
        const fs = (slot + 2 * pad) * s;
        const px0 = fx;
        const py0 = fy + fs + @round(gap * s);
        const pw = @min(@round(panel_w * s), @round(W * 0.5));
        const py1 = @max(py0 + header_h * s, @round(H - margin * s));
        var g: Geo = undefined;
        g.s = s;
        g.folder = .{ .min = .{ .x = fx, .y = fy }, .max = .{ .x = fx + fs, .y = fy + fs } };
        g.panel = .{ .min = .{ .x = px0, .y = py0 }, .max = .{ .x = px0 + pw, .y = py1 } };
        const ub = 32 * s;
        const ux = px0 + inner * s;
        const uy = py0 + (header_h * s - ub) / 2;
        g.up = .{ .min = .{ .x = ux, .y = uy }, .max = .{ .x = ux + ub, .y = uy + ub } };
        g.path = .{ .min = .{ .x = ux + ub + 8 * s, .y = py0 }, .max = .{ .x = px0 + pw - inner * s, .y = py0 + header_h * s } };
        g.list = .{ .min = .{ .x = px0 + inner * s, .y = py0 + header_h * s }, .max = .{ .x = px0 + pw - inner * s, .y = py1 - inner * s } };
        g.row_h = row_h_1 * s;
        g.thumb_w = thumb_w_1 * s;
        g.thumb_h = thumb_h_1 * s;
        return g;
    }

    pub fn listHeight(g: Geo) f32 {
        return g.list.max.y - g.list.min.y;
    }

    /// Largest scroll offset for `n` rows.
    pub fn maxScroll(g: Geo, n: usize) f32 {
        return @max(0, @as(f32, @floatFromInt(n)) * g.row_h - g.listHeight());
    }

    /// Offset kept inside 0..maxScroll, whole pixels.
    pub fn clampScroll(g: Geo, scroll: f32, n: usize) f32 {
        return @round(std.math.clamp(scroll, 0, g.maxScroll(n)));
    }

    /// The row rectangle (full width of the list) at scroll offset `scroll`.
    pub fn row(g: Geo, i: usize, scroll: f32) Bounds {
        const y = g.list.min.y + @as(f32, @floatFromInt(i)) * g.row_h - scroll;
        return .{ .min = .{ .x = g.list.min.x, .y = y }, .max = .{ .x = g.list.max.x, .y = y + g.row_h } };
    }

    /// The rows that show at all: `first` up to but not including `end`.
    pub fn visible(g: Geo, scroll: f32, n: usize) [2]usize {
        const first: usize = @intFromFloat(@floor(scroll / g.row_h));
        const end: usize = @intFromFloat(@ceil((scroll + g.listHeight()) / g.row_h));
        return .{ @min(first, n), @min(end, n) };
    }

    /// The thumbnail box of a row.
    pub fn thumbBox(g: Geo, r: Bounds) Bounds {
        const x = r.min.x + 4 * g.s;
        const y = r.min.y + (g.row_h - g.thumb_h) / 2;
        return .{ .min = .{ .x = x, .y = y }, .max = .{ .x = x + g.thumb_w, .y = y + g.thumb_h } };
    }

    /// Left edge of the text of a row.
    pub fn textX(g: Geo, r: Bounds) f32 {
        return r.min.x + 4 * g.s + g.thumb_w + 10 * g.s;
    }

    /// Right edge of the text of a row (before the scrollbar).
    pub fn textRight(g: Geo) f32 {
        return g.list.max.x - 8 * g.s;
    }

    /// The scrollbar thumb, or null when everything fits.
    pub fn scrollbar(g: Geo, scroll: f32, n: usize) ?Bounds {
        const max = g.maxScroll(n);
        if (max <= 0) return null;
        const lh = g.listHeight();
        const total = @as(f32, @floatFromInt(n)) * g.row_h;
        const th = @max(24 * g.s, lh * lh / total);
        const y = g.list.min.y + (lh - th) * (scroll / max);
        const x1 = g.list.max.x - 2 * g.s;
        return .{ .min = .{ .x = x1 - 3 * g.s, .y = y }, .max = .{ .x = x1, .y = y + th } };
    }

    /// What is under `p`. `panel_open`: the panel exists. `n` rows.
    pub fn hit(g: Geo, p: Vec2, panel_open: bool, scroll: f32, n: usize) ?Hit {
        if (inside(g.folder, p)) return .folder;
        if (!panel_open or !inside(g.panel, p)) return null;
        if (inside(g.up, p)) return .up;
        if (inside(g.list, p)) {
            const k = (p.y - g.list.min.y + scroll) / g.row_h;
            if (k >= 0) {
                const i: usize = @intFromFloat(@floor(k));
                if (i < n) return .{ .row = i };
            }
        }
        return .panel;
    }
};

pub fn inside(b: Bounds, p: Vec2) bool {
    return p.x >= b.min.x and p.x < b.max.x and p.y >= b.min.y and p.y < b.max.y;
}

const testing = std.testing;

test "panel sits left, below the button, full height minus margins" {
    const g = Geo.of(1920, 1080);
    try testing.expectEqual(@as(f32, 14), g.folder.min.x);
    try testing.expectEqual(@as(f32, 14), g.folder.min.y);
    try testing.expect(g.panel.min.y > g.folder.max.y);
    try testing.expectEqual(@as(f32, 1080 - 14), g.panel.max.y);
    try testing.expectEqual(@as(f32, 340), g.panel.max.x - g.panel.min.x);
    const g4 = Geo.of(3840, 2160);
    try testing.expectEqual(@as(f32, 680), g4.panel.max.x - g4.panel.min.x);
    // A narrow screen: half of it at most.
    try testing.expectEqual(@as(f32, 200), Geo.of(400, 300).panel.max.x - Geo.of(400, 300).panel.min.x);
}

test "scroll clamps to the content; visible rows" {
    const g = Geo.of(1920, 1080);
    try testing.expectEqual(@as(f32, 0), g.clampScroll(500, 3)); // all fits
    const n: usize = 100;
    try testing.expectEqual(g.maxScroll(n), g.clampScroll(1e9, n));
    try testing.expectEqual(@as(f32, 0), g.clampScroll(-50, n));
    const v = g.visible(0, n);
    try testing.expectEqual(@as(usize, 0), v[0]);
    try testing.expect(v[1] > 10 and v[1] < 20);
    const v2 = g.visible(g.row_h * 5 + 3, n);
    try testing.expectEqual(@as(usize, 5), v2[0]);
    try testing.expectEqual(@as(usize, 3), g.visible(0, 3)[1]);
}

test "hit test: button, up, rows with scroll, panel, outside" {
    const g = Geo.of(1920, 1080);
    const c = struct {
        fn of(b: Bounds) Vec2 {
            return b.min.add(b.max).scale(0.5);
        }
    }.of;
    try testing.expect(g.hit(c(g.folder), false, 0, 10).?.eql(.folder));
    try testing.expectEqual(@as(?Hit, null), g.hit(c(g.up), false, 0, 10)); // closed
    try testing.expect(g.hit(c(g.up), true, 0, 10).?.eql(.up));
    try testing.expect(g.hit(c(g.row(2, 0)), true, 0, 10).?.eql(.{ .row = 2 }));
    try testing.expect(g.hit(c(g.row(7, 100)), true, 100, 10).?.eql(.{ .row = 7 }));
    try testing.expect(g.hit(c(g.row(12, 0)), true, 0, 10) == null or g.hit(c(g.row(12, 0)), true, 0, 10).?.eql(.panel));
    try testing.expect(g.hit(.{ .x = g.panel.min.x + 2, .y = g.panel.min.y + 2 }, true, 0, 10).?.eql(.panel));
    try testing.expectEqual(@as(?Hit, null), g.hit(.{ .x = 1000, .y = 500 }, true, 0, 10));
}

test "scrollbar thumb follows the offset" {
    const g = Geo.of(1920, 1080);
    try testing.expectEqual(@as(?Bounds, null), g.scrollbar(0, 3));
    const top = g.scrollbar(0, 100).?;
    const bot = g.scrollbar(g.maxScroll(100), 100).?;
    try testing.expectApproxEqAbs(g.list.min.y, top.min.y, 0.01);
    try testing.expectApproxEqAbs(g.list.max.y, bot.max.y, 0.01);
}
