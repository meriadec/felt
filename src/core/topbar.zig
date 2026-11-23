//! Top bar geometry: a small panel at the top center with the Undo and Redo
//! buttons, a separator, the canvas background switch (light / dark) and
//! the canvas padding slider (a label and a track with one notch per step
//! of settings.padding_steps), in the dock style. Pure layout from the screen size: chrome.zig draws it
//! and the editor hit-tests clicks and hover with the same numbers. Undo
//! and redo have no single-key shortcut and are the most common mouse
//! action after picking a tool; the canvas switch is a view setting, not a
//! tool, so it sits here and not in the dock. Save and copy stay on the
//! keyboard (Ctrl+S, Ctrl+C), so the bar stays small over the image.
const std = @import("std");
const geom = @import("geom.zig");
const style = @import("style.zig");
const settings = @import("settings.zig");

const Vec2 = geom.Vec2;
const Bounds = geom.Bounds;

pub const Button = enum { undo, redo, canvas_bg, padding };

pub const buttons = [_]Button{ .undo, .redo, .canvas_bg, .padding };
const n_buttons: comptime_int = buttons.len;

// Metrics in px at UI scale 1 (same slot and padding as the dock).
const slot = 40.0;
const slot_gap = 4.0;
const pad = 8.0;
const margin = 14.0;
/// Room for the separator line before the canvas switch.
const sep_w = 17.0;
/// The padding slider: its width, the inset of the track ends, and the
/// track's distance from the top of the slot.
const slider_w = 140.0;
const track_inset = 10.0;
const track_y = 29.0;

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
        const nat = 2 * pad + (n_buttons - 1) * slot + slider_w + (n_buttons - 2) * slot_gap + sep_w;
        if ((nat + 2 * margin) * s > W) s *= W / ((nat + 2 * margin) * s);
        const pw = nat * s;
        const ph = (slot + 2 * pad) * s;
        const x0 = @round((W - pw) / 2);
        const y0 = @round(margin * s);
        var b: TopBar = .{ .s = s, .panel = .{ .min = .{ .x = x0, .y = y0 }, .max = .{ .x = x0 + pw, .y = y0 + ph } }, .slots = undefined, .sep = 0 };
        var x = x0 + pad * s;
        for (&b.slots, buttons) |*r, btn| {
            if (btn == .canvas_bg) { // after the separator, not a gap
                x -= slot_gap * s;
                b.sep = x + sep_w * s / 2;
                x += sep_w * s;
            }
            const bw: f32 = if (btn == .padding) slider_w else slot;
            r.* = .{ .min = .{ .x = x, .y = y0 + pad * s }, .max = .{ .x = x + bw * s, .y = y0 + (pad + slot) * s } };
            x += (bw + slot_gap) * s;
        }
        return b;
    }

    /// The button under `p`, or null.
    pub fn hit(b: *const TopBar, p: Vec2) ?Button {
        for (b.slots, buttons) |r, btn| if (inside(r, p)) return btn;
        return null;
    }

    /// The slider's slot.
    pub fn slider(b: *const TopBar) Bounds {
        return b.slots[@intFromEnum(Button.padding)];
    }

    /// x of the notch of padding step `i` (the knob rests there).
    pub fn notchX(b: *const TopBar, i: usize) f32 {
        const r = b.slider();
        const x0 = r.min.x + track_inset * b.s;
        const x1 = r.max.x - track_inset * b.s;
        const n: f32 = @floatFromInt(settings.padding_steps.len - 1);
        return x0 + (x1 - x0) * @as(f32, @floatFromInt(i)) / n;
    }

    /// y of the track.
    pub fn trackY(b: *const TopBar) f32 {
        return b.slider().min.y + track_y * b.s;
    }

    /// The step whose notch is nearest to screen x (a click or a drag).
    pub fn stepAt(b: *const TopBar, x: f32) usize {
        var best: usize = 0;
        for (0..settings.padding_steps.len) |i| {
            if (@abs(b.notchX(i) - x) < @abs(b.notchX(best) - x)) best = i;
        }
        return best;
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
    try std.testing.expectEqual(Button.canvas_bg, b.hit(center(b.slots[2])).?);
    try std.testing.expect(b.slots[1].max.x < b.sep and b.sep < b.slots[2].min.x);
    try std.testing.expectEqual(@as(?Button, null), b.hit(.{ .x = b.sep, .y = center(b.slots[2]).y }));
    try std.testing.expectEqual(Button.padding, b.hit(center(b.slots[3])).?);
    try std.testing.expectApproxEqAbs(b.panel.max.x - 8, b.slots[3].max.x, 0.01);
    try std.testing.expectEqual(@as(?Button, null), b.hit(.{ .x = 10, .y = 10 }));
    try std.testing.expectEqual(@as(f32, 2), TopBar.of(3840, 2160).s);
}

test "slider: notches are spread over the track and a point snaps to the nearest" {
    const b = TopBar.of(1920, 1080);
    const n = settings.padding_steps.len;
    try std.testing.expect(b.notchX(0) > b.slider().min.x and b.notchX(n - 1) < b.slider().max.x);
    for (0..n) |i| {
        try std.testing.expectEqual(i, b.stepAt(b.notchX(i)));
        if (i > 0) try std.testing.expect(b.notchX(i) > b.notchX(i - 1));
    }
    try std.testing.expectEqual(@as(usize, 0), b.stepAt(-100));
    try std.testing.expectEqual(n - 1, b.stepAt(5000));
    try std.testing.expectEqual(@as(usize, 1), b.stepAt((b.notchX(1) + b.notchX(2)) / 2 - 1));
    try std.testing.expect(b.trackY() > b.slider().min.y and b.trackY() < b.slider().max.y);
}
