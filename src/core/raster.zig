//! Anti-aliased rasterizer for signed distance shapes (see sdf.zig).
//! Works in 8x8 tiles: a tile far outside the shape is skipped, a tile deep
//! inside is filled without per-pixel math. Edge coverage = clamp(0.5 - d/soft).
const std = @import("std");
const geom = @import("geom.zig");
const Canvas = @import("canvas.zig").Canvas;
const Color = @import("color.zig").Color;

const Vec2 = geom.Vec2;
const Rect = geom.Rect;

pub const Paint = union(enum) {
    /// Source-over blend.
    solid: Color,
    /// Multiply blend (highlighter); alpha sets strength.
    multiply: Color,
};

pub const Options = struct {
    /// Shift the shape (for drop shadows).
    offset: Vec2 = Vec2.zero,
    /// Edge ramp width in pixels: 1 = crisp anti-aliasing, more = soft shadow.
    soft: f32 = 1,
};

const tile = 8;

/// Fill `shape` on `canvas`, writing only inside `clip`.
pub fn fill(canvas: *Canvas, clip: Rect, shape: anytype, paint: Paint, opts: Options) void {
    const margin = opts.soft * 0.5 + 1;
    const area = shape.bounds().expand(margin).offset(opts.offset).toRect()
        .intersect(clip).intersect(canvas.bounds());
    if (area.isEmpty()) return;

    const inv_soft = 1.0 / opts.soft;
    const half_soft = opts.soft * 0.5;
    const tile_r: f32 = @as(f32, tile) * 0.7072; // half diagonal, conservative
    const off = opts.offset;

    var ty = area.y0;
    while (ty < area.y1) : (ty += tile) {
        const ty1 = @min(ty + tile, area.y1);
        var tx = area.x0;
        while (tx < area.x1) : (tx += tile) {
            const tx1 = @min(tx + tile, area.x1);
            const center = Vec2.init(
                @as(f32, @floatFromInt(tx + tx1)) * 0.5 - off.x,
                @as(f32, @floatFromInt(ty + ty1)) * 0.5 - off.y,
            );
            const dc = shape.dist(center);
            if (dc - tile_r >= half_soft) continue; // fully outside
            const inside = dc + tile_r <= -half_soft;
            var y = ty;
            while (y < ty1) : (y += 1) {
                const base = @as(usize, @intCast(y)) * canvas.width;
                const py = @as(f32, @floatFromInt(y)) + 0.5 - off.y;
                var x = tx;
                while (x < tx1) : (x += 1) {
                    const i = base + @as(usize, @intCast(x));
                    var cov: u32 = 255;
                    if (!inside) {
                        const d = shape.dist(.{ .x = @as(f32, @floatFromInt(x)) + 0.5 - off.x, .y = py });
                        const k = std.math.clamp(0.5 - d * inv_soft, 0, 1);
                        cov = @intFromFloat(k * 255 + 0.5);
                        if (cov == 0) continue;
                    }
                    switch (paint) {
                        .solid => |c| canvas.blendAt(i, c, cov),
                        .multiply => |c| canvas.multiplyAt(i, c, (cov * c.a + 127) / 255),
                    }
                }
            }
        }
    }
}

test "disc coverage is anti-aliased and symmetric" {
    const gpa = std.testing.allocator;
    var cv = try Canvas.init(gpa, 20, 20);
    defer cv.deinit(gpa);
    cv.fill(.{ .r = 0, .g = 0, .b = 0 });
    const sdf = @import("sdf.zig");
    fill(&cv, cv.bounds(), sdf.Disc{ .c = .{ .x = 10, .y = 10 }, .r = 5 }, .{ .solid = .{ .r = 255, .g = 255, .b = 255 } }, .{});
    try std.testing.expectEqual(@as(u32, 0xffffffff), cv.at(10, 10));
    try std.testing.expectEqual(@as(u32, 0xff000000), cv.at(0, 0));
    const edge = cv.at(14, 10) & 0xff;
    try std.testing.expect(edge > 0 and edge <= 255);
    try std.testing.expectEqual(cv.at(5, 10), cv.at(14, 10));
}
