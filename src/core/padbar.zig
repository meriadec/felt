//! Padding widget geometry: a small panel at the bottom right with the
//! canvas padding slider (a track with one notch per step of
//! settings.padding_steps, centered in a panel as tall as the dock), in the dock style. Pure layout from the screen
//! size: chrome.zig draws it and the editor hit-tests clicks, drags, wheel
//! and hover with the same numbers.
const std = @import("std");
const geom = @import("geom.zig");
const style = @import("style.zig");
const grid = @import("grid.zig");
const settings = @import("settings.zig");

const Vec2 = geom.Vec2;
const Bounds = geom.Bounds;

// Metrics in px at UI scale 1 (same slot and padding as the dock).
const slot_h = 40.0;
const pad = 2.0;
const margin = 14.0;
/// The slider's width, the inset of the track ends, and the track's
/// distance from the top of the slot.
const slider_w = 160.0;
const track_inset = 20.0;
const track_y = 20.0;

pub const PadBar = struct {
    /// Px per 1080p px.
    s: f32,
    panel: Bounds,
    /// The slider's slot (the panel without its padding).
    slot: Bounds,

    pub fn of(w: u32, h: u32) PadBar {
        const W: f32 = @floatFromInt(w);
        const H: f32 = @floatFromInt(h);
        const s = style.uiScale(h);
        const st = grid.step(h);
        const pw = grid.cells((slider_w + 2 * pad) * s, st);
        const ph = 2 * st;
        const x1 = grid.atMost(grid.centerX(w), st, W - margin * s);
        const y1 = grid.atMost(grid.centerY(h), st, H - margin * s);
        const panel = grid.panel(x1 - pw, y1 - ph, x1, y1);
        // The slot: the panel inside its border, with an even gap around the slider.
        const gap = (ph - slot_h * s) / 2;
        const slot = Bounds{ .min = .{ .x = x1 - pw + 0.5 + gap, .y = y1 - ph + 0.5 + gap }, .max = .{ .x = x1 + 0.5 - gap, .y = y1 + 0.5 - gap } };
        return .{ .s = s, .panel = panel, .slot = slot };
    }

    /// x of the notch of padding step `i` (the knob rests there).
    pub fn notchX(b: *const PadBar, i: usize) f32 {
        const x0 = b.slot.min.x + track_inset * b.s;
        const x1 = b.slot.max.x - track_inset * b.s;
        const n: f32 = @floatFromInt(settings.padding_steps.len - 1);
        return x0 + (x1 - x0) * @as(f32, @floatFromInt(i)) / n;
    }

    /// y of the track.
    pub fn trackY(b: *const PadBar) f32 {
        return b.slot.min.y + track_y * b.s;
    }

    /// The step whose notch is nearest to screen x (a click or a drag).
    pub fn stepAt(b: *const PadBar, x: f32) usize {
        var best: usize = 0;
        for (0..settings.padding_steps.len) |i| {
            if (@abs(b.notchX(i) - x) < @abs(b.notchX(best) - x)) best = i;
        }
        return best;
    }

    /// True if `p` is on the panel (clicks there never draw).
    pub fn contains(b: *const PadBar, p: Vec2) bool {
        return p.x >= b.panel.min.x and p.x < b.panel.max.x and p.y >= b.panel.min.y and p.y < b.panel.max.y;
    }
};

test "pad bar sits at the bottom right" {
    const b = PadBar.of(1920, 1080);
    try std.testing.expectEqual(@as(f32, 1888 + 2), b.panel.max.x);
    try std.testing.expectEqual(@as(f32, 1052 + 2), b.panel.max.y);
    try std.testing.expect(b.contains(.{ .x = b.notchX(1), .y = b.trackY() }));
    try std.testing.expect(!b.contains(.{ .x = 10, .y = 10 }));
}

test "slider: notches are spread over the track and a point snaps to the nearest" {
    const b = PadBar.of(1920, 1080);
    const n = settings.padding_steps.len;
    try std.testing.expect(b.notchX(0) > b.slot.min.x and b.notchX(n - 1) < b.slot.max.x);
    for (0..n) |i| {
        try std.testing.expectEqual(i, b.stepAt(b.notchX(i)));
        if (i > 0) try std.testing.expect(b.notchX(i) > b.notchX(i - 1));
    }
    try std.testing.expectEqual(@as(usize, 0), b.stepAt(-100));
    try std.testing.expectEqual(n - 1, b.stepAt(5000));
    try std.testing.expectEqual(@as(usize, 1), b.stepAt((b.notchX(1) + b.notchX(2)) / 2 - 1));
    try std.testing.expect(b.trackY() > b.slot.min.y and b.trackY() < b.slot.max.y);
}
