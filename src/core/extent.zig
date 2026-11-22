//! Extent: the canvas of the document, in image pixels. The canvas is the
//! kept rectangle (the image, or the last crop) grown to hold the
//! annotations made since. Each annotation has its own clip: the kept
//! rectangle at its creation, grown on every side that the body of the
//! shape crosses, to its full draw bounds (shadow included) plus `pad`.
//! A shape inside the image never grows the canvas, even if its shadow
//! touches the edge. The canvas is the union of the kept rectangle and these
//! clips. Canvas areas outside the image are `fill` (white), on screen and in
//! the export. Clips never change once made, so the compositor can append.
const std = @import("std");
const geom = @import("geom.zig");
const draw = @import("draw.zig");
const color = @import("color.zig");
const Document = @import("document.zig").Document;
const Annotation = @import("annotation.zig").Annotation;

const Rect = geom.Rect;

/// White space (image px) kept past a shape on a side it grew.
pub const pad = 16;

/// Color of the canvas outside the image.
pub const fill = color.white;

/// A canvas grows at most this far past the kept rectangle on each side:
/// the larger kept side, clamped to [min_reach, max_reach]. It bounds the
/// memory of the export; min_reach covers a 4K screen around a small image
/// at 1:1.
const min_reach = 2048;
const max_reach = 4096;

/// How far the canvas can grow around `kept`.
pub fn limit(kept: Rect) Rect {
    return kept.expand(std.math.clamp(@max(kept.width(), kept.height()), min_reach, max_reach));
}

/// The point (image px) is close enough to `kept` to draw there.
pub fn reachable(kept: Rect, p: geom.Vec2) bool {
    const l = limit(kept);
    return p.x >= @as(f32, @floatFromInt(l.x0)) and p.y >= @as(f32, @floatFromInt(l.y0)) and
        p.x < @as(f32, @floatFromInt(l.x1)) and p.y < @as(f32, @floatFromInt(l.y1));
}

/// The body of `a` touches the reach of `kept`: it can be added.
pub fn fits(ctx: draw.Ctx, kept: Rect, a: Annotation) bool {
    return draw.bodyBounds(ctx, a, .identity).intersects(limit(kept));
}

/// Clip of `a` made while `kept` was the kept rectangle.
pub fn grow(ctx: draw.Ctx, kept: Rect, a: Annotation) Rect {
    const body = draw.bodyBounds(ctx, a, .identity);
    if (!body.intersects(limit(kept))) return kept; // out of reach: never added
    const full = draw.bounds(ctx, a, .identity, .{});
    var r = kept;
    if (body.x0 < kept.x0) r.x0 = @min(r.x0, full.x0 - pad);
    if (body.y0 < kept.y0) r.y0 = @min(r.y0, full.y0 - pad);
    if (body.x1 > kept.x1) r.x1 = @max(r.x1, full.x1 + pad);
    if (body.y1 > kept.y1) r.y1 = @max(r.y1, full.y1 + pad);
    return r.intersect(limit(kept));
}

/// The kept rectangle when annotation `i` was made (image w x h).
fn keptAt(doc: *const Document, w: u32, h: u32, i: usize) Rect {
    var r = Rect.fromSize(0, 0, @intCast(w), @intCast(h));
    for (doc.crops.items) |c| {
        if (c.first <= i) r = c.rect;
    }
    return r;
}

/// Clip of annotation `i`: its own clip, cut by every later crop.
pub fn itemClip(ctx: draw.Ctx, doc: *const Document, w: u32, h: u32, i: usize) Rect {
    const r = grow(ctx, keptAt(doc, w, h, i), doc.items.items[i]);
    return if (doc.clipOf(i)) |c| r.intersect(c) else r;
}

/// The canvas of the document over an image of size w x h.
pub fn canvas(ctx: draw.Ctx, doc: *const Document, w: u32, h: u32) Rect {
    const kept = doc.kept(w, h);
    var r = kept;
    for (doc.growing()) |a| r = r.unite(grow(ctx, kept, a));
    return r;
}

test "a shape grows the canvas only on the sides its body crosses" {
    const gpa = std.testing.allocator;
    var font = try @import("font.zig").Font.init(gpa, @import("root.zig").font_ttf);
    defer font.deinit();
    const ctx = draw.Ctx{ .gpa = gpa, .font = &font };
    const red = color.palette[0].color;
    var doc = Document{};
    defer doc.deinit(gpa);
    const img = Rect.fromSize(0, 0, 200, 100);
    // Inside, near the edge: the shadow touches the edge but nothing grows.
    try doc.add(gpa, .{ .arrow = .{ .tail = .{ .x = 20, .y = 50 }, .head = .{ .x = 199, .y = 50 }, .width = 6, .color = red } });
    try std.testing.expectEqual(img, canvas(ctx, &doc, 200, 100));
    // Past the right edge: only x1 grows, past the full bounds.
    try doc.add(gpa, .{ .arrow = .{ .tail = .{ .x = 100, .y = 50 }, .head = .{ .x = 300, .y = 50 }, .width = 6, .color = red } });
    const c = canvas(ctx, &doc, 200, 100);
    const full = draw.bounds(ctx, doc.items.items[1], .identity, .{});
    try std.testing.expectEqual(@as(i32, 0), c.x0);
    try std.testing.expectEqual(@as(i32, 0), c.y0);
    try std.testing.expectEqual(@as(i32, 100), c.y1);
    try std.testing.expectEqual(full.x1 + pad, c.x1);
    try std.testing.expect(c.contains(full));
    // Undo shrinks it back.
    _ = try doc.undo(gpa);
    try std.testing.expectEqual(img, canvas(ctx, &doc, 200, 100));
    // Far away: the reach limit bounds the canvas.
    const far = Annotation{ .arrow = .{ .tail = .{ .x = 100, .y = 50 }, .head = .{ .x = -1e6, .y = 50 }, .width = 6, .color = red } };
    try std.testing.expect(fits(ctx, img, far));
    try doc.add(gpa, far);
    try std.testing.expectEqual(@as(i32, -min_reach), canvas(ctx, &doc, 200, 100).x0);
    try std.testing.expect(!fits(ctx, img, .{ .arrow = .{ .tail = .{ .x = 1e5, .y = 50 }, .head = .{ .x = 1e5 + 50, .y = 50 }, .width = 6, .color = red } }));
    try std.testing.expect(!reachable(img, .{ .x = 0, .y = -3000 }));
}
