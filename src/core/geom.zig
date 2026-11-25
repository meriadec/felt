//! Geometry: float vectors, integer pixel rectangles, and the similarity
//! transform that maps image coordinates to screen coordinates.
const std = @import("std");

pub const Vec2 = struct {
    x: f32,
    y: f32,

    pub const zero = Vec2{ .x = 0, .y = 0 };

    pub fn init(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }
    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
    pub fn scale(a: Vec2, s: f32) Vec2 {
        return .{ .x = a.x * s, .y = a.y * s };
    }
    pub fn dot(a: Vec2, b: Vec2) f32 {
        return a.x * b.x + a.y * b.y;
    }
    pub fn cross(a: Vec2, b: Vec2) f32 {
        return a.x * b.y - a.y * b.x;
    }
    pub fn len(a: Vec2) f32 {
        return @sqrt(a.dot(a));
    }
    pub fn dist(a: Vec2, b: Vec2) f32 {
        return a.sub(b).len();
    }
    /// Unit vector, or (1, 0) for a zero vector.
    pub fn normalize(a: Vec2) Vec2 {
        const l = a.len();
        return if (l < 1e-6) .{ .x = 1, .y = 0 } else a.scale(1.0 / l);
    }
    /// Rotated 90 degrees.
    pub fn perp(a: Vec2) Vec2 {
        return .{ .x = -a.y, .y = a.x };
    }
    pub fn min(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y) };
    }
    pub fn max(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = @max(a.x, b.x), .y = @max(a.y, b.y) };
    }
    pub fn abs(a: Vec2) Vec2 {
        return .{ .x = @abs(a.x), .y = @abs(a.y) };
    }
};

/// Float bounds (min corner, max corner).
pub const Bounds = struct {
    min: Vec2,
    max: Vec2,

    pub fn unite(a: Bounds, b: Bounds) Bounds {
        return .{ .min = a.min.min(b.min), .max = a.max.max(b.max) };
    }
    pub fn expand(a: Bounds, m: f32) Bounds {
        return .{ .min = a.min.sub(.{ .x = m, .y = m }), .max = a.max.add(.{ .x = m, .y = m }) };
    }
    pub fn offset(a: Bounds, d: Vec2) Bounds {
        return .{ .min = a.min.add(d), .max = a.max.add(d) };
    }
    /// Smallest pixel rectangle that covers the bounds.
    pub fn toRect(a: Bounds) Rect {
        const lim = 1e7;
        return .{
            .x0 = @intFromFloat(@floor(std.math.clamp(a.min.x, -lim, lim))),
            .y0 = @intFromFloat(@floor(std.math.clamp(a.min.y, -lim, lim))),
            .x1 = @intFromFloat(@ceil(std.math.clamp(a.max.x, -lim, lim))),
            .y1 = @intFromFloat(@ceil(std.math.clamp(a.max.y, -lim, lim))),
        };
    }
};

/// Pixel rectangle, half-open: [x0, x1) x [y0, y1).
pub const Rect = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    pub const empty = Rect{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };

    pub fn fromSize(x: i32, y: i32, w: i32, h: i32) Rect {
        return .{ .x0 = x, .y0 = y, .x1 = x + w, .y1 = y + h };
    }
    pub fn width(r: Rect) i32 {
        return r.x1 - r.x0;
    }
    pub fn height(r: Rect) i32 {
        return r.y1 - r.y0;
    }
    pub fn isEmpty(r: Rect) bool {
        return r.x1 <= r.x0 or r.y1 <= r.y0;
    }
    pub fn area(r: Rect) u64 {
        return if (r.isEmpty()) 0 else @as(u64, @intCast(r.width())) * @as(u64, @intCast(r.height()));
    }
    pub fn intersect(a: Rect, b: Rect) Rect {
        const r = Rect{ .x0 = @max(a.x0, b.x0), .y0 = @max(a.y0, b.y0), .x1 = @min(a.x1, b.x1), .y1 = @min(a.y1, b.y1) };
        return if (r.isEmpty()) empty else r;
    }
    pub fn intersects(a: Rect, b: Rect) bool {
        return !a.intersect(b).isEmpty();
    }
    pub fn unite(a: Rect, b: Rect) Rect {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        return .{ .x0 = @min(a.x0, b.x0), .y0 = @min(a.y0, b.y0), .x1 = @max(a.x1, b.x1), .y1 = @max(a.y1, b.y1) };
    }
    pub fn expand(r: Rect, n: i32) Rect {
        if (r.isEmpty()) return r;
        return .{ .x0 = r.x0 - n, .y0 = r.y0 - n, .x1 = r.x1 + n, .y1 = r.y1 + n };
    }
    pub fn offset(r: Rect, dx: i32, dy: i32) Rect {
        return .{ .x0 = r.x0 + dx, .y0 = r.y0 + dy, .x1 = r.x1 + dx, .y1 = r.y1 + dy };
    }
    pub fn contains(a: Rect, b: Rect) bool {
        return b.isEmpty() or (b.x0 >= a.x0 and b.y0 >= a.y0 and b.x1 <= a.x1 and b.y1 <= a.y1);
    }
    /// The parts of `a` outside `b`: top, bottom, left, right bands (some empty).
    pub fn minus(a: Rect, b: Rect) [4]Rect {
        if (a.isEmpty()) return .{ empty, empty, empty, empty };
        if (!a.intersects(b)) return .{ a, empty, empty, empty };
        const my0 = @max(a.y0, b.y0);
        const my1 = @min(a.y1, b.y1);
        const parts = [4]Rect{
            .{ .x0 = a.x0, .y0 = a.y0, .x1 = a.x1, .y1 = my0 },
            .{ .x0 = a.x0, .y0 = my1, .x1 = a.x1, .y1 = a.y1 },
            .{ .x0 = a.x0, .y0 = my0, .x1 = @max(a.x0, b.x0), .y1 = my1 },
            .{ .x0 = @min(a.x1, b.x1), .y0 = my0, .x1 = a.x1, .y1 = my1 },
        };
        var out: [4]Rect = undefined;
        for (parts, 0..) |p, i| out[i] = if (p.isEmpty()) empty else p;
        return out;
    }
    pub fn toBounds(r: Rect) Bounds {
        return .{
            .min = .{ .x = @floatFromInt(r.x0), .y = @floatFromInt(r.y0) },
            .max = .{ .x = @floatFromInt(r.x1), .y = @floatFromInt(r.y1) },
        };
    }
};

/// Similarity transform: p' = p * scale + offset.
pub const Xform = struct {
    scale: f32 = 1,
    offset: Vec2 = Vec2.zero,

    pub const identity = Xform{};

    pub fn apply(t: Xform, p: Vec2) Vec2 {
        // Snap the scaled point to 1/2048 px: the sum with the whole pixel
        // offset is then exact, so a pan (a scroll of the scene) and a full
        // repaint rasterize the same shapes to the same pixels.
        const q = p.scale(t.scale);
        return .{ .x = snap(q.x) + t.offset.x, .y = snap(q.y) + t.offset.y };
    }
    fn snap(v: f32) f32 {
        return @round(v * 2048) / 2048;
    }
    pub fn invert(t: Xform, p: Vec2) Vec2 {
        return p.sub(t.offset).scale(1.0 / t.scale);
    }
    pub fn len(t: Xform, l: f32) f32 {
        return l * t.scale;
    }
};

test "rect ops" {
    const a = Rect.fromSize(0, 0, 10, 10);
    const b = Rect.fromSize(5, 5, 10, 10);
    try std.testing.expectEqual(Rect{ .x0 = 5, .y0 = 5, .x1 = 10, .y1 = 10 }, a.intersect(b));
    try std.testing.expectEqual(Rect{ .x0 = 0, .y0 = 0, .x1 = 15, .y1 = 15 }, a.unite(b));
    try std.testing.expect(a.intersect(Rect.fromSize(20, 20, 1, 1)).isEmpty());
}

test "rect minus" {
    const a = Rect.fromSize(0, 0, 10, 10);
    const parts = a.minus(Rect.fromSize(2, 3, 4, 4));
    var sum: u64 = 0;
    for (parts) |p| sum += p.area();
    try std.testing.expectEqual(@as(u64, 100 - 16), sum);
    try std.testing.expectEqual(a, a.minus(Rect.fromSize(20, 0, 5, 5))[0]);
    for (a.minus(Rect.fromSize(-5, -5, 30, 30))) |p| try std.testing.expect(p.isEmpty());
    try std.testing.expectEqual(Rect{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 5 }, a.minus(Rect.fromSize(-1, 5, 12, 10))[0]);
}

test "xform round trip" {
    const t = Xform{ .scale = 0.5, .offset = .{ .x = 10, .y = 20 } };
    const p = Vec2.init(100, 40);
    const q = t.invert(t.apply(p));
    try std.testing.expectApproxEqAbs(p.x, q.x, 1e-4);
    try std.testing.expectApproxEqAbs(p.y, q.y, 1e-4);
}

test "xform: a whole pixel pan moves every point by exactly that much" {
    // A pan scrolls the scene; a full repaint must give the same pixels.
    const s: f32 = 0.4444444;
    var i: i32 = 0;
    while (i < 500) : (i += 1) {
        const p = Vec2.init(@as(f32, @floatFromInt(i)) * 1.37 + 0.31, @as(f32, @floatFromInt(i)) * 0.83);
        const a = (Xform{ .scale = s, .offset = .{ .x = 37, .y = -12 } }).apply(p);
        const b = (Xform{ .scale = s, .offset = .{ .x = 37 + 51, .y = -12 + 33 } }).apply(p);
        try std.testing.expectEqual(a.x + 51, b.x);
        try std.testing.expectEqual(a.y + 33, b.y);
    }
}
