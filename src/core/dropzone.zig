//! Drop-slot overlay of a montage drag: while an image of a known size is
//! dragged, every free magnet slot around the placed images shows as a faint
//! dashed outline, and the slot nearest to the pointer as a stronger one with
//! a faint fill. Pure: `build` turns the document, the view and the drag
//! state into screen rectangles; `paint` draws them; the compositor keeps
//! the last overlay to damage exactly what changed.
const std = @import("std");
const geom = @import("geom.zig");
const color = @import("color.zig");
const dashed = @import("dashed.zig");
const magnet = @import("magnet.zig");
const style = @import("style.zig");
const Canvas = @import("canvas.zig").Canvas;
const Document = @import("document.zig").Document;
const View = @import("view.zig").View;

const Rect = geom.Rect;
const Vec2 = geom.Vec2;

/// The editor state of a drag: the size of the dragged image (px) and the
/// pointer (screen px).
pub const Drop = struct {
    w: i32,
    h: i32,
    pointer: Vec2,
};

const line = color.nord.n8;

pub const Overlay = struct {
    /// Slots on screen (not clipped).
    rects: []Rect = &.{},
    /// Index of the slot nearest to the pointer.
    hot: ?usize = null,
    /// Screen height: scales the dashes.
    screen_h: u32 = 0,

    pub fn deinit(o: *Overlay, gpa: std.mem.Allocator) void {
        gpa.free(o.rects);
        o.* = .{};
    }

    /// The free slots of `doc` for the dragged image, on screen.
    pub fn build(gpa: std.mem.Allocator, doc: *const Document, view: View, drop: Drop) !Overlay {
        const n = doc.scene.count();
        const placed = try gpa.alloc(Rect, n);
        defer gpa.free(placed);
        for (doc.scene.images.items, placed) |p, *r| r.* = p.rect();
        const buf = try gpa.alloc(magnet.Slot, magnet.maxSlots(n));
        defer gpa.free(buf);
        const list = magnet.slots(buf, placed, drop.w, drop.h);
        const rects = try gpa.alloc(Rect, list.len);
        for (list, rects) |s, *r| r.* = view.rect(s.rect);
        var o = Overlay{ .rects = rects, .screen_h = view.screen_h };
        if (magnet.nearest(list, view.toImage(drop.pointer))) |best| {
            for (list, 0..) |s, i| if (s.target == best.target and s.side == best.side) {
                o.hot = i;
            };
        }
        return o;
    }

    pub fn eql(a: Overlay, b: Overlay) bool {
        if (a.hot != b.hot or a.screen_h != b.screen_h or a.rects.len != b.rects.len) return false;
        for (a.rects, b.rects) |x, y| if (!std.meta.eql(x, y)) return false;
        return true;
    }

    /// Draw the overlay in `clip`.
    pub fn paint(o: Overlay, cv: *Canvas, clip: Rect) void {
        const ui = style.uiScale(o.screen_h);
        const w: i32 = @intFromFloat(@round(ui));
        for (o.rects, 0..) |r, i| {
            if (!r.intersects(clip)) continue;
            const hot = o.hot == i;
            if (hot) cv.blendRect(r.intersect(clip), line.withAlpha(36));
            dashed.rect(cv, clip, r, .{
                .w = if (hot) w * 2 else w,
                .dash = @intFromFloat(@round(8 * ui)),
                .gap = @intFromFloat(@round(6 * ui)),
                .color = line.withAlpha(if (hot) 235 else 130),
            });
        }
    }
};

test "the slot under the pointer is hot, slots on images are not offered" {
    const gpa = std.testing.allocator;
    var doc = Document{};
    defer doc.deinit(gpa);
    _ = try doc.addImage(gpa, 100, 100, 0, 0, null, false);
    const view = View.fit(Rect.fromSize(0, 0, 100, 100), 400, 400);
    const right = magnet.slotRect(Rect.fromSize(0, 0, 100, 100), .right, 50, 50);
    var o = try Overlay.build(gpa, &doc, view, .{ .w = 50, .h = 50, .pointer = view.toScreen(Vec2.init(@floatFromInt(right.x0 + 5), 50)) });
    defer o.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 4), o.rects.len);
    try std.testing.expectEqual(@as(usize, 2), o.hot.?); // left, top, right, bottom
    var o2 = try Overlay.build(gpa, &doc, view, .{ .w = 50, .h = 50, .pointer = view.toScreen(Vec2.init(50, -400)) });
    defer o2.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), o2.hot.?);
    try std.testing.expect(!o.eql(o2));
}
