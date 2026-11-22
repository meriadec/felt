//! Dock geometry: the floating tool bar at the bottom center. One slot per
//! tool (in key map order), the color swatches, the size slot and the help
//! button. Pure layout from the screen size, no font: chrome.zig draws it and
//! the editor hit-tests clicks with the same numbers.
const std = @import("std");
const geom = @import("geom.zig");
const keymap = @import("keymap.zig");
const color = @import("color.zig");
const style = @import("style.zig");

const Vec2 = geom.Vec2;
const Bounds = geom.Bounds;

pub const Hit = union(enum) {
    tool: keymap.Tool,
    color: u8,
    size,
    help,
};

const n_tools: comptime_int = keymap.tools.len;
const n_colors: comptime_int = color.palette.len;

// Metrics in px at UI scale 1.
const slot = 40.0;
const slot_gap = 4.0;
const pad = 8.0;
const sep_w = 17.0;
const swatch_pitch = 22.0;
const help_w = 34.0;
const margin = 14.0;

pub const Dock = struct {
    /// Px per 1080p px (the UI scale, shrunk if the screen is too narrow).
    s: f32,
    panel: Bounds,
    tools: [n_tools]Bounds,
    swatches: [n_colors]Vec2,
    swatch_r: f32,
    size: Bounds,
    help: Bounds,
    /// x of the two separator lines.
    seps: [2]f32,

    fn naturalWidth() f32 {
        return 2 * pad + n_tools * slot + (n_tools - 1) * slot_gap + sep_w + n_colors * swatch_pitch + sep_w + slot + slot_gap + help_w;
    }

    pub fn of(w: u32, h: u32) Dock {
        const W: f32 = @floatFromInt(w);
        const H: f32 = @floatFromInt(h);
        var s = style.uiScale(h);
        const need = (naturalWidth() + 2 * margin) * s;
        if (need > W) s *= W / need;

        var d: Dock = undefined;
        d.s = s;
        const pw = naturalWidth() * s;
        const ph = (slot + 2 * pad) * s;
        const x0 = @round((W - pw) / 2);
        const y0 = @round(H - margin * s - ph);
        d.panel = .{ .min = .{ .x = x0, .y = y0 }, .max = .{ .x = x0 + pw, .y = y0 + ph } };
        const top = y0 + pad * s;
        const cy = top + slot * s / 2;
        var x = x0 + pad * s;
        for (&d.tools) |*b| {
            b.* = .{ .min = .{ .x = x, .y = top }, .max = .{ .x = x + slot * s, .y = top + slot * s } };
            x += (slot + slot_gap) * s;
        }
        x -= slot_gap * s;
        d.seps[0] = x + sep_w * s / 2;
        x += sep_w * s;
        d.swatch_r = 7 * s;
        for (&d.swatches) |*c| {
            c.* = .{ .x = x + swatch_pitch * s / 2, .y = cy };
            x += swatch_pitch * s;
        }
        d.seps[1] = x + sep_w * s / 2;
        x += sep_w * s;
        d.size = .{ .min = .{ .x = x, .y = top }, .max = .{ .x = x + slot * s, .y = top + slot * s } };
        x += (slot + slot_gap) * s;
        d.help = .{ .min = .{ .x = x, .y = top + (slot - help_w) * s / 2 }, .max = .{ .x = x + help_w * s, .y = top + (slot + help_w) * s / 2 } };
        return d;
    }

    /// What a click at `p` hits, or null outside the dock.
    pub fn hit(d: *const Dock, p: Vec2) ?Hit {
        if (!inside(d.panel, p)) return null;
        for (d.tools, 0..) |b, i| if (inside(b, p)) return .{ .tool = keymap.tools[i].tool };
        for (d.swatches, 0..) |c, i| if (p.dist(c) <= swatch_pitch * d.s / 2) return .{ .color = @intCast(i) };
        if (inside(d.size, p)) return .size;
        if (inside(d.help, p)) return .help;
        return null;
    }

    /// True if `p` is on the dock panel (clicks there never draw).
    pub fn contains(d: *const Dock, p: Vec2) bool {
        return inside(d.panel, p);
    }
};

fn inside(b: Bounds, p: Vec2) bool {
    return p.x >= b.min.x and p.x < b.max.x and p.y >= b.min.y and p.y < b.max.y;
}

test "dock is centered at the bottom and hit-tests its slots" {
    const d = Dock.of(1920, 1080);
    try std.testing.expectEqual(@as(f32, 1), d.s);
    try std.testing.expectApproxEqAbs(1920 - d.panel.max.x, d.panel.min.x, 1);
    try std.testing.expect(d.panel.max.y < 1080);
    const t = d.tools[2];
    try std.testing.expectEqual(Hit{ .tool = keymap.tools[2].tool }, d.hit(t.min.add(t.max).scale(0.5)).?);
    try std.testing.expectEqual(Hit{ .color = 3 }, d.hit(d.swatches[3]).?);
    try std.testing.expectEqual(Hit.help, d.hit(d.help.min.add(d.help.max).scale(0.5)).?);
    try std.testing.expectEqual(@as(?Hit, null), d.hit(.{ .x = 10, .y = 10 }));
    // 4K: twice as big. Narrow screen: shrunk to fit.
    try std.testing.expectEqual(@as(f32, 2), Dock.of(3840, 2160).s);
    const narrow = Dock.of(300, 1080);
    try std.testing.expect(narrow.panel.min.x >= 0 and narrow.panel.max.x <= 300);
}
