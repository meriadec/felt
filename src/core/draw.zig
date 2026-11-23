//! Draws annotations on a canvas through an image-to-target transform
//! (screen view or identity for export). Geometry is computed in image units
//! and then transformed, so screen and export match. `bounds` gives the
//! target-pixel area a draw can touch (for damage tracking).
const std = @import("std");
const geom = @import("geom.zig");
const sdf = @import("sdf.zig");
const raster = @import("raster.zig");
const stairs = @import("stairs.zig");
const text = @import("text.zig");
const ann_mod = @import("annotation.zig");
const color = @import("color.zig");
const Canvas = @import("canvas.zig").Canvas;
const Font = @import("font.zig").Font;

const Vec2 = geom.Vec2;
const Rect = geom.Rect;
const Bounds = geom.Bounds;
const Xform = geom.Xform;
const Color = color.Color;
const Annotation = ann_mod.Annotation;

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    font: *Font,
    /// Canvas padding (image px, settings.zig `padding_steps`): margin around
    /// the kept rectangle that is always canvas (extent.zig). 0: none.
    pad: i32 = 0,
};

pub const Options = struct {
    /// The shape is in progress: draw the text caret and the pixelate frame.
    preview: bool = false,
    /// Image area in target px (null: the whole canvas). Pixelate averages
    /// only pixels inside, so the screen background never bleeds in.
    area: ?Rect = null,
};

const preview_frame = Color{ .r = 128, .g = 128, .b = 128, .a = 200 };

const shadow_color = Color{ .r = 0, .g = 0, .b = 0, .a = 90 };

const Shadow = struct {
    offset: Vec2,
    soft: f32,

    fn of(width: f32) Shadow {
        const o = @max(1, width * 0.35);
        return .{ .offset = .{ .x = o * 0.5, .y = o }, .soft = 1 + width * 0.8 };
    }
    fn margin(s: Shadow) f32 {
        return @max(@abs(s.offset.x), @abs(s.offset.y)) + s.soft + 2;
    }
};

pub fn annotation(ctx: Ctx, cv: *Canvas, clip: Rect, ann: Annotation, xf: Xform, opts: Options) !void {
    switch (ann) {
        .arrow => |a| switch (arrowShape(a, xf)) {
            inline else => |s| drawWithShadow(cv, clip, s, a.color, Shadow.of(a.width * xf.scale)),
        },
        .rect => |b| {
            const s = boxShape(b, xf);
            drawWithShadow(cv, clip, s, b.color, Shadow.of(b.width * xf.scale));
        },
        .pixelate => |p| {
            const r = sortedBounds(xf.apply(p.a), xf.apply(p.b)).toRect();
            const block: i32 = @intFromFloat(@max(2, @round(p.block * xf.scale)));
            cv.pixelate(r, block, opts.area orelse cv.bounds(), clip);
            if (opts.preview) raster.fill(cv, clip, sdf.RectStroke{ .min = r.toBounds().min, .max = r.toBounds().max, .w = 1 }, .{ .solid = preview_frame }, .{});
        },
        .text => |t| try drawText(ctx, cv, clip, t, xf, opts.preview),
        .number => |n| try drawNumber(ctx, cv, clip, n, xf),
        .callout => |c| try drawCallout(ctx, cv, clip, c, xf, opts.preview),
    }
}

/// Target-pixel rectangle that `annotation` may write.
pub fn bounds(ctx: Ctx, ann: Annotation, xf: Xform, opts: Options) Rect {
    _ = opts; // preview extras (caret, pixelate frame) stay inside the shape bounds
    const b: Bounds = switch (ann) {
        .arrow => |a| arrowShape(a, xf).bounds().expand(Shadow.of(a.width * xf.scale).margin()),
        .rect => |r| boxShape(r, xf).bounds().expand(Shadow.of(r.width * xf.scale).margin()),
        .pixelate => |p| sortedBounds(xf.apply(p.a), xf.apply(p.b)).expand(1),
        .text => |t| blk: {
            const g = textGeom(ctx, t, xf);
            break :blk g.box.bounds().expand(Shadow.of(g.m.pxf * 0.2).margin() + 2);
        },
        .number => |n| numberDisc(n, xf).bounds().expand(Shadow.of(n.size * xf.scale * 0.2).margin() + 2),
        .callout => |c| blk: {
            const g = calloutGeom(ctx, c, xf);
            const box = g.box.bounds().expand(Shadow.of(g.m.pxf * 0.2).margin() + 2);
            const p = g.pointer orelse break :blk box;
            break :blk box.unite(p.bounds().expand(g.pointer_margin));
        },
    };
    return b.toRect();
}

/// Most rectangles `cover` returns.
pub const max_cover = 24;

/// Rectangles (target px) that together hold everything `annotation` may
/// write, tighter than `bounds` for thin shapes: a long diagonal arrow or
/// callout pointer in pieces along its axis, a rect outline as its four
/// sides. A move repaints only these (old and new place).
pub fn cover(ctx: Ctx, ann: Annotation, xf: Xform, buf: *[max_cover]Rect) []const Rect {
    var n: usize = 0;
    switch (ann) {
        .arrow => |a| n = arrowCover(arrowShape(a, xf), Shadow.of(a.width * xf.scale).margin(), buf),
        .rect => |r| {
            const b = boxShape(r, xf);
            const e = b.w * 0.5 + Shadow.of(r.width * xf.scale).margin();
            const sides = [4][2]Vec2{
                .{ b.min, .{ .x = b.max.x, .y = b.min.y } },
                .{ .{ .x = b.min.x, .y = b.max.y }, b.max },
                .{ b.min, .{ .x = b.min.x, .y = b.max.y } },
                .{ .{ .x = b.max.x, .y = b.min.y }, b.max },
            };
            for (sides, 0..) |sd, i| buf[i] = (Bounds{ .min = sd[0], .max = sd[1] }).expand(e).toRect();
            n = 4;
        },
        .callout => |c| {
            const g = calloutGeom(ctx, c, xf);
            const m = Shadow.of(g.m.pxf * 0.2).margin() + 2;
            buf[0] = g.box.bounds().expand(m).toRect();
            n = 1;
            if (g.pointer) |p| n += arrowCover(p, g.pointer_margin, buf[1..]);
        },
        else => {
            buf[0] = bounds(ctx, ann, xf, .{});
            n = 1;
        },
    }
    return buf[0..n];
}

/// Cover an arrow grown by `m` (its shadow margin): the head, and slabs
/// along a straight stroke or the boxes of the stairs segments (axis
/// aligned: their boxes are tight). Returns the count (at most `out.len`).
fn arrowCover(shape: ArrowShape, m: f32, out: []Rect) usize {
    switch (shape) {
        .straight => |s| {
            out[0] = s.b.bounds().expand(m).toRect(); // head
            return 1 + segmentCover(s.a.a, s.a.b, s.a.r + m, out[1..]);
        },
        .stairs => |s| {
            out[0] = s.b.bounds().expand(m).toRect();
            for (s.a.pieces(m), 1..) |b, i| out[i] = b.toRect();
            return 4;
        },
    }
}

/// Cover the segment a..b grown by `r` with slabs across its main axis.
/// Slabs sit on a fixed grid, so the slabs of the same segment at two
/// places line up and a move repaints each slab once (compositor `Fix`).
/// Returns the count (at most `out.len`).
fn segmentCover(a: Vec2, b: Vec2, r: f32, out: []Rect) usize {
    const d = b.sub(a).abs();
    const along_x = d.x >= d.y;
    const lo = (if (along_x) @min(a.x, b.x) else @min(a.y, b.y)) - r;
    const hi = (if (along_x) @max(a.x, b.x) else @max(a.y, b.y)) + r;
    // Slab width: a multiple of 32 px, at most out.len slabs.
    const n_max: f32 = @floatFromInt(out.len);
    const step = 32 * @max(1, @ceil((hi - lo) / (32 * (n_max - 1))));
    var k: usize = 0;
    var s0 = @floor(lo / step) * step;
    while (s0 < hi and k < out.len) : (s0 += step) {
        const s1 = s0 + step;
        // The part of the segment inside the slab, grown by r across it.
        const t0, const t1 = slabParams(a, b, along_x, s0 - r, s1 + r);
        const p0 = a.add(b.sub(a).scale(t0));
        const p1 = a.add(b.sub(a).scale(t1));
        const cross_lo = (if (along_x) @min(p0.y, p1.y) else @min(p0.x, p1.x)) - r;
        const cross_hi = (if (along_x) @max(p0.y, p1.y) else @max(p0.x, p1.x)) + r;
        const bb: Bounds = if (along_x)
            .{ .min = .{ .x = @max(s0, lo), .y = cross_lo }, .max = .{ .x = @min(s1, hi), .y = cross_hi } }
        else
            .{ .min = .{ .x = cross_lo, .y = @max(s0, lo) }, .max = .{ .x = cross_hi, .y = @min(s1, hi) } };
        out[k] = bb.toRect();
        k += 1;
    }
    return k;
}

/// Parameters (0..1) of the segment a..b where its main coordinate is in
/// [lo, hi], clamped to the segment.
fn slabParams(a: Vec2, b: Vec2, along_x: bool, lo: f32, hi: f32) struct { f32, f32 } {
    const av = if (along_x) a.x else a.y;
    const bv = if (along_x) b.x else b.y;
    if (@abs(bv - av) < 1e-6) return .{ 0, 1 };
    const ta = std.math.clamp((lo - av) / (bv - av), 0, 1);
    const tb = std.math.clamp((hi - av) / (bv - av), 0, 1);
    return .{ @min(ta, tb), @max(ta, tb) };
}

/// Target-pixel rectangle of the shape itself: no shadow, no anti-aliasing
/// margin. The canvas grows on a side only when this crosses it (extent.zig).
pub fn bodyBounds(ctx: Ctx, ann: Annotation, xf: Xform) Rect {
    const b: Bounds = switch (ann) {
        .arrow => |a| arrowShape(a, xf).bounds(),
        .rect => |r| boxShape(r, xf).bounds(),
        .pixelate => |p| sortedBounds(xf.apply(p.a), xf.apply(p.b)),
        .text => |t| textGeom(ctx, t, xf).box.bounds(),
        .number => |n| blk: {
            const d = numberDisc(n, xf);
            break :blk d.bounds().expand(numberRing(d));
        },
        .callout => |c| calloutGeom(ctx, c, xf).shape().bounds(),
    };
    // Round inward by a hair: a shape that ends on a pixel edge does not cross it.
    return (Bounds{ .min = b.min.add(.{ .x = 0.01, .y = 0.01 }), .max = b.max.sub(.{ .x = 0.01, .y = 0.01 }) }).toRect();
}

/// Distance (target px) from `p` to the drawn shape, negative inside: the
/// stroke of an arrow or a rect outline, the area of the filled shapes, the
/// label box of a text, the box and pointer of a callout. For hit tests.
pub fn hitDist(ctx: Ctx, ann: Annotation, xf: Xform, p: Vec2) f32 {
    return switch (ann) {
        .arrow => |a| arrowShape(a, xf).dist(p),
        .rect => |r| boxShape(r, xf).dist(p),
        .pixelate => |q| blk: {
            const b = sortedBounds(xf.apply(q.a), xf.apply(q.b));
            break :blk (sdf.RoundRect{ .min = b.min, .max = b.max, .radius = 0 }).dist(p);
        },
        .text => |t| textGeom(ctx, t, xf).box.dist(p),
        .number => |n| blk: {
            const d = numberDisc(n, xf);
            break :blk d.dist(p) - numberRing(d);
        },
        .callout => |c| calloutGeom(ctx, c, xf).shape().dist(p),
    };
}

/// Look of the move tool's outline: a flat line `gap` px off the shape.
pub const OutlineStyle = struct { gap: f32, w: f32, color: Color };

/// Outline `ann` (move tool hover): a line around its shape, `st.gap` px
/// off it. A rect outline gets one line around its outer edge.
pub fn outline(ctx: Ctx, cv: *Canvas, clip: Rect, ann: Annotation, xf: Xform, st: OutlineStyle) void {
    const paint = raster.Paint{ .solid = st.color };
    const off = st.gap + st.w * 0.5;
    switch (ann) {
        .arrow => |a| raster.fill(cv, clip, sdf.ring(sdf.Grown(ArrowShape){ .s = arrowShape(a, xf), .r = off }, st.w), paint, .{}),
        .rect => |r| {
            const b = boxShape(r, xf);
            const e = b.w * 0.5 + off;
            raster.fill(cv, clip, sdf.ring(sdf.RoundRect{ .min = b.min.sub(.{ .x = e, .y = e }), .max = b.max.add(.{ .x = e, .y = e }), .radius = off }, st.w), paint, .{});
        },
        .pixelate => |q| {
            const b = sortedBounds(xf.apply(q.a), xf.apply(q.b)).expand(off);
            raster.fill(cv, clip, sdf.ring(sdf.RoundRect{ .min = b.min, .max = b.max, .radius = off }, st.w), paint, .{});
        },
        .text => |t| raster.fill(cv, clip, sdf.ring(sdf.Grown(sdf.RoundRect){ .s = textGeom(ctx, t, xf).box, .r = off }, st.w), paint, .{}),
        .number => |n| {
            const d = numberDisc(n, xf);
            raster.fill(cv, clip, sdf.ring(sdf.Disc{ .c = d.c, .r = d.r + numberRing(d) + off }, st.w), paint, .{});
        },
        .callout => |c| raster.fill(cv, clip, sdf.ring(sdf.Grown(CalloutShape){ .s = calloutGeom(ctx, c, xf).shape(), .r = off }, st.w), paint, .{}),
    }
}

/// Target-pixel rectangle that `outline` may write.
pub fn outlineBounds(ctx: Ctx, ann: Annotation, xf: Xform, st: OutlineStyle) Rect {
    const body = bodyBounds(ctx, ann, xf);
    return body.expand(@intFromFloat(@ceil(st.gap + st.w + 2)));
}

fn drawWithShadow(cv: *Canvas, clip: Rect, shape: anytype, c: Color, sh: Shadow) void {
    raster.fill(cv, clip, shape, .{ .solid = shadow_color }, .{ .offset = sh.offset, .soft = sh.soft });
    raster.fill(cv, clip, shape, .{ .solid = c }, .{});
}

fn sortedBounds(a: Vec2, b: Vec2) Bounds {
    return .{ .min = a.min(b), .max = a.max(b) };
}

// ---- arrow -------------------------------------------------------------

const Head = sdf.Subtract(sdf.Triangle, sdf.Triangle);

/// A straight arrow, or a stairs arrow (stairs.zig): a stroke and a head.
pub const ArrowShape = union(ann_mod.ArrowStyle) {
    straight: sdf.Union(sdf.Capsule, Head),
    stairs: sdf.Union(stairs.Path, Head),

    pub fn dist(s: ArrowShape, p: Vec2) f32 {
        return switch (s) {
            inline else => |x| x.dist(p),
        };
    }
    pub fn bounds(s: ArrowShape) Bounds {
        return switch (s) {
            inline else => |x| x.bounds(),
        };
    }
};

/// Head length in image units for a stroke width in image units.
fn headLength(width: f32) f32 {
    return 3 * width + 4 * @sqrt(width);
}

/// Head of length `len` with its point at `h`, pointing along `dir`:
/// a triangle minus a wedge behind the notch (swallow tail).
fn headShape(h: Vec2, dir: Vec2, len: f32) Head {
    const n = dir.perp();
    const half = len * 0.58;
    const base = h.sub(dir.scale(len));
    const notch = h.sub(dir.scale(len * 0.8));
    const left = base.add(n.scale(half));
    const right = base.sub(n.scale(half));
    return .{
        .a = .{ .a = h, .b = left, .c = right },
        .b = .{ .a = notch, .b = left.add(left.sub(notch)), .c = right.add(right.sub(notch)) },
    };
}

/// The stroke ends this far (a fraction of the head length) before the
/// point, inside the head.
const shaft_back = 0.6;

/// How a stairs arrow runs through an `Xform` (target px): its route (the
/// elbow of the arrow, clamped so the head keeps its straight stretch),
/// whether it runs along the minor axis first, and its head length.
pub const StairsPlan = struct { rt: stairs.Route, flip: bool, head: f32 };

/// The stairs plan of `a`, or null: it draws straight (a straight arrow,
/// or a rise under the stroke width: a jog that small would only show as
/// a dent). A flip shows only where the minor axis has room for full
/// corners and a full head; else the arrow runs along the dominant axis
/// first. The head length follows the span of the first axis, not the
/// turn, so moving the turn never resizes the head.
pub fn stairsPlan(a: ann_mod.Arrow, xf: Xform) ?StairsPlan {
    if (a.style == .straight) return null;
    const t = xf.apply(a.tail);
    const h = xf.apply(a.head);
    const hw = @max(1, a.width * xf.scale) * 0.5;
    const base = stairs.Route.of(t, h);
    if (base.rise < 2 * hw) return null;
    const hl = headLength(a.width) * xf.scale;
    const flip = a.elbow.flip and base.rise * 0.375 >= hl and
        stairs.bendRange(base.rise, stairs.cornerRadius(a.width) * xf.scale, hl) != null;
    const span = if (flip) base.rise else base.span();
    const head = @min(hl, span * 0.5 * 0.75);
    const at = std.math.clamp(a.elbow.at, 0, 1 - head / span);
    return .{ .rt = stairs.Route.init(t, h, at, flip), .flip = flip, .head = head };
}

/// Where the router or a pin may put the middle segment of `a` (image px)
/// with the first axis given by `flip`: the `at` range with full corners
/// and the head stretch kept, or {0.5, 0.5} when there is no room. Null:
/// that orientation is not open (a straight arrow, a flip with no room).
pub fn elbowRange(a: ann_mod.Arrow, flip: bool) ?[2]f32 {
    var b = a;
    b.elbow = .{ .flip = flip };
    const p = stairsPlan(b, .identity) orelse return null;
    if (p.flip != flip) return null;
    const r = @min(stairs.cornerRadius(a.width), p.rt.rise * 0.5);
    return stairs.bendRange(p.rt.span(), r, p.head) orelse .{ 0.5, 0.5 };
}

pub fn arrowShape(a: ann_mod.Arrow, xf: Xform) ArrowShape {
    const t = xf.apply(a.tail);
    const h = xf.apply(a.head);
    const hw = @max(1, a.width * xf.scale) * 0.5;
    if (stairsPlan(a, xf)) |p| {
        // The head sits on the last segment and points along it.
        const path = stairs.Path.init(p.rt, p.head * shaft_back, p.head, stairs.cornerRadius(a.width) * xf.scale, hw);
        return .{ .stairs = .{ .a = path, .b = headShape(h, p.rt.u, p.head) } };
    }
    const hl = headLength(a.width) * xf.scale;
    const d = h.sub(t);
    const l = d.len();
    const dir = d.normalize();
    const head = @min(hl, l * 0.75);
    const shaft_end = h.sub(dir.scale(head * shaft_back));
    return .{ .straight = .{ .a = .{ .a = t, .b = if (l > head) shaft_end else t, .r = hw }, .b = headShape(h, dir, head) } };
}

/// The stairs path of an arrow or a callout pointer, as an arrow (image
/// px), or null: none, or straight.
pub fn stairsArrow(a: Annotation) ?ann_mod.Arrow {
    const ar = switch (a) {
        .arrow => |x| x,
        .callout => |c| calloutPointer(c) orelse return null,
        else => return null,
    };
    return if (ar.style == .stairs) ar else null;
}

/// The box of a label (text, callout box, number bubble; image px), or null.
pub fn labelBox(ctx: Ctx, a: Annotation) ?Bounds {
    return switch (a) {
        .text => |t| textGeom(ctx, t, .identity).box.bounds(),
        .callout => |c| calloutGeom(ctx, c, .identity).box.bounds(),
        .number => |n| blk: {
            const d = numberDisc(n, .identity);
            break :blk d.bounds().expand(numberRing(d));
        },
        else => null,
    };
}

// ---- rect ----------------------------------------------------------------

fn boxShape(b: ann_mod.Box, xf: Xform) sdf.RectStroke {
    const s = sortedBounds(xf.apply(b.a), xf.apply(b.b));
    return .{ .min = s.min, .max = s.max, .w = @max(1, b.width * xf.scale) };
}

// ---- text label ------------------------------------------------------

/// Text and callouts share one label look: a rounded box in the annotation
/// color, text in the contrast color, a soft drop shadow. Crisp on any background.
const LabelMetrics = struct {
    px: u16,
    pxf: f32,
    /// Space between the text and the box edge (target px).
    pad: f32,
    /// Box size (target px).
    size: Vec2,

    fn of(ctx: Ctx, s: []const u8, size: f32, xf: Xform) LabelMetrics {
        const pxf = size * xf.scale;
        const px = text.pxOf(pxf);
        const lay = text.measure(ctx.font, s, px);
        const pad = pxf * 0.45;
        return .{ .px = px, .pxf = pxf, .pad = pad, .size = Vec2.init(@max(lay.width, pxf * 0.5) + 2 * pad, lay.height + 2 * pad) };
    }

    fn box(m: LabelMetrics, min: Vec2) sdf.RoundRect {
        return .{ .min = min, .max = min.add(m.size), .radius = m.pad * 0.7 };
    }
};

/// Blend a text block whose top-left is at `o` (target px).
fn blendText(ctx: Ctx, cv: *Canvas, clip: Rect, s: []const u8, px: u16, o: Vec2, fill_c: Color, caret: bool) !void {
    const fx = @floor(o.x);
    var mask = try text.render(ctx.gpa, ctx.font, s, px, 0, o.x - fx, caret);
    defer mask.deinit(ctx.gpa);
    cv.blendMask(mask.data, mask.w, mask.h, @intFromFloat(fx), @intFromFloat(@round(o.y)), fill_c, clip);
}

const TextGeom = struct { m: LabelMetrics, box: sdf.RoundRect, text_pos: Vec2 };

/// `t.pos` is the top-left of the text; the box grows around it by the padding.
fn textGeom(ctx: Ctx, t: ann_mod.Text, xf: Xform) TextGeom {
    const m = LabelMetrics.of(ctx, t.text, t.size, xf);
    const o = xf.apply(t.pos);
    return .{ .m = m, .box = m.box(o.sub(.{ .x = m.pad, .y = m.pad })), .text_pos = o };
}

/// Label body: shadow, fill, and a faint edge so a white label stays visible
/// on white (and a black one on black).
fn drawLabelBody(cv: *Canvas, clip: Rect, shape: anytype, c: Color, m: LabelMetrics) void {
    drawWithShadow(cv, clip, shape, c, Shadow.of(m.pxf * 0.2));
    const edge = if (c.luminance() > 0.6) Color{ .r = 0, .g = 0, .b = 0, .a = 50 } else Color{ .r = 255, .g = 255, .b = 255, .a = 40 };
    raster.fill(cv, clip, sdf.ring(shape, @max(1, m.pxf * 0.05)), .{ .solid = edge }, .{});
}

fn drawText(ctx: Ctx, cv: *Canvas, clip: Rect, t: ann_mod.Text, xf: Xform, caret: bool) !void {
    const g = textGeom(ctx, t, xf);
    drawLabelBody(cv, clip, g.box, t.color, g.m);
    try blendText(ctx, cv, clip, t.text, g.m.px, g.text_pos, t.color.contrast(), caret);
}

// ---- numbered bubble ---------------------------------------------------

fn numberDisc(n: ann_mod.Number, xf: Xform) sdf.Disc {
    return .{ .c = xf.apply(n.center), .r = n.size * 0.8 * xf.scale };
}

fn numberRing(disc: sdf.Disc) f32 {
    return @max(1.5, disc.r * 0.12);
}

fn drawNumber(ctx: Ctx, cv: *Canvas, clip: Rect, n: ann_mod.Number, xf: Xform) !void {
    const disc = numberDisc(n, xf);
    const ring = numberRing(disc);
    const outer = sdf.Disc{ .c = disc.c, .r = disc.r + ring };
    drawWithShadow(cv, clip, outer, color.white, Shadow.of(n.size * xf.scale * 0.2));
    raster.fill(cv, clip, disc, .{ .solid = n.color }, .{});

    var buf: [12]u8 = undefined;
    const digits = std.fmt.bufPrint(&buf, "{d}", .{n.value}) catch unreachable;
    const px = text.pxOf(n.size * xf.scale * (if (digits.len > 2) @as(f32, 0.7) else 0.95));
    var mask = try text.render(ctx.gpa, ctx.font, digits, px, 1, 0, false);
    defer mask.deinit(ctx.gpa);
    const ink = mask.inkBounds();
    const cx = @as(f32, @floatFromInt(ink[0] + ink[2])) * 0.5;
    const cy = @as(f32, @floatFromInt(ink[1] + ink[3])) * 0.5;
    const dx: i32 = @intFromFloat(@round(disc.c.x - cx));
    const dy: i32 = @intFromFloat(@round(disc.c.y - cy));
    cv.blendMask(mask.data, mask.w, mask.h, dx, dy, n.color.contrast(), clip);
}

// ---- callout -----------------------------------------------------------

/// The box and, under it, the arrow pointer (none: a label).
const CalloutShape = struct {
    box: sdf.RoundRect,
    pointer: ?ArrowShape,

    pub fn dist(s: CalloutShape, p: Vec2) f32 {
        const d = s.box.dist(p);
        const ptr = s.pointer orelse return d;
        return @min(d, ptr.dist(p));
    }
    pub fn bounds(s: CalloutShape) Bounds {
        const b = s.box.bounds();
        return if (s.pointer) |ptr| b.unite(ptr.bounds()) else b;
    }
};

const CalloutGeom = struct {
    m: LabelMetrics,
    box: sdf.RoundRect,
    pointer: ?ArrowShape,
    /// Shadow margin of the pointer (target px).
    pointer_margin: f32,
    text_pos: Vec2,

    fn shape(g: CalloutGeom) CalloutShape {
        return .{ .box = g.box, .pointer = g.pointer };
    }
};

/// The pointer of a callout as an arrow: from `anchor` (the middle of the
/// box side that faces the target) to the target, with the callout's
/// stroke, color and style. A stairs pointer leaves the box across that
/// side: its first segment runs along the same axis that picked the side.
/// None for a label, or when the target is nearer the box than one head
/// length: a pointer that short would be only a head stuck to the box.
/// Its tip handle still moves it out (move tool).
pub fn calloutPointer(c: ann_mod.Callout) ?ann_mod.Arrow {
    const t = c.target orelse return null;
    if (t.dist(c.anchor) < headLength(c.width)) return null;
    var e = c.elbow;
    e.flip = false;
    return .{ .tail = c.anchor, .head = t, .width = c.width, .color = c.color, .style = c.style, .elbow = e };
}

fn calloutGeom(ctx: Ctx, c: ann_mod.Callout, xf: Xform) CalloutGeom {
    const m = LabelMetrics.of(ctx, c.text, c.size, xf);
    const size = m.size;
    const a = xf.apply(c.anchor);
    var min = a.sub(size.scale(0.5)); // centered label
    if (c.target) |t_img| {
        // The box goes on the far side of the anchor from the target,
        // along the dominant axis: the anchor is the middle of that side.
        const d = a.sub(xf.apply(t_img));
        if (@abs(d.x) >= @abs(d.y)) {
            min.x = if (d.x >= 0) a.x else a.x - size.x;
        } else {
            min.y = if (d.y >= 0) a.y else a.y - size.y;
        }
    }
    const ptr = calloutPointer(c);
    return .{
        .m = m,
        .box = m.box(min),
        .pointer = if (ptr) |p| arrowShape(p, xf) else null,
        .pointer_margin = Shadow.of(c.width * xf.scale).margin(),
        .text_pos = min.add(.{ .x = m.pad, .y = m.pad }),
    };
}

/// The pointer first (an arrow with its shadow), then the box over its
/// start: the join is the clean box edge.
fn drawCallout(ctx: Ctx, cv: *Canvas, clip: Rect, c: ann_mod.Callout, xf: Xform, caret: bool) !void {
    const g = calloutGeom(ctx, c, xf);
    if (g.pointer) |p| switch (p) {
        inline else => |s| drawWithShadow(cv, clip, s, c.color, Shadow.of(c.width * xf.scale)),
    };
    drawLabelBody(cv, clip, g.box, c.color, g.m);
    try blendText(ctx, cv, clip, c.text, g.m.px, g.text_pos, c.color.contrast(), caret);
}

test "cover holds every pixel an annotation writes" {
    const gpa = std.testing.allocator;
    var font = try Font.init(gpa, @import("root.zig").font_ttf);
    defer font.deinit();
    const ctx = Ctx{ .gpa = gpa, .font = &font };
    var cv = try Canvas.init(gpa, 400, 300);
    defer cv.deinit(gpa);
    const red = color.palette[0].color;
    const anns = [_]Annotation{
        .{ .arrow = .{ .tail = .{ .x = 20, .y = 250 }, .head = .{ .x = 380, .y = 40 }, .width = 8, .color = red } },
        .{ .arrow = .{ .tail = .{ .x = 20, .y = 250 }, .head = .{ .x = 380, .y = 40 }, .width = 8, .color = red, .style = .stairs } },
        .{ .arrow = .{ .tail = .{ .x = 300, .y = 20 }, .head = .{ .x = 100, .y = 290 }, .width = 10, .color = red, .style = .stairs } },
        .{ .rect = .{ .a = .{ .x = 30, .y = 30 }, .b = .{ .x = 350, .y = 260 }, .width = 8, .color = red } },
        .{ .callout = .{ .target = .{ .x = 20, .y = 20 }, .anchor = .{ .x = 300, .y = 250 }, .text = "Hi", .size = 20, .color = red, .width = 5 } },
        .{ .callout = .{ .target = .{ .x = 20, .y = 20 }, .anchor = .{ .x = 300, .y = 250 }, .text = "Hi", .size = 20, .color = red, .width = 5, .style = .stairs } },
        .{ .callout = .{ .target = .{ .x = 380, .y = 30 }, .anchor = .{ .x = 60, .y = 260 }, .text = "Hi", .size = 20, .color = red, .width = 5, .style = .stairs } },
        .{ .callout = .{ .target = .{ .x = 100, .y = 290 }, .anchor = .{ .x = 300, .y = 20 }, .text = "Hi", .size = 20, .color = red, .width = 8, .style = .stairs } },
    };
    for (anns) |a| {
        cv.fill(color.white);
        try annotation(ctx, &cv, cv.bounds(), a, .identity, .{});
        var buf: [max_cover]Rect = undefined;
        const rs = cover(ctx, a, .identity, &buf);
        var covered: u64 = 0;
        for (rs) |r| covered += r.intersect(cv.bounds()).area();
        try std.testing.expect(covered < bounds(ctx, a, .identity, .{}).area() * 3 / 4); // tighter
        for (0..300) |y| for (0..400) |x| {
            if (cv.at(@intCast(x), @intCast(y)) == color.white.toPixel()) continue;
            var in = false;
            for (rs) |r| in = in or (x >= r.x0 and x < r.x1 and y >= r.y0 and y < r.y1);
            try std.testing.expect(in);
        };
    }
}

test "arrow head is proportional and points at the head" {
    const a = ann_mod.Arrow{ .tail = .{ .x = 0, .y = 0 }, .head = .{ .x = 100, .y = 0 }, .width = 4, .color = color.black };
    const s = arrowShape(a, .identity);
    try std.testing.expect(s.dist(.{ .x = 99, .y = 0 }) < 0);
    try std.testing.expect(s.dist(.{ .x = 50, .y = 1.5 }) < 0);
    try std.testing.expect(s.dist(.{ .x = 50, .y = 3 }) > 0);
    // twice the scale, twice the size
    const s2 = arrowShape(a, .{ .scale = 2 });
    const b1 = s.bounds();
    const b2 = s2.bounds();
    try std.testing.expectApproxEqAbs(2 * (b1.max.y - b1.min.y), b2.max.y - b2.min.y, 0.01);
}

test "stairs arrow: the stroke follows the elbow path, the head points along the last segment" {
    const a = ann_mod.Arrow{ .tail = .{ .x = 0, .y = 0 }, .head = .{ .x = 200, .y = 100 }, .width = 4, .color = color.black, .style = .stairs };
    const s = arrowShape(a, .identity);
    try std.testing.expect(s.dist(.{ .x = 50, .y = 0 }) < 0); // first segment
    try std.testing.expect(s.dist(.{ .x = 100, .y = 50 }) < 0); // middle
    try std.testing.expect(s.dist(.{ .x = 150, .y = 100 }) < 0); // last
    try std.testing.expect(s.dist(.{ .x = 100, .y = 0 }) > 2); // round corner
    try std.testing.expect(s.dist(.{ .x = 50, .y = 25 }) > 10); // the straight line: off it
    // Head: a horizontal triangle at the head point.
    try std.testing.expect(s.dist(.{ .x = 199, .y = 100 }) < 0);
    try std.testing.expect(s.dist(.{ .x = 190, .y = 104 }) < 0);
    try std.testing.expect(s.dist(.{ .x = 200, .y = 108 }) > 0);
    // The straight style of the same arrow crosses the middle of the box.
    var b = a;
    b.style = .straight;
    try std.testing.expect(arrowShape(b, .identity).dist(.{ .x = 50, .y = 25 }) < 0);
    // A rise under the stroke width: a straight arrow.
    var flat = a;
    flat.head = .{ .x = 200, .y = 3 };
    try std.testing.expect(arrowShape(flat, .identity) == .straight);
    flat.head.y = 5;
    try std.testing.expect(arrowShape(flat, .identity) == .stairs);
    // Same body bounds for both: the path stays in the box of its ends.
    const sb = s.bounds();
    try std.testing.expect(sb.min.x >= -3 and sb.max.x <= 203 and sb.min.y >= -3 and sb.max.y <= 113);
}

test "stairs arrow: the elbow moves the middle segment and may flip the axes; the head keeps its size" {
    var a = ann_mod.Arrow{ .tail = .{ .x = 0, .y = 0 }, .head = .{ .x = 300, .y = 100 }, .width = 4, .color = color.black, .style = .stairs };
    const base = stairsPlan(a, .identity).?;
    a.elbow.at = 0.25;
    const s = arrowShape(a, .identity);
    try std.testing.expect(s.dist(.{ .x = 75, .y = 50 }) < 0); // the middle segment at x 75
    try std.testing.expect(s.dist(.{ .x = 150, .y = 50 }) > 5);
    try std.testing.expectEqual(base.head, stairsPlan(a, .identity).?.head);
    // A turn past the head stretch is clamped: the head stays on the last segment.
    a.elbow.at = 1;
    const p = stairsPlan(a, .identity).?;
    try std.testing.expectApproxEqAbs(p.head, p.rt.run2, 1e-3);
    // Flipped: vertical first, then across, then down into the head.
    a.elbow = .{ .at = 0.5, .flip = true };
    const f = arrowShape(a, .identity);
    try std.testing.expect(stairsPlan(a, .identity).?.flip);
    try std.testing.expect(f.dist(.{ .x = 0, .y = 25 }) < 0);
    try std.testing.expect(f.dist(.{ .x = 150, .y = 50 }) < 0);
    try std.testing.expect(f.dist(.{ .x = 300, .y = 75 }) < 0);
    try std.testing.expect(elbowRange(a, true) != null);
    // No room on the minor axis: no flip, the arrow runs as before.
    a.head.y = 30;
    try std.testing.expect(!stairsPlan(a, .identity).?.flip);
    try std.testing.expectEqual(@as(?[2]f32, null), elbowRange(a, true));
    // A callout pointer never flips.
    const c = ann_mod.Callout{ .target = .{ .x = 0, .y = 0 }, .anchor = .{ .x = 300, .y = 200 }, .text = "x", .size = 10, .color = color.black, .width = 4, .style = .stairs, .elbow = .{ .flip = true } };
    try std.testing.expect(!calloutPointer(c).?.elbow.flip);
}

test "callout pointer: an arrow from the middle of the box side that faces the target, under the box" {
    const gpa = std.testing.allocator;
    var font = try Font.init(gpa, @import("root.zig").font_ttf);
    defer font.deinit();
    const ctx = Ctx{ .gpa = gpa, .font = &font };
    const red = color.palette[0].color;
    // Target up-left, wider than high: the box sits right of the anchor,
    // the pointer leaves its left side at the anchor.
    var c = ann_mod.Callout{ .target = .{ .x = 0, .y = 0 }, .anchor = .{ .x = 200, .y = 100 }, .text = "Hi", .size = 20, .color = red, .width = 4 };
    const g = calloutGeom(ctx, c, .identity);
    try std.testing.expectEqual(@as(f32, 200), g.box.min.x);
    try std.testing.expectApproxEqAbs(@as(f32, 100), (g.box.min.y + g.box.max.y) * 0.5, 1e-3);
    const p = calloutPointer(c).?;
    try std.testing.expectEqual(c.anchor, p.tail);
    try std.testing.expectEqual(c.target.?, p.head);
    // Straight: along the line; stairs: along the elbow, not the line.
    const a: Annotation = .{ .callout = c };
    try std.testing.expect(hitDist(ctx, a, .identity, .{ .x = 150, .y = 75 }) < 0);
    try std.testing.expect(hitDist(ctx, a, .identity, .{ .x = 150, .y = 100 }) > 5);
    c.style = .stairs;
    const s: Annotation = .{ .callout = c };
    try std.testing.expect(hitDist(ctx, s, .identity, .{ .x = 150, .y = 100 }) < 0); // leaves the box across its side
    try std.testing.expect(hitDist(ctx, s, .identity, .{ .x = 100, .y = 50 }) < 0); // middle segment
    try std.testing.expect(hitDist(ctx, s, .identity, .{ .x = 50, .y = 0 }) < 0); // into the target
    try std.testing.expect(hitDist(ctx, s, .identity, .{ .x = 150, .y = 75 }) > 5); // the straight line: off it
    try std.testing.expect(hitDist(ctx, s, .identity, .{ .x = 230, .y = 100 }) < 0); // the box
    // Bounds hold the whole elbow, the box and their shadows.
    const b = bounds(ctx, s, .identity, .{});
    try std.testing.expect(b.x0 < -2 and b.y0 < -2 and b.x1 > @as(i32, @intFromFloat(g.box.max.x)));
    // Target below, higher than wide: the box sits above the anchor, the
    // pointer leaves its bottom side.
    const down = ann_mod.Callout{ .target = .{ .x = 220, .y = 300 }, .anchor = .{ .x = 200, .y = 100 }, .text = "Hi", .size = 20, .color = red, .width = 4, .style = .stairs };
    const gd = calloutGeom(ctx, down, .identity);
    try std.testing.expectEqual(@as(f32, 100), gd.box.max.y);
    try std.testing.expect(hitDist(ctx, .{ .callout = down }, .identity, .{ .x = 200, .y = 150 }) < 0);
    try std.testing.expect(hitDist(ctx, .{ .callout = down }, .identity, .{ .x = 220, .y = 250 }) < 0);
    // Under the box: a pointer pixel inside the box has the box's look.
    var cv = try Canvas.init(gpa, 320, 200);
    defer cv.deinit(gpa);
    cv.fill(color.white);
    try annotation(ctx, &cv, cv.bounds(), s, .identity, .{});
    try std.testing.expectEqual(red.toPixel(), cv.at(150, 100)); // the stroke
    try std.testing.expectEqual(red.toPixel(), cv.at(204, 100)); // the box over the stroke start
}

test "callout pointer: none for a label or a target nearer than one head length" {
    const red = color.palette[0].color;
    var c = ann_mod.Callout{ .target = null, .anchor = .{ .x = 200, .y = 100 }, .text = "Hi", .size = 20, .color = red, .width = 4 };
    try std.testing.expectEqual(@as(?ann_mod.Arrow, null), calloutPointer(c));
    c.target = .{ .x = 190, .y = 95 };
    try std.testing.expectEqual(@as(?ann_mod.Arrow, null), calloutPointer(c));
    c.target = .{ .x = 200 - headLength(4) - 1, .y = 100 };
    try std.testing.expect(calloutPointer(c) != null);
}
