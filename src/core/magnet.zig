//! Magnet: where a dragged image can land next to the placed ones. A slot is
//! a rectangle at the left, top, right or bottom of a placed image, `gap`
//! px away from it and centered on the shared edge. Pure functions on
//! rectangles (scene px): no images, no state. A slot that would overlap a
//! placed image is not offered.
const std = @import("std");
const geom = @import("geom.zig");

const Rect = geom.Rect;
const Vec2 = geom.Vec2;

/// Space between two images placed by a magnet slot (scene px).
pub const gap: i32 = 64;

pub const Side = enum { left, top, right, bottom };

pub const sides = [_]Side{ .left, .top, .right, .bottom };

/// Four slots per placed image at most.
pub const Slot = struct {
    /// Index in the list of placed rectangles that the slot hangs on.
    target: usize,
    side: Side,
    /// Where the dragged image would sit.
    rect: Rect,
};

/// The rectangle for an image of `w` x `h` on `side` of `target`: `gap` away,
/// centered on the shared edge.
pub fn slotRect(target: Rect, side: Side, w: i32, h: i32) Rect {
    const cx = target.x0 + @divFloor(target.width() - w, 2);
    const cy = target.y0 + @divFloor(target.height() - h, 2);
    return switch (side) {
        .left => Rect.fromSize(target.x0 - gap - w, cy, w, h),
        .right => Rect.fromSize(target.x1 + gap, cy, w, h),
        .top => Rect.fromSize(cx, target.y0 - gap - h, w, h),
        .bottom => Rect.fromSize(cx, target.y1 + gap, w, h),
    };
}

/// Upper bound of `slots` results for `n` placed images.
pub fn maxSlots(n: usize) usize {
    return 4 * n;
}

/// Free slots for an image of `w` x `h` around `placed`, in the order
/// target, left, top, right, bottom. `out` must hold `maxSlots(placed.len)`.
pub fn slots(out: []Slot, placed: []const Rect, w: i32, h: i32) []Slot {
    var n: usize = 0;
    for (placed, 0..) |t, i| for (sides) |s| {
        const r = slotRect(t, s, w, h);
        var free = true;
        for (placed) |o| free = free and !o.intersects(r);
        if (!free) continue;
        out[n] = .{ .target = i, .side = s, .rect = r };
        n += 1;
    };
    return out[0..n];
}

fn dist2(r: Rect, p: Vec2) f32 {
    const b = r.toBounds();
    const dx = @max(b.min.x - p.x, 0, p.x - b.max.x);
    const dy = @max(b.min.y - p.y, 0, p.y - b.max.y);
    return dx * dx + dy * dy;
}

fn center2(r: Rect, p: Vec2) f32 {
    const c = r.toBounds();
    const q = Vec2.init((c.min.x + c.max.x) / 2, (c.min.y + c.max.y) / 2);
    const d = q.sub(p);
    return d.dot(d);
}

/// The slot nearest to the point `p`: the nearest by distance to its
/// rectangle (0 inside), ties by distance to its center. Null: no slot.
pub fn nearest(list: []const Slot, p: Vec2) ?Slot {
    var best: ?Slot = null;
    var bd: f32 = 0;
    var bc: f32 = 0;
    for (list) |s| {
        const d = dist2(s.rect, p);
        const c = center2(s.rect, p);
        if (best == null or d < bd or (d == bd and c < bc)) {
            best = s;
            bd = d;
            bc = c;
        }
    }
    return best;
}

test "a slot is gap away and centered on the shared edge" {
    const t = Rect.fromSize(100, 100, 200, 100);
    try std.testing.expectEqual(Rect.fromSize(100 - gap - 50, 100 + 25, 50, 50), slotRect(t, .left, 50, 50));
    try std.testing.expectEqual(Rect.fromSize(300 + gap, 125, 50, 50), slotRect(t, .right, 50, 50));
    try std.testing.expectEqual(Rect.fromSize(175, 100 - gap - 50, 50, 50), slotRect(t, .top, 50, 50));
    try std.testing.expectEqual(Rect.fromSize(175, 200 + gap, 50, 50), slotRect(t, .bottom, 50, 50));
    // Bigger than the target: centered, so it sticks out on both sides.
    try std.testing.expectEqual(Rect.fromSize(50, 200 + gap, 300, 20), slotRect(t, .bottom, 300, 20));
}

test "slots skip places that overlap a placed image" {
    const a = Rect.fromSize(0, 0, 100, 100);
    const b = Rect.fromSize(100 + gap, 0, 100, 100); // right of a
    var buf: [8]Slot = undefined;
    const s = slots(&buf, &.{ a, b }, 100, 100);
    // a: right is taken by b; b: left is taken by a. 3 + 3 left.
    try std.testing.expectEqual(@as(usize, 6), s.len);
    for (s) |x| {
        try std.testing.expect(!a.intersects(x.rect));
        try std.testing.expect(!b.intersects(x.rect));
    }
    try std.testing.expectEqual(@as(usize, 4), slots(&buf, &.{a}, 10, 10).len);
    try std.testing.expectEqual(@as(usize, 0), slots(&buf, &.{}, 10, 10).len);
}

test "nearest picks the slot under the point, else the closest one" {
    const a = Rect.fromSize(0, 0, 100, 100);
    var buf: [4]Slot = undefined;
    const s = slots(&buf, &.{a}, 100, 100);
    const right = slotRect(a, .right, 100, 100);
    const inside = nearest(s, Vec2.init(@floatFromInt(right.x0 + 10), 50)).?;
    try std.testing.expectEqual(Side.right, inside.side);
    try std.testing.expectEqual(@as(usize, 0), inside.target);
    // Far above and a bit right: the top slot.
    try std.testing.expectEqual(Side.top, nearest(s, Vec2.init(60, -500)).?.side);
    try std.testing.expectEqual(Side.left, nearest(s, Vec2.init(-400, 40)).?.side);
    try std.testing.expectEqual(Side.bottom, nearest(s, Vec2.init(50, 900)).?.side);
    try std.testing.expect(nearest(&.{}, Vec2.zero) == null);
}
