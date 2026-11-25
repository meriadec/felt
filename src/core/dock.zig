//! Dock geometry: the floating tool bar at the bottom center. One slot per
//! tool (in key map order), the color swatches, the size slot and the help
//! button. With the callout tool active, a small switch floats above the
//! dock, over that tool's slot: one slot per pointer style (straight first,
//! then stairs). The text tool has one too: plain, boxed. Pure
//! layout from the screen size and the tool, no font: chrome.zig draws it
//! and the editor hit-tests clicks with the same numbers.
const std = @import("std");
const geom = @import("geom.zig");
const keymap = @import("keymap.zig");
const color = @import("color.zig");
const style = @import("style.zig");
const ArrowStyle = @import("annotation.zig").ArrowStyle;
const TextStyle = @import("annotation.zig").TextStyle;

const Vec2 = geom.Vec2;
const Bounds = geom.Bounds;

pub const Hit = union(enum) {
    tool: keymap.Tool,
    color: u8,
    size,
    help,
    arrow_style: ArrowStyle,
    text_style: TextStyle,
};

/// The styles in the switch, left to right.
pub const arrow_styles = [_]ArrowStyle{ .straight, .stairs };
/// The styles in the switch with the text tool, left to right.
pub const text_styles = [_]TextStyle{ .plain, .boxed };

const n_tools: comptime_int = keymap.tools.len;
const n_colors: comptime_int = color.palette.len;

// Metrics in px at UI scale 1.
const slot = 40.0;
const slot_gap = 2.0;
const pad = 2.0;
/// The space between the tools, the colors and the size (no divider lines).
const sep_w = 26.0;
const swatch_pitch = 22.0;
const help_w = 34.0;
const margin = 14.0;
// Arrow style switch.
const sw_slot = 32.0;
const sw_pad = 2.0;
const sw_gap = 6.0;

pub const Dock = struct {
    /// Px per 1080p px (the UI scale, shrunk if the screen is too narrow).
    s: f32,
    panel: Bounds,
    tools: [n_tools]Bounds,
    swatches: [n_colors]Vec2,
    swatch_r: f32,
    size: Bounds,
    help: Bounds,
    /// The tool the dock was laid out for (picks what the switch means).
    tool: keymap.Tool,
    /// The arrow style switch panel (null: no tool with a style is active).
    switch_panel: ?Bounds,
    styles: [arrow_styles.len]Bounds,

    fn naturalWidth() f32 {
        return 2 * pad + n_tools * slot + (n_tools - 1) * slot_gap + sep_w + n_colors * swatch_pitch + sep_w + slot + slot_gap + help_w;
    }

    /// The dock on a w x h screen while `tool` is active.
    pub fn of(w: u32, h: u32, tool: keymap.Tool) Dock {
        const W: f32 = @floatFromInt(w);
        const H: f32 = @floatFromInt(h);
        var s = style.uiScale(h);
        const need = (naturalWidth() + 2 * margin) * s;
        if (need > W) s *= W / need;

        var d: Dock = undefined;
        d.s = s;
        d.tool = tool;
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
        x += sep_w * s;
        d.swatch_r = 7 * s;
        for (&d.swatches) |*c| {
            c.* = .{ .x = x + swatch_pitch * s / 2, .y = cy };
            x += swatch_pitch * s;
        }
        x += sep_w * s;
        d.size = .{ .min = .{ .x = x, .y = top }, .max = .{ .x = x + slot * s, .y = top + slot * s } };
        x += (slot + slot_gap) * s;
        d.help = .{ .min = .{ .x = x, .y = top + (slot - help_w) * s / 2 }, .max = .{ .x = x + help_w * s, .y = top + (slot + help_w) * s / 2 } };

        // Over the active tool's slot, centered, but not left of the dock.
        const sw_n: f32 = arrow_styles.len;
        const sw_w = (2 * sw_pad + sw_n * sw_slot + (sw_n - 1) * slot_gap) * s;
        const ts = d.tools[toolIndex(tool)];
        const sx0 = @max(x0, @round((ts.min.x + ts.max.x - sw_w) / 2));
        const sy1 = y0 - sw_gap * s;
        const sy0 = sy1 - (sw_slot + 2 * sw_pad) * s;
        d.switch_panel = if (hasStyleSwitch(tool)) .{ .min = .{ .x = sx0, .y = sy0 }, .max = .{ .x = sx0 + sw_w, .y = sy1 } } else null;
        var sx = sx0 + sw_pad * s;
        for (&d.styles) |*b| {
            b.* = .{ .min = .{ .x = sx, .y = sy0 + sw_pad * s }, .max = .{ .x = sx + sw_slot * s, .y = sy1 - sw_pad * s } };
            sx += (sw_slot + slot_gap) * s;
        }
        return d;
    }

    /// What a click at `p` hits, or null outside the dock.
    pub fn hit(d: *const Dock, p: Vec2) ?Hit {
        if (d.switch_panel) |sp| if (inside(sp, p)) {
            if (d.tool == .text) {
                for (d.styles, text_styles) |b, st| if (inside(b, p)) return .{ .text_style = st };
            } else for (d.styles, arrow_styles) |b, st| if (inside(b, p)) return .{ .arrow_style = st };
            return null;
        };
        if (!inside(d.panel, p)) return null;
        for (d.tools, 0..) |b, i| if (inside(b, p)) return .{ .tool = keymap.tools[i].tool };
        for (d.swatches, 0..) |c, i| if (p.dist(c) <= swatch_pitch * d.s / 2) return .{ .color = @intCast(i) };
        if (inside(d.size, p)) return .size;
        if (inside(d.help, p)) return .help;
        return null;
    }

    /// True if `p` is on the dock panel or the style switch (clicks there never draw).
    pub fn contains(d: *const Dock, p: Vec2) bool {
        if (d.switch_panel) |sp| if (inside(sp, p)) return true;
        return inside(d.panel, p);
    }
};

/// The tool has a style: the switch shows above the dock (pointer styles, or
/// the text styles with the text tool).
pub fn hasStyleSwitch(tool: keymap.Tool) bool {
    return tool == .callout or tool == .text;
}

/// The slot of `tool` in `Dock.tools` (the order of `keymap.tools`): tests look slots up by tool, not by number.
pub fn toolIndex(tool: keymap.Tool) usize {
    for (keymap.tools, 0..) |t, i| if (t.tool == tool) return i;
    unreachable;
}

fn inside(b: Bounds, p: Vec2) bool {
    return p.x >= b.min.x and p.x < b.max.x and p.y >= b.min.y and p.y < b.max.y;
}

test "dock is centered at the bottom and hit-tests its slots" {
    const d = Dock.of(1920, 1080, .rect);
    try std.testing.expectEqual(@as(f32, 1), d.s);
    try std.testing.expectApproxEqAbs(1920 - d.panel.max.x, d.panel.min.x, 1);
    try std.testing.expect(d.panel.max.y < 1080);
    const t = d.tools[2];
    try std.testing.expectEqual(Hit{ .tool = keymap.tools[2].tool }, d.hit(t.min.add(t.max).scale(0.5)).?);
    try std.testing.expectEqual(Hit{ .color = 3 }, d.hit(d.swatches[3]).?);
    try std.testing.expectEqual(Hit.help, d.hit(d.help.min.add(d.help.max).scale(0.5)).?);
    try std.testing.expectEqual(@as(?Hit, null), d.hit(.{ .x = 10, .y = 10 }));
    // 4K: twice as big. Narrow screen: shrunk to fit.
    try std.testing.expectEqual(@as(f32, 2), Dock.of(3840, 2160, .rect).s);
    const narrow = Dock.of(300, 1080, .rect);
    try std.testing.expect(narrow.panel.min.x >= 0 and narrow.panel.max.x <= 300);
}

test "the pointer style switch shows above the dock with the callout tool only" {
    const other = Dock.of(1920, 1080, .rect);
    try std.testing.expectEqual(@as(?Bounds, null), other.switch_panel);
    const d = Dock.of(1920, 1080, .callout);
    const sp = d.switch_panel.?;
    try std.testing.expect(sp.max.y < d.panel.min.y);
    try std.testing.expectEqual(d.panel.min.x, sp.min.x);
    for (d.styles, arrow_styles) |b, st| {
        const c = b.min.add(b.max).scale(0.5);
        try std.testing.expectEqual(Hit{ .arrow_style = st }, d.hit(c).?);
        try std.testing.expect(d.contains(c));
        try std.testing.expectEqual(@as(?Hit, null), other.hit(c));
        try std.testing.expect(!other.contains(c));
    }
}

test "with the callout tool the switch sits over the callout slot" {
    const d = Dock.of(1920, 1080, .callout);
    const sp = d.switch_panel.?;
    const slot_b = d.tools[toolIndex(.callout)];
    try std.testing.expect(sp.min.x <= slot_b.min.x + (slot_b.max.x - slot_b.min.x) / 2 and sp.max.x >= slot_b.min.x + (slot_b.max.x - slot_b.min.x) / 2);
    for (d.styles, arrow_styles) |b, st| {
        try std.testing.expectEqual(Hit{ .arrow_style = st }, d.hit(b.min.add(b.max).scale(0.5)).?);
    }
}

test "the text tool has a style switch of its own" {
    const d = Dock.of(1920, 1080, .text);
    try std.testing.expect(d.switch_panel != null);
    for (d.styles, text_styles) |b, st| {
        try std.testing.expectEqual(Hit{ .text_style = st }, d.hit(b.min.add(b.max).scale(0.5)).?);
    }
}
