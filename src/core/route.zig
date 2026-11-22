//! Route: auto-routing of stairs paths (stairs arrows and stairs callout
//! pointers) around the other annotations. A stairs path has two free
//! parameters (annotation.Elbow): where its middle segment turns, and, for
//! an arrow, which axis runs first. `best` tries a fixed set of elbows and
//! keeps the cheapest: a crossing with the path of another annotation costs
//! most, then running along one closer than about two stroke widths or
//! passing that close to its end or corner (a near touch), then running
//! through a label box (text, callout box, number), then the
//! distance from the default elbow (the midpoint, the dominant axis first).
//! With nothing around, a path keeps the default look. Every candidate path
//! stays in the box of its two ends, so only what crosses that box counts.
//! The router is pure: the editor calls it while a path is drawn or moved,
//! and on a commit for the paths around the change (`settle`).
const std = @import("std");
const geom = @import("geom.zig");
const draw = @import("draw.zig");
const ann = @import("annotation.zig");

const Vec2 = geom.Vec2;
const Bounds = geom.Bounds;
const Annotation = ann.Annotation;

/// Cost of one crossing with another path.
pub const cross_cost: f32 = 1000;
/// Cost per px of a run along another path, at no gap (less as the gap
/// grows, none at `nearGap`).
pub const near_cost: f32 = 3;
/// Cost of an end or corner of one path nearer than `nearGap` to the
/// other (less as the distance grows): a near touch.
pub const touch_cost: f32 = 100;
/// Cost per px of path inside a label box.
pub const box_cost: f32 = 2;
/// Cost per px that the middle segment moves off the midpoint.
pub const shift_cost: f32 = 0.2;
/// Cost of running along the minor axis first.
pub const flip_cost: f32 = 200;
/// Turn positions tried per orientation (plus the midpoint).
pub const samples = 48;

/// A straight piece of a path (image px) and the stroke width of its path.
pub const Seg = struct { a: Vec2, b: Vec2, w: f32 };

/// Centre distance under which two parallel strokes of widths `wa` and
/// `wb` look crowded: about two stroke widths of space between them.
pub fn nearGap(wa: f32, wb: f32) f32 {
    return 1.5 * (wa + wb);
}

/// The other annotations' paths and label boxes that cross a region.
pub const Obstacles = struct {
    pub const max_segs = 256;
    pub const max_boxes = 64;
    segs: [max_segs]Seg = undefined,
    n_segs: usize = 0,
    boxes: [max_boxes]Bounds = undefined,
    n_boxes: usize = 0,

    /// Collect the paths and label boxes of `items` (all but `skip`) that
    /// touch `region`. Boxes that hold `ends` (the routed path's tail or
    /// head: it starts on them or points at them) do not count. Past the
    /// buffer sizes, the rest is left out.
    pub fn collect(ctx: draw.Ctx, items: []const Annotation, skip: ?usize, region: Bounds, ends: [2]Vec2) Obstacles {
        var o = Obstacles{};
        for (items, 0..) |a, i| {
            if (skip != null and skip.? == i) continue;
            o.addPath(a, region);
            if (draw.labelBox(ctx, a)) |b| {
                if (!overlaps(b, region) or contains(b, ends[0]) or contains(b, ends[1])) continue;
                if (o.n_boxes < max_boxes) {
                    o.boxes[o.n_boxes] = b;
                    o.n_boxes += 1;
                }
            }
        }
        return o;
    }

    fn addPath(o: *Obstacles, a: Annotation, region: Bounds) void {
        const ar = switch (a) {
            .arrow => |x| x,
            .callout => |c| draw.calloutPointer(c) orelse return,
            else => return,
        };
        if (draw.stairsPlan(ar, .identity)) |p| {
            const pts = [4]Vec2{ p.rt.t, p.rt.c1, p.rt.c2, p.rt.h };
            for (0..3) |k| o.addSeg(.{ .a = pts[k], .b = pts[k + 1], .w = ar.width }, region);
        } else o.addSeg(.{ .a = ar.tail, .b = ar.head, .w = ar.width }, region);
    }

    fn addSeg(o: *Obstacles, s: Seg, region: Bounds) void {
        if (!overlaps(segBounds(s.a, s.b), region) or o.n_segs == max_segs) return;
        o.segs[o.n_segs] = s;
        o.n_segs += 1;
    }

    pub fn empty(o: *const Obstacles) bool {
        return o.n_segs == 0 and o.n_boxes == 0;
    }

    /// Cost of the polyline `pts` with stroke width `w` among the obstacles.
    pub fn cost(o: *const Obstacles, pts: []const Vec2, w: f32) f32 {
        const ends = [2]Vec2{ pts[0], pts[pts.len - 1] };
        var c: f32 = 0;
        for (pts[0 .. pts.len - 1], pts[1..]) |a, b| {
            if (a.dist(b) < 1e-3) continue;
            const sb = segBounds(a, b);
            for (o.segs[0..o.n_segs]) |q| {
                const g = nearGap(w, q.w);
                if (!overlaps(sb.expand(g), segBounds(q.a, q.b))) continue;
                if (crosses(a, b, q.a, q.b)) {
                    c += cross_cost;
                } else if (!sharesEnd(a, b, q.a, q.b, ends)) {
                    c += near_cost * nearLength(a, b, q.a, q.b, g);
                    c += touch_cost * (closeness(q.a, a, b, g) + closeness(q.b, a, b, g) + closeness(a, q.a, q.b, g) + closeness(b, q.a, q.b, g));
                }
            }
            // A stroke width of space around a box: no grazing.
            for (o.boxes[0..o.n_boxes]) |bx| c += box_cost * lengthInside(a, b, bx.expand(w * 1.5));
        }
        return c;
    }
};

/// The annotation with the elbow of its stairs path chosen by the router
/// among the other `items` (`skip`: its own index, if it is one of them).
/// Unchanged when it has no stairs path or its elbow is pinned. Candidates
/// go in a fixed order and only a strictly lower cost wins, so the choice
/// is deterministic; the default elbow goes first.
pub fn best(ctx: draw.Ctx, items: []const Annotation, skip: ?usize, a: Annotation) Annotation {
    const ar0 = draw.stairsArrow(a) orelse return a;
    if (ar0.elbow.pinned) return a;
    var ar = ar0;
    ar.elbow = .{};
    const base = draw.stairsPlan(ar, .identity) orelse return a;
    const region = (Bounds{ .min = ar.tail.min(ar.head), .max = ar.tail.max(ar.head) }).expand(nearGap(ar.width, 4 * ar.width));
    const obs = Obstacles.collect(ctx, items, skip, region, .{ ar.tail, ar.head });
    var elbow = ann.Elbow{};
    if (!obs.empty()) {
        var best_cost = candidateCost(&obs, ar, base);
        for ([_]bool{ false, true }) |flip| {
            if (flip and a != .arrow) break; // a callout pointer leaves across its box side
            const range = draw.elbowRange(ar, flip) orelse continue;
            for (0..samples + 1) |k| {
                const f: f32 = @floatFromInt(k);
                const e = ann.Elbow{ .at = range[0] + (range[1] - range[0]) * f / samples, .flip = flip };
                if (!flip and e.at == 0.5) continue; // the default, done
                ar.elbow = e;
                const p = draw.stairsPlan(ar, .identity) orelse continue;
                const c = candidateCost(&obs, ar, p);
                if (c < best_cost) {
                    best_cost = c;
                    elbow = e;
                }
            }
        }
    }
    var out = a;
    switch (out) {
        .arrow => |*x| x.elbow = elbow,
        .callout => |*x| x.elbow = elbow,
        else => unreachable,
    }
    return out;
}

/// Cost of the path of `ar` (plan `p`): the obstacles, the shift of the
/// middle segment off the midpoint, a flip.
fn candidateCost(o: *const Obstacles, ar: ann.Arrow, p: draw.StairsPlan) f32 {
    const pts = [4]Vec2{ p.rt.t, p.rt.c1, p.rt.c2, p.rt.h };
    const shift = @abs(ar.elbow.at - 0.5) * p.rt.span() * shift_cost;
    return o.cost(&pts, ar.width) + shift + (if (p.flip) flip_cost else 0);
}

/// Most annotations `settle` re-routes at once.
pub const max_settle = 64;

/// An annotation `settle` re-routed, and its geometry before.
pub const Rerouted = struct { index: usize, before: Annotation };

/// Re-route the auto stairs paths of `items` near `region` (the old and
/// new bounds of a change, image px), in creation order, twice: a path
/// that moved out of the way can let an earlier one settle back. Writes
/// the new geometry in `items` and what changed in `changed` (each index
/// once, with its geometry from before the first pass); returns how many.
pub fn settle(ctx: draw.Ctx, items: []Annotation, region: Bounds, changed: *[max_settle]Rerouted) usize {
    var near: [max_settle]usize = undefined;
    var n_near: usize = 0;
    for (items, 0..) |a, i| {
        const ar = draw.stairsArrow(a) orelse continue;
        if (ar.elbow.pinned or n_near == max_settle) continue;
        const b = (Bounds{ .min = ar.tail.min(ar.head), .max = ar.tail.max(ar.head) }).expand(nearGap(ar.width, 4 * ar.width));
        if (!overlaps(b, region)) continue;
        near[n_near] = i;
        n_near += 1;
    }
    var n: usize = 0;
    for (0..2) |_| {
        for (near[0..n_near]) |i| {
            const r = best(ctx, items, i, items[i]);
            if (std.meta.eql(r, items[i])) continue;
            const seen = for (changed[0..n]) |c| {
                if (c.index == i) break true;
            } else false;
            if (!seen) {
                changed[n] = .{ .index = i, .before = items[i] };
                n += 1;
            }
            items[i] = r;
        }
    }
    return n;
}

// ---- geometry ------------------------------------------------------------

fn segBounds(a: Vec2, b: Vec2) Bounds {
    return .{ .min = a.min(b), .max = a.max(b) };
}

fn overlaps(a: Bounds, b: Bounds) bool {
    return a.min.x <= b.max.x and b.min.x <= a.max.x and a.min.y <= b.max.y and b.min.y <= a.max.y;
}

fn contains(b: Bounds, p: Vec2) bool {
    return p.x >= b.min.x and p.x <= b.max.x and p.y >= b.min.y and p.y <= b.max.y;
}

/// The segments a0..a1 and b0..b1 cross: each one's ends lie strictly on
/// both sides of the other. Touching ends and collinear runs do not count
/// (a run along is `nearLength`).
pub fn crosses(a0: Vec2, a1: Vec2, b0: Vec2, b1: Vec2) bool {
    const da = a1.sub(a0);
    const db = b1.sub(b0);
    const d1 = da.cross(b0.sub(a0));
    const d2 = da.cross(b1.sub(a0));
    const d3 = db.cross(a0.sub(b0));
    const d4 = db.cross(a1.sub(b0));
    return ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0));
}

/// The segment a0..a1 starts or ends where b0..b1 does, at one of the
/// routed path's `ends`: paths from (or to) one place share their first
/// stretch, that is no crowding. Two corners on one point are.
fn sharesEnd(a0: Vec2, a1: Vec2, b0: Vec2, b1: Vec2, ends: [2]Vec2) bool {
    const e = 0.5;
    for ([_]Vec2{ a0, a1 }) |p| {
        if (p.dist(ends[0]) >= e and p.dist(ends[1]) >= e) continue;
        if (p.dist(b0) < e or p.dist(b1) < e) return true;
    }
    return false;
}

/// How much of a0..a1 runs along b0..b1 (within 15 degrees) closer than
/// `g`, weighted by closeness: the length of the overlap times (1 - gap/g),
/// with the gap at the closer end of the overlap.
pub fn nearLength(a0: Vec2, a1: Vec2, b0: Vec2, b1: Vec2, g: f32) f32 {
    const la = a0.dist(a1);
    const lb = b0.dist(b1);
    if (la < 1e-3 or lb < 1e-3) return 0;
    const ua = a1.sub(a0).scale(1 / la);
    const ub = b1.sub(b0).scale(1 / lb);
    if (@abs(ua.cross(ub)) > 0.26) return 0;
    const s0 = b0.sub(a0).dot(ua);
    const s1 = b1.sub(a0).dot(ua);
    const lo = @max(0, @min(s0, s1));
    const hi = @min(la, @max(s0, s1));
    if (hi <= lo) return 0;
    // Offset of b across a at a place s along a (b is a line there).
    const e0 = ua.cross(b0.sub(a0));
    const e1 = ua.cross(b1.sub(a0));
    const ds = s1 - s0;
    const off = struct {
        fn at(s: f32, s_0: f32, d: f32, x0: f32, x1: f32) f32 {
            return if (@abs(d) < 1e-6) x0 else x0 + (x1 - x0) * (s - s_0) / d;
        }
    }.at;
    const gap = @min(@abs(off(lo, s0, ds, e0, e1)), @abs(off(hi, s0, ds, e0, e1)));
    if (gap >= g) return 0;
    return (hi - lo) * (1 - gap / g);
}

/// 1 when `p` is on the segment a..b, down to 0 at distance `g`.
pub fn closeness(p: Vec2, a: Vec2, b: Vec2, g: f32) f32 {
    const d = b.sub(a);
    const l2 = d.dot(d);
    const t = if (l2 < 1e-6) 0 else std.math.clamp(p.sub(a).dot(d) / l2, 0, 1);
    return @max(0, 1 - p.dist(a.add(d.scale(t))) / g);
}

/// Length of the segment a..b inside the box `bx`.
pub fn lengthInside(a: Vec2, b: Vec2, bx: Bounds) f32 {
    const d = b.sub(a);
    var t0: f32 = 0;
    var t1: f32 = 1;
    const ps = [4]f32{ -d.x, d.x, -d.y, d.y };
    const qs = [4]f32{ a.x - bx.min.x, bx.max.x - a.x, a.y - bx.min.y, bx.max.y - a.y };
    for (ps, qs) |p, q| {
        if (p == 0) {
            if (q < 0) return 0;
            continue;
        }
        const r = q / p;
        if (p < 0) t0 = @max(t0, r) else t1 = @min(t1, r);
        if (t0 > t1) return 0;
    }
    return (t1 - t0) * d.len();
}

// ---- tests -------------------------------------------------------------

const color = @import("color.zig");
const Font = @import("font.zig").Font;

fn v(x: f32, y: f32) Vec2 {
    return Vec2.init(x, y);
}

test "crossings: a proper crossing counts; touching ends and collinear runs do not" {
    try std.testing.expect(crosses(v(0, 0), v(10, 10), v(0, 10), v(10, 0)));
    try std.testing.expect(!crosses(v(0, 0), v(10, 0), v(10, 0), v(10, 10))); // a corner
    try std.testing.expect(!crosses(v(0, 0), v(10, 0), v(5, 0), v(5, 10))); // a T on the line
    try std.testing.expect(!crosses(v(0, 0), v(10, 0), v(5, 0), v(15, 0))); // collinear
    try std.testing.expect(!crosses(v(0, 0), v(10, 0), v(0, 1), v(10, 1))); // parallel
    try std.testing.expect(crosses(v(5, -5), v(5, 5), v(0, 0), v(10, 0)));
}

test "parallel gap: the overlap weighted by closeness; none past the gap or across" {
    // Collinear overlap of 5: full weight.
    try std.testing.expectApproxEqAbs(@as(f32, 5), nearLength(v(0, 0), v(10, 0), v(5, 0), v(20, 0), 6), 1e-4);
    // Half the gap: half weight; the overlap only.
    try std.testing.expectApproxEqAbs(@as(f32, 4), nearLength(v(0, 0), v(10, 0), v(2, 3), v(30, 3), 6), 1e-4);
    try std.testing.expectEqual(@as(f32, 0), nearLength(v(0, 0), v(10, 0), v(0, 6), v(10, 6), 6));
    try std.testing.expectEqual(@as(f32, 0), nearLength(v(0, 0), v(10, 0), v(5, -5), v(5, 5), 6));
    try std.testing.expectEqual(@as(f32, 0), nearLength(v(0, 0), v(10, 0), v(20, 0), v(30, 0), 6));
    // A near touch: an end close to the other segment.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), closeness(v(5, 3), v(0, 0), v(10, 0), 6), 1e-4);
    try std.testing.expectEqual(@as(f32, 0), closeness(v(5, 7), v(0, 0), v(10, 0), 6));
    try std.testing.expectApproxEqAbs(@as(f32, 1), closeness(v(10, 0), v(0, 0), v(10, 0), 6), 1e-4);
    // Through a box: the length inside.
    try std.testing.expectApproxEqAbs(@as(f32, 4), lengthInside(v(0, 5), v(20, 5), .{ .min = v(8, 0), .max = v(12, 10) }), 1e-4);
    try std.testing.expectEqual(@as(f32, 0), lengthInside(v(0, 20), v(20, 20), .{ .min = v(8, 0), .max = v(12, 10) }));
}

const TestCtx = struct {
    font: Font,

    fn init() !TestCtx {
        return .{ .font = try Font.init(std.testing.allocator, @import("root.zig").font_ttf) };
    }
    fn ctx(t: *TestCtx) draw.Ctx {
        return .{ .gpa = std.testing.allocator, .font = &t.font };
    }
};

fn stairsArrow(t: Vec2, h: Vec2) Annotation {
    return .{ .arrow = .{ .tail = t, .head = h, .width = 4, .color = color.black, .style = .stairs } };
}

/// Number of crossings between the drawn paths of two annotations.
fn crossingsOf(a: Annotation, b: Annotation) usize {
    var o = Obstacles{};
    o.addPath(b, .{ .min = v(-1e6, -1e6), .max = v(1e6, 1e6) });
    const p = draw.stairsPlan(draw.stairsArrow(a).?, .identity).?;
    const pts = [4]Vec2{ p.rt.t, p.rt.c1, p.rt.c2, p.rt.h };
    var n: usize = 0;
    for (pts[0..3], pts[1..]) |x, y| for (o.segs[0..o.n_segs]) |q| {
        if (crosses(x, y, q.a, q.b)) n += 1;
    };
    return n;
}

test "best: nothing around keeps the default elbow; a pinned elbow stays" {
    var tc = try TestCtx.init();
    defer tc.font.deinit();
    const a = stairsArrow(v(0, 0), v(300, 100));
    const far = [_]Annotation{stairsArrow(v(500, 500), v(800, 600))};
    try std.testing.expectEqual(ann.Elbow{}, best(tc.ctx(), &far, null, a).arrow.elbow);
    try std.testing.expectEqual(ann.Elbow{}, best(tc.ctx(), &.{}, null, a).arrow.elbow);
    var p = a;
    p.arrow.elbow = .{ .at = 0.3, .pinned = true };
    const near = [_]Annotation{stairsArrow(v(0, 10), v(300, 110))};
    try std.testing.expectEqual(p.arrow.elbow, best(tc.ctx(), &near, null, p).arrow.elbow);
    // A straight arrow has no elbow to choose.
    var s = a;
    s.arrow.style = .straight;
    try std.testing.expectEqual(s, best(tc.ctx(), &near, null, s));
}

test "best: two arrows side by side nest, in both orders, with no crossing; the choice is deterministic" {
    var tc = try TestCtx.init();
    defer tc.font.deinit();
    // The user's case: vertical first, tails at the top, heads lower left.
    const a = stairsArrow(v(495, 100), v(260, 400));
    const b = stairsArrow(v(557, 100), v(435, 400));
    // b drawn second: it bends below a's middle segment.
    const b2 = best(tc.ctx(), &.{a}, null, b);
    try std.testing.expectEqual(@as(usize, 0), crossingsOf(b2, a));
    try std.testing.expect(b2.arrow.elbow.at > 0.5);
    // a drawn second: it bends above b's.
    const a2 = best(tc.ctx(), &.{b}, null, a);
    try std.testing.expectEqual(@as(usize, 0), crossingsOf(a2, b));
    try std.testing.expect(a2.arrow.elbow.at < 0.5);
    // Same input, same choice.
    try std.testing.expectEqual(b2, best(tc.ctx(), &.{a}, null, b));
    // Far enough apart: no crowding left.
    const pa = draw.stairsPlan(a.arrow, .identity).?;
    const pb = draw.stairsPlan(b2.arrow, .identity).?;
    try std.testing.expect(pb.rt.c1.y - pa.rt.c1.y >= nearGap(4, 4) - 1e-3);
}

test "settle: a change re-routes the auto paths near it, not the pinned or far ones" {
    var tc = try TestCtx.init();
    defer tc.font.deinit();
    var items = [_]Annotation{
        stairsArrow(v(495, 100), v(260, 400)),
        stairsArrow(v(557, 100), v(435, 400)),
        stairsArrow(v(2000, 100), v(2300, 400)),
    };
    items[0].arrow.elbow.pinned = true;
    const b1 = items[1];
    var changed: [max_settle]Rerouted = undefined;
    const n = settle(tc.ctx(), &items, .{ .min = v(0, 0), .max = v(600, 500) }, &changed);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(Rerouted{ .index = 1, .before = b1 }, changed[0]);
    try std.testing.expect(items[0].arrow.elbow.at == 0.5);
    try std.testing.expect(items[1].arrow.elbow.at > 0.5);
    try std.testing.expectEqual(ann.Elbow{}, items[2].arrow.elbow);
}
