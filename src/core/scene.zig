//! Scene: the placed images of a document. Each placed image has a stable
//! `id`, a size, a position (scene px, its top-left corner) and a pixel
//! canvas. The scene space is the space of the annotations. A document with
//! one image has it at (0, 0): scene px are image px. The list order is the
//! paint order (the last one is on top). This file holds the model and its
//! queries only; the undo history of changes is in document.zig, where
//! magnet.zig picks the positions.
const std = @import("std");
const geom = @import("geom.zig");
const Canvas = @import("canvas.zig").Canvas;

const Rect = geom.Rect;
const Vec2 = geom.Vec2;

/// An image placed in the scene. `canvas` null: a size-only image (pure
/// tests), nothing to paint. `owned`: the scene frees the canvas
/// (`release`); the first image of an App belongs to the App.
pub const Placed = struct {
    id: u32,
    w: i32,
    h: i32,
    x: i32,
    y: i32,
    canvas: ?*const Canvas = null,
    owned: bool = false,

    pub fn rect(p: Placed) Rect {
        return Rect.fromSize(p.x, p.y, p.w, p.h);
    }

    /// Free the canvas if the scene owns it.
    pub fn release(p: Placed, gpa: std.mem.Allocator) void {
        if (!p.owned) return;
        const c: *Canvas = @constCast(p.canvas.?);
        c.deinit(gpa);
        gpa.destroy(c);
    }
};

pub const Scene = struct {
    images: std.ArrayList(Placed) = .empty,
    next_id: u32 = 0,

    /// Frees the canvases the scene owns.
    pub fn deinit(self: *Scene, gpa: std.mem.Allocator) void {
        for (self.images.items) |p| p.release(gpa);
        self.images.deinit(gpa);
    }

    pub fn count(self: *const Scene) usize {
        return self.images.items.len;
    }

    /// Union of the placed images; empty with none.
    pub fn bounds(self: *const Scene) Rect {
        var r = Rect.empty;
        for (self.images.items) |p| r = r.unite(p.rect());
        return r;
    }

    pub fn indexOf(self: *const Scene, id: u32) ?usize {
        for (self.images.items, 0..) |p, i| if (p.id == id) return i;
        return null;
    }

    /// Topmost image whose rectangle holds the scene point `p`.
    pub fn imageAt(self: *const Scene, p: Vec2) ?usize {
        var i = self.images.items.len;
        while (i > 0) {
            i -= 1;
            const b = self.images.items[i].rect().toBounds();
            if (p.x >= b.min.x and p.y >= b.min.y and p.x < b.max.x and p.y < b.max.y) return i;
        }
        return null;
    }

    /// The image under `p`, else the nearest one (distance to its rectangle,
    /// the first on a tie); null with no images.
    pub fn nearest(self: *const Scene, p: Vec2) ?usize {
        if (self.imageAt(p)) |i| return i;
        var best: ?usize = null;
        var bd: f32 = 0;
        for (self.images.items, 0..) |im, i| {
            const b = im.rect().toBounds();
            const dx = @max(b.min.x - p.x, 0, p.x - b.max.x);
            const dy = @max(b.min.y - p.y, 0, p.y - b.max.y);
            const d = dx * dx + dy * dy;
            if (best == null or d < bd) {
                best = i;
                bd = d;
            }
        }
        return best;
    }

    /// The rectangles of all images, in order, into `out` (len `count`).
    pub fn rects(self: *const Scene, out: []Rect) []Rect {
        for (self.images.items, 0..) |p, i| out[i] = p.rect();
        return out[0..self.images.items.len];
    }

    /// A new id (never reused in this scene).
    pub fn newId(self: *Scene) u32 {
        defer self.next_id += 1;
        return self.next_id;
    }
};

test "bounds is the union; hit test takes the topmost; nearest falls back to distance" {
    const gpa = std.testing.allocator;
    var s = Scene{};
    defer s.deinit(gpa);
    try std.testing.expectEqual(Rect.empty, s.bounds());
    try std.testing.expectEqual(@as(?usize, null), s.nearest(Vec2.zero));
    try s.images.append(gpa, .{ .id = s.newId(), .w = 100, .h = 50, .x = 0, .y = 0 });
    try s.images.append(gpa, .{ .id = s.newId(), .w = 100, .h = 100, .x = 164, .y = -20 });
    try std.testing.expectEqual(Rect{ .x0 = 0, .y0 = -20, .x1 = 264, .y1 = 80 }, s.bounds());
    try std.testing.expectEqual(@as(?usize, 0), s.imageAt(Vec2.init(99.5, 10)));
    try std.testing.expectEqual(@as(?usize, null), s.imageAt(Vec2.init(100, 10)));
    try std.testing.expectEqual(@as(?usize, 1), s.imageAt(Vec2.init(164, -20)));
    try std.testing.expectEqual(@as(?usize, 0), s.nearest(Vec2.init(120, 10))); // in the gap, nearer to 0
    try std.testing.expectEqual(@as(?usize, 1), s.nearest(Vec2.init(150, 10)));
    try std.testing.expectEqual(@as(?usize, 1), s.indexOf(1));
}
