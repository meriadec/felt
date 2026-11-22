//! Top bar geometry: a small panel at the top center with the Undo and Redo
//! buttons, in the dock style. Pure layout from the screen size: chrome.zig
//! draws it and the editor hit-tests clicks and hover with the same numbers.
//! Only undo and redo live here: they have no single-key shortcut and are
//! the most common mouse action after picking a tool. Save and copy stay on
//! the keyboard (Ctrl+S, Ctrl+C), so the bar stays small over the image.
const std = @import("std");
const geom = @import("geom.zig");
const style = @import("style.zig");

const Vec2 = geom.Vec2;
const Bounds = geom.Bounds;

pub const Button = enum { undo, redo };

pub const buttons = [_]Button{ .undo, .redo };
const n_buttons: comptime_int = buttons.len;

// Metrics in px at UI scale 1 (same slot and padding as the dock).
const slot = 40.0;
const slot_gap = 4.0;
const pad = 8.0;
const margin = 14.0;

pub const TopBar = struct {
    /// Px per 1080p px.
    s: f32,
    panel: Bounds,
    slots: [buttons.len]Bounds,

    pub fn of(w: u32, h: u32) TopBar {
        const W: f32 = @floatFromInt(w);
        var s = style.uiScale(h);
        const nat = 2 * pad + n_buttons * slot + (n_buttons - 1) * slot_gap;
        if ((nat + 2 * margin) * s > W) s *= W / ((nat + 2 * margin) * s);
        const pw = nat * s;
        const ph = (slot + 2 * pad) * s;
        const x0 = @round((W - pw) / 2);
        const y0 = @round(margin * s);
        var b: TopBar = .{ .s = s, .panel = .{ .min = .{ .x = x0, .y = y0 }, .max = .{ .x = x0 + pw, .y = y0 + ph } }, .slots = undefined };
        var x = x0 + pad * s;
        for (&b.slots) |*r| {
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
    try std.testing.expectEqual(@as(f32, 14), b.panel.min.y);
    try std.testing.expectEqual(Button.undo, b.hit(center(b.slots[0])).?);
    try std.testing.expectEqual(Button.redo, b.hit(center(b.slots[1])).?);
    try std.testing.expectEqual(@as(?Button, null), b.hit(.{ .x = 10, .y = 10 }));
    try std.testing.expectEqual(@as(f32, 2), TopBar.of(3840, 2160).s);
}
