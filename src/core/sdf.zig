//! Signed distance shapes for the rasterizer. Each shape has
//! `dist(p) f32` (negative inside, 1-Lipschitz) and `bounds() Bounds`.
//! Coordinates are in target pixels; pixel centers are at +0.5.
const std = @import("std");
const geom = @import("geom.zig");

const Vec2 = geom.Vec2;
const Bounds = geom.Bounds;

/// Thick segment with round caps.
pub const Capsule = struct {
    a: Vec2,
    b: Vec2,
    r: f32,

    pub fn dist(s: Capsule, p: Vec2) f32 {
        const pa = p.sub(s.a);
        const ba = s.b.sub(s.a);
        const l2 = ba.dot(ba);
        const h = if (l2 < 1e-9) 0 else std.math.clamp(pa.dot(ba) / l2, 0, 1);
        return pa.sub(ba.scale(h)).len() - s.r;
    }
    pub fn bounds(s: Capsule) Bounds {
        return (Bounds{ .min = s.a.min(s.b), .max = s.a.max(s.b) }).expand(s.r);
    }
};

pub const Disc = struct {
    c: Vec2,
    r: f32,

    pub fn dist(s: Disc, p: Vec2) f32 {
        return p.dist(s.c) - s.r;
    }
    pub fn bounds(s: Disc) Bounds {
        return (Bounds{ .min = s.c, .max = s.c }).expand(s.r);
    }
};

/// Filled triangle (exact distance, any winding).
pub const Triangle = struct {
    a: Vec2,
    b: Vec2,
    c: Vec2,

    pub fn dist(s: Triangle, p: Vec2) f32 {
        const e0 = s.b.sub(s.a);
        const e1 = s.c.sub(s.b);
        const e2 = s.a.sub(s.c);
        const v0 = p.sub(s.a);
        const v1 = p.sub(s.b);
        const v2 = p.sub(s.c);
        const pq0 = v0.sub(e0.scale(std.math.clamp(v0.dot(e0) / e0.dot(e0), 0, 1)));
        const pq1 = v1.sub(e1.scale(std.math.clamp(v1.dot(e1) / e1.dot(e1), 0, 1)));
        const pq2 = v2.sub(e2.scale(std.math.clamp(v2.dot(e2) / e2.dot(e2), 0, 1)));
        const sgn: f32 = if (e0.cross(e2) < 0) -1 else 1;
        const d0 = Vec2.init(pq0.dot(pq0), sgn * v0.cross(e0));
        const d1 = Vec2.init(pq1.dot(pq1), sgn * v1.cross(e1));
        const d2 = Vec2.init(pq2.dot(pq2), sgn * v2.cross(e2));
        const d = d0.min(d1).min(d2);
        return -@sqrt(d.x) * std.math.sign(d.y);
    }
    pub fn bounds(s: Triangle) Bounds {
        return .{ .min = s.a.min(s.b).min(s.c), .max = s.a.max(s.b).max(s.c) };
    }
};

/// Filled rectangle with rounded corners (radius 0 = sharp).
pub const RoundRect = struct {
    min: Vec2,
    max: Vec2,
    radius: f32 = 0,

    pub fn dist(s: RoundRect, p: Vec2) f32 {
        return boxDist(s.min, s.max, s.radius, p);
    }
    pub fn bounds(s: RoundRect) Bounds {
        return .{ .min = s.min, .max = s.max };
    }
};

/// Rectangle outline of width `w` centered on the edges.
pub const RectStroke = struct {
    min: Vec2,
    max: Vec2,
    w: f32,

    pub fn dist(s: RectStroke, p: Vec2) f32 {
        return @abs(boxDist(s.min, s.max, 0, p)) - s.w * 0.5;
    }
    pub fn bounds(s: RectStroke) Bounds {
        return (Bounds{ .min = s.min, .max = s.max }).expand(s.w * 0.5);
    }
};

fn boxDist(mn: Vec2, mx: Vec2, radius: f32, p: Vec2) f32 {
    const c = mn.add(mx).scale(0.5);
    const half = mx.sub(mn).scale(0.5);
    const r = @min(radius, @min(half.x, half.y));
    const q = p.sub(c).abs().sub(half).add(.{ .x = r, .y = r });
    const outside = q.max(Vec2.zero).len();
    return outside + @min(@max(q.x, q.y), 0) - r;
}

/// Union of two shapes (min distance): seamless, single blend.
pub fn Union(comptime A: type, comptime B: type) type {
    return struct {
        a: A,
        b: B,

        pub fn dist(s: @This(), p: Vec2) f32 {
            const da = s.a.dist(p);
            // Outside the bounds of `b`, the distance to them is a lower
            // bound of `b.dist`: skip `b` when it cannot be nearer (e.g. the
            // head of a long arrow, for pixels along the shaft).
            const bb = s.b.bounds();
            const lb = boxDist(bb.min, bb.max, 0, p);
            if (lb > 0 and lb >= da) return da;
            return @min(da, s.b.dist(p));
        }
        pub fn bounds(s: @This()) Bounds {
            return s.a.bounds().unite(s.b.bounds());
        }
    };
}

pub fn unite(a: anytype, b: anytype) Union(@TypeOf(a), @TypeOf(b)) {
    return .{ .a = a, .b = b };
}

/// `A` minus `B`. Exact inside, a lower bound outside: safe for tile culling.
pub fn Subtract(comptime A: type, comptime B: type) type {
    return struct {
        a: A,
        b: B,

        pub fn dist(s: @This(), p: Vec2) f32 {
            return @max(s.a.dist(p), -s.b.dist(p));
        }
        pub fn bounds(s: @This()) Bounds {
            return s.a.bounds();
        }
    };
}

/// Shape grown by `r` (positive = bigger), e.g. for outlines.
pub fn Grown(comptime S: type) type {
    return struct {
        s: S,
        r: f32,

        pub fn dist(g: @This(), p: Vec2) f32 {
            return g.s.dist(p) - g.r;
        }
        pub fn bounds(g: @This()) Bounds {
            return g.s.bounds().expand(@max(g.r, 0));
        }
    };
}

/// Outline of a shape: a band of width `w` centered on its edge.
pub fn Ring(comptime S: type) type {
    return struct {
        s: S,
        w: f32,

        pub fn dist(g: @This(), p: Vec2) f32 {
            return @abs(g.s.dist(p)) - g.w * 0.5;
        }
        pub fn bounds(g: @This()) Bounds {
            return g.s.bounds().expand(g.w * 0.5);
        }
    };
}

pub fn ring(s: anytype, w: f32) Ring(@TypeOf(s)) {
    return .{ .s = s, .w = w };
}

test "triangle sign" {
    const t = Triangle{ .a = .{ .x = 0, .y = 0 }, .b = .{ .x = 10, .y = 0 }, .c = .{ .x = 0, .y = 10 } };
    try std.testing.expect(t.dist(.{ .x = 2, .y = 2 }) < 0);
    try std.testing.expectApproxEqAbs(@as(f32, 5), t.dist(.{ .x = -5, .y = 2 }), 1e-4);
    const t2 = Triangle{ .a = t.a, .b = t.c, .c = t.b }; // other winding
    try std.testing.expect(t2.dist(.{ .x = 2, .y = 2 }) < 0);
    try std.testing.expectApproxEqAbs(@as(f32, 5), t2.dist(.{ .x = -5, .y = 2 }), 1e-4);
}

test "box and capsule" {
    const b = RoundRect{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 10, .y = 10 } };
    try std.testing.expectApproxEqAbs(@as(f32, -5), b.dist(.{ .x = 5, .y = 5 }), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 3), b.dist(.{ .x = 13, .y = 5 }), 1e-4);
    const c = Capsule{ .a = .{ .x = 0, .y = 0 }, .b = .{ .x = 10, .y = 0 }, .r = 2 };
    try std.testing.expectApproxEqAbs(@as(f32, 1), c.dist(.{ .x = 5, .y = 3 }), 1e-4);
}
