//! Stairs path: the stroke of a stairs arrow (an elbow connector). From the
//! tail it runs along the dominant axis to the midpoint, turns 90 degrees,
//! runs along the other axis, turns again and ends along the dominant axis
//! into the head (horizontal-vertical-horizontal when |dx| >= |dy|). The two
//! corners are quarter circles. `Path` is a signed distance shape (see
//! sdf.zig) of the stroke without the head; draw.zig adds the head.
const std = @import("std");
const geom = @import("geom.zig");

const Vec2 = geom.Vec2;
const Bounds = geom.Bounds;

/// The polyline of a stairs arrow from tail `t` to head `h`.
pub const Route = struct {
    t: Vec2,
    /// The two corners.
    c1: Vec2,
    c2: Vec2,
    h: Vec2,
    /// Direction of the first and the last segment (unit, axis aligned).
    u: Vec2,
    /// Direction of the middle segment (unit, axis aligned, across `u`).
    v: Vec2,
    /// Length of the first segment (and of the last one).
    run: f32,
    /// Length of the middle segment (0: a straight line).
    rise: f32,

    pub fn of(t: Vec2, h: Vec2) Route {
        const d = h.sub(t);
        const horizontal = @abs(d.x) >= @abs(d.y);
        const along = if (horizontal) d.x else d.y;
        const across = if (horizontal) d.y else d.x;
        const su: f32 = if (along < 0) -1 else 1;
        const sv: f32 = if (across < 0) -1 else 1;
        const u = if (horizontal) Vec2.init(su, 0) else Vec2.init(0, su);
        const v = if (horizontal) Vec2.init(0, sv) else Vec2.init(sv, 0);
        const run = @abs(along) * 0.5;
        const rise = @abs(across);
        const c1 = t.add(u.scale(run));
        return .{ .t = t, .c1 = c1, .c2 = c1.add(v.scale(rise)), .h = h, .u = u, .v = v, .run = run, .rise = rise };
    }
};

/// Corner radius (same unit as the stroke width) before `Path.init` clamps
/// it to the segments.
pub fn cornerRadius(width: f32) f32 {
    return 3 * width + 6;
}

/// Stroke of a route with round caps and round corners.
pub const Path = struct {
    t: Vec2,
    /// Corner k runs from a[k] (on the segment before) to b[k] (on the
    /// segment after), around the center k[k].
    a: [2]Vec2,
    b: [2]Vec2,
    k: [2]Vec2,
    /// End of the stroke on the last segment (under the head).
    end: Vec2,
    u: Vec2,
    v: Vec2,
    r: f32,
    /// Half the stroke width.
    hw: f32,

    /// The stroke stops `back` before the head point; the last `keep`
    /// (>= back) stays straight for the head. The corner radius is `r_pref`,
    /// or less where a segment is too short: a short middle segment gives
    /// an S curve, no middle segment a straight line. Needs keep <= run.
    pub fn init(rt: Route, back: f32, keep: f32, r_pref: f32, hw: f32) Path {
        const r = @max(0, @min(@min(r_pref, rt.run - keep), @min(rt.run, rt.rise * 0.5)));
        return .{
            .t = rt.t,
            .a = .{ rt.c1.sub(rt.u.scale(r)), rt.c2.sub(rt.v.scale(r)) },
            .b = .{ rt.c1.add(rt.v.scale(r)), rt.c2.add(rt.u.scale(r)) },
            .k = .{ rt.c1.sub(rt.u.scale(r)).add(rt.v.scale(r)), rt.c2.sub(rt.v.scale(r)).add(rt.u.scale(r)) },
            .end = rt.h.sub(rt.u.scale(back)),
            .u = rt.u,
            .v = rt.v,
            .r = r,
            .hw = hw,
        };
    }

    pub fn dist(s: Path, p: Vec2) f32 {
        // Segments (axis aligned): one square root for the three.
        const d2 = @min(segDist2(p, s.t, s.a[0]), @min(segDist2(p, s.b[0], s.a[1]), segDist2(p, s.b[1], s.end)));
        var d = @sqrt(d2);
        // Arcs: only inside the quarter of each corner; outside it the
        // nearest arc point is an end, which a segment already holds.
        const q0 = p.sub(s.k[0]);
        if (q0.dot(s.u) >= 0 and q0.dot(s.v) <= 0) d = @min(d, @abs(q0.len() - s.r));
        const q1 = p.sub(s.k[1]);
        if (q1.dot(s.v) >= 0 and q1.dot(s.u) <= 0) d = @min(d, @abs(q1.len() - s.r));
        return d - s.hw;
    }

    /// The corners stay inside the box of the polyline.
    pub fn bounds(s: Path) Bounds {
        const c1 = s.a[0].add(s.u.scale(s.r));
        const c2 = s.a[1].add(s.v.scale(s.r));
        return (Bounds{ .min = s.t.min(c1).min(c2).min(s.end), .max = s.t.max(c1).max(c2).max(s.end) }).expand(s.hw);
    }

    /// Boxes that hold the stroke (grown by `grow`): the first segment with
    /// the first half of corner 1, the middle segment with the other
    /// halves, the last segment with the last half of corner 2. A 45 degree
    /// arc between two axis points stays in the box of its ends, so each
    /// box is only 0.3 r wider than its segment. For tight repaints: few
    /// boxes, little waste.
    pub fn pieces(s: Path, grow: f32) [3]Bounds {
        const m0 = s.k[0].add(s.u.sub(s.v).scale(s.r * std.math.sqrt1_2));
        const m1 = s.k[1].add(s.v.sub(s.u).scale(s.r * std.math.sqrt1_2));
        const pts = [_][2]Vec2{ .{ s.t, m0 }, .{ m0, m1 }, .{ m1, s.end } };
        var out: [3]Bounds = undefined;
        for (pts, 0..) |q, i| out[i] = (Bounds{ .min = q[0].min(q[1]), .max = q[0].max(q[1]) }).expand(s.hw + grow);
        return out;
    }
};

/// Squared distance from `p` to the segment a..b, which is axis aligned:
/// the distance to a box of zero width, no division.
fn segDist2(p: Vec2, a: Vec2, b: Vec2) f32 {
    const lo = a.min(b);
    const hi = a.max(b);
    const dx = @max(@max(lo.x - p.x, p.x - hi.x), 0);
    const dy = @max(@max(lo.y - p.y, p.y - hi.y), 0);
    return dx * dx + dy * dy;
}

test "route: the dominant axis first and last, the turn at the midpoint" {
    const rt = Route.of(.{ .x = 0, .y = 0 }, .{ .x = 100, .y = 40 });
    try std.testing.expectEqual(Vec2.init(1, 0), rt.u);
    try std.testing.expectEqual(Vec2.init(0, 1), rt.v);
    try std.testing.expectEqual(Vec2.init(50, 0), rt.c1);
    try std.testing.expectEqual(Vec2.init(50, 40), rt.c2);
    // Steeper than 45 degrees, to the up-left: vertical, horizontal, vertical.
    const up = Route.of(.{ .x = 0, .y = 0 }, .{ .x = -30, .y = -100 });
    try std.testing.expectEqual(Vec2.init(0, -1), up.u);
    try std.testing.expectEqual(Vec2.init(-1, 0), up.v);
    try std.testing.expectEqual(Vec2.init(0, -50), up.c1);
    try std.testing.expectEqual(Vec2.init(-30, -50), up.c2);
    try std.testing.expectEqual(@as(f32, 30), up.rise);
}

test "path: the stroke follows the segments and the round corners" {
    const rt = Route.of(.{ .x = 0, .y = 0 }, .{ .x = 200, .y = 100 });
    const s = Path.init(rt, 10, 20, 30, 2);
    try std.testing.expectEqual(@as(f32, 30), s.r);
    try std.testing.expectApproxEqAbs(@as(f32, -2), s.dist(.{ .x = 40, .y = 0 }), 1e-4); // first segment
    try std.testing.expectApproxEqAbs(@as(f32, -2), s.dist(.{ .x = 100, .y = 50 }), 1e-4); // middle
    try std.testing.expectApproxEqAbs(@as(f32, -2), s.dist(.{ .x = 160, .y = 100 }), 1e-4); // last
    // The corner is cut: the sharp corner point is off the stroke, the arc
    // middle (30 * (1 - 1/sqrt 2) from both lines) is on it.
    try std.testing.expect(s.dist(.{ .x = 100, .y = 0 }) > 5);
    const m: f32 = 30.0 * (1.0 - 1.0 / @sqrt(2.0));
    try std.testing.expectApproxEqAbs(@as(f32, -2), s.dist(.{ .x = 100 - m, .y = m }), 1e-3);
    // The stroke stops `back` before the head point.
    try std.testing.expectApproxEqAbs(@as(f32, 8), s.dist(.{ .x = 200, .y = 100 }), 1e-4);
    // Bounds: the polyline box, grown by the half width.
    const b = s.bounds();
    try std.testing.expectEqual(Vec2.init(-2, -2), b.min);
    try std.testing.expectEqual(Vec2.init(192, 102), b.max);
}

test "path: short segments shrink the corners; no rise is a straight line" {
    // A rise of 10: two corners of 5, an S curve.
    const s = Path.init(Route.of(.{ .x = 0, .y = 0 }, .{ .x = 200, .y = 10 }), 10, 20, 30, 2);
    try std.testing.expectEqual(@as(f32, 5), s.r);
    try std.testing.expect(s.dist(.{ .x = 100, .y = 5 }) < 0);
    // A short run: the last segment keeps room for the head.
    const short = Path.init(Route.of(.{ .x = 0, .y = 0 }, .{ .x = 60, .y = 50 }), 12, 20, 30, 2);
    try std.testing.expectEqual(@as(f32, 10), short.r);
    // No rise: exactly the straight stroke, for any point.
    const flat = Path.init(Route.of(.{ .x = 0, .y = 0 }, .{ .x = 200, .y = 0 }), 10, 20, 30, 2);
    try std.testing.expectEqual(@as(f32, 0), flat.r);
    for ([_]Vec2{ .{ .x = 100, .y = 0 }, .{ .x = 100, .y = 7 }, .{ .x = -5, .y = 3 }, .{ .x = 195, .y = -4 } }) |p| {
        const straight = @import("sdf.zig").Capsule{ .a = .{ .x = 0, .y = 0 }, .b = .{ .x = 190, .y = 0 }, .r = 2 };
        try std.testing.expectApproxEqAbs(straight.dist(p), flat.dist(p), 1e-4);
    }
}

test "path: pieces hold every point of the stroke" {
    const s = Path.init(Route.of(.{ .x = 10, .y = 300 }, .{ .x = 90, .y = 20 }), 8, 16, 40, 3);
    const ps = s.pieces(0.5);
    var y: f32 = 0;
    while (y < 320) : (y += 1) {
        var x: f32 = 0;
        while (x < 100) : (x += 1) {
            const p = Vec2.init(x + 0.5, y + 0.5);
            if (s.dist(p) > 0) continue;
            var in = false;
            for (ps) |b| in = in or (p.x >= b.min.x and p.x <= b.max.x and p.y >= b.min.y and p.y <= b.max.y);
            try std.testing.expect(in);
        }
    }
}
