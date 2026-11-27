//! Top bar geometry: a small panel at the top center with the Undo and Redo
//! buttons, a separator and the canvas background switch (light / dark),
//! in the dock style. Pure layout from the screen size: chrome.zig draws it
//! and the editor hit-tests clicks and hover with the same numbers. Undo
//! and redo have no single-key shortcut and are the most common mouse
//! action after picking a tool; the canvas switch is a view setting, not a
//! tool, so it sits here and not in the dock. Save and copy stay on the
//! keyboard (Ctrl+S, Ctrl+C), so the bar stays small over the image.
const std = @import("std");
const geom = @import("geom.zig");
const style = @import("style.zig");
const grid = @import("grid.zig");

const Vec2 = geom.Vec2;
const Bounds = geom.Bounds;

pub const Button = enum { undo, redo, canvas_bg };

pub const buttons = [_]Button{ .undo, .redo, .canvas_bg };
const n_buttons: comptime_int = buttons.len;

// Metrics in px at UI scale 1 (same slot and padding as the dock).
const slot = 40.0;
const slot_gap = 2.0;
const pad = 2.0;
const margin = 14.0;
/// Room for the separator line before the canvas switch.
const sep_w = 26.0;

pub const TopBar = struct {
    /// Px per 1080p px.
    s: f32,
    panel: Bounds,
    slots: [buttons.len]Bounds,
    /// x of the separator line between redo and the canvas switch.
    sep: f32,

    pub fn of(w: u32, h: u32) TopBar {
        const W: f32 = @floatFromInt(w);
        var s = style.uiScale(h);
        const nat = 2 * pad + n_buttons * slot + (n_buttons - 2) * slot_gap + sep_w;
        const avail = 2 * grid.step(h) * @floor(W / (2 * grid.step(h)));
        if (nat * s > avail) s = avail / nat;
        const st = grid.step(h);
        const pw = grid.evenCells(nat * s, st);
        const ph = 2 * st;
        const lx0 = grid.centerX(w) - pw / 2;
        const ly0 = grid.atLeast(grid.centerY(h), st, margin * s);
        var b: TopBar = .{ .s = s, .panel = grid.panel(lx0, ly0, lx0 + pw, ly0 + ph), .slots = undefined, .sep = 0 };
        const x0 = lx0 + 0.5;
        const y0 = ly0 + 0.5 + (ph - slot * s) / 2 - pad * s;
        var x = x0 + (pw - nat * s) / 2 + pad * s;
        for (&b.slots, buttons) |*r, btn| {
            if (btn == .canvas_bg) { // after the separator, not a gap
                x -= slot_gap * s;
                b.sep = x + sep_w * s / 2;
                x += sep_w * s;
            }
            r.* = .{ .min = .{ .x = x, .y = y0 + pad * s }, .max = .{ .x = x + slot * s, .y = y0 + (pad + slot) * s } };
            x += (slot + slot_gap) * s;
        }
        return b;
    }

    /// The button under `p`, or null.
    pub fn hit(b: *const TopBar, p: Vec2) ?Button {
        for (b.slots, buttons) |r, btn| if (inside(r, p)) return btn;
        return null;
    }

    /// True if `p` is on the panel (clicks there never draw).
    pub fn contains(b: *const TopBar, p: Vec2) bool {
        return inside(b.panel, p);
    }
};

fn inside(b: Bounds, p: Vec2) bool {
    return p.x >= b.min.x and p.x < b.max.x and p.y >= b.min.y and p.y < b.max.y;
}

fn center(b: Bounds) Vec2 {
    return b.min.add(b.max).scale(0.5);
}

test "top bar is centered at the top and hit-tests its buttons" {
    const b = TopBar.of(1920, 1080);
    try std.testing.expectApproxEqAbs(1920 - b.panel.max.x, b.panel.min.x, 1);
    try std.testing.expectEqual(@as(f32, 28 - 1), b.panel.min.y);
    try std.testing.expectEqual(Button.undo, b.hit(center(b.slots[0])).?);
    try std.testing.expectEqual(Button.redo, b.hit(center(b.slots[1])).?);
    try std.testing.expectEqual(Button.canvas_bg, b.hit(center(b.slots[2])).?);
    try std.testing.expect(b.slots[1].max.x < b.sep and b.sep < b.slots[2].min.x);
    try std.testing.expectEqual(@as(?Button, null), b.hit(.{ .x = b.sep, .y = center(b.slots[2]).y }));
    try std.testing.expect(b.slots[2].max.x < b.panel.max.x - 2);
    try std.testing.expectEqual(@as(?Button, null), b.hit(.{ .x = 10, .y = 10 }));
    try std.testing.expectEqual(@as(f32, 2), TopBar.of(3840, 2160).s);
}
