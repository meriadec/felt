//! Draws annotations on a canvas through an image-to-target transform
//! (screen view or identity for export). Geometry is computed in image units
//! and then transformed, so screen and export match. `bounds` gives the
//! target-pixel area a draw can touch (for damage tracking).
const std = @import("std");
const geom = @import("geom.zig");
const sdf = @import("sdf.zig");
const raster = @import("raster.zig");
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
};

pub const Options = struct {
    /// The shape is in progress: draw the text caret and the pixelate frame.
    preview: bool = false,
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
        .arrow => |a| {
            const s = arrowShape(a, xf);
            drawWithShadow(cv, clip, s, a.color, Shadow.of(a.width * xf.scale));
        },
        .rect => |b| {
            const s = boxShape(b, xf);
            drawWithShadow(cv, clip, s, b.color, Shadow.of(b.width * xf.scale));
        },
        .highlight => |h| raster.fill(cv, clip, highlightShape(h, xf), .{ .multiply = highlightTint(h.color) }, .{}),
        .pixelate => |p| {
            const r = sortedBounds(xf.apply(p.a), xf.apply(p.b)).toRect();
            const block: i32 = @intFromFloat(@max(2, @round(p.block * xf.scale)));
            cv.pixelate(r, block, clip);
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
        .highlight => |h| highlightShape(h, xf).bounds().expand(2),
        .pixelate => |p| sortedBounds(xf.apply(p.a), xf.apply(p.b)).expand(1),
        .text => |t| blk: {
            const g = textGeom(ctx, t, xf);
            break :blk g.box.bounds().expand(Shadow.of(g.m.pxf * 0.2).margin() + 2);
        },
        .number => |n| numberDisc(n, xf).bounds().expand(Shadow.of(n.size * xf.scale * 0.2).margin() + 2),
        .callout => |c| blk: {
            const g = calloutGeom(ctx, c, xf);
            break :blk g.shape().bounds().expand(Shadow.of(g.m.pxf * 0.2).margin() + 2);
        },
    };
    return b.toRect();
}

fn drawWithShadow(cv: *Canvas, clip: Rect, shape: anytype, c: Color, sh: Shadow) void {
    raster.fill(cv, clip, shape, .{ .solid = shadow_color }, .{ .offset = sh.offset, .soft = sh.soft });
    raster.fill(cv, clip, shape, .{ .solid = c }, .{});
}

fn sortedBounds(a: Vec2, b: Vec2) Bounds {
    return .{ .min = a.min(b), .max = a.max(b) };
}

// ---- arrow -------------------------------------------------------------

pub const ArrowShape = sdf.Union(sdf.Capsule, sdf.Subtract(sdf.Triangle, sdf.Triangle));

/// Head length in image units for a stroke width in image units.
fn headLength(width: f32) f32 {
    return 3 * width + 4 * @sqrt(width);
}

pub fn arrowShape(a: ann_mod.Arrow, xf: Xform) ArrowShape {
    const t = xf.apply(a.tail);
    const h = xf.apply(a.head);
    const w = @max(1, a.width * xf.scale);
    const d = h.sub(t);
    const l = d.len();
    const dir = d.normalize();
    const n = dir.perp();
    const head = @min(headLength(a.width) * xf.scale, l * 0.75);
    const half = head * 0.58;
    const base = h.sub(dir.scale(head));
    const notch = h.sub(dir.scale(head * 0.8));
    const left = base.add(n.scale(half));
    const right = base.sub(n.scale(half));
    const shaft_end = h.sub(dir.scale(head * 0.6));
    return .{
        .a = .{ .a = t, .b = if (l > head) shaft_end else t, .r = w * 0.5 },
        // Head: triangle minus a wedge behind the notch (swallow tail).
        .b = .{
            .a = .{ .a = h, .b = left, .c = right },
            .b = .{ .a = notch, .b = left.add(left.sub(notch)), .c = right.add(right.sub(notch)) },
        },
    };
}

// ---- rect, highlight ---------------------------------------------------

fn boxShape(b: ann_mod.Box, xf: Xform) sdf.RectStroke {
    const s = sortedBounds(xf.apply(b.a), xf.apply(b.b));
    return .{ .min = s.min, .max = s.max, .w = @max(1, b.width * xf.scale) };
}

fn highlightShape(h: ann_mod.Highlight, xf: Xform) sdf.RoundRect {
    const s = sortedBounds(xf.apply(h.a), xf.apply(h.b));
    return .{ .min = s.min, .max = s.max, .radius = 3 * xf.scale };
}

fn highlightTint(c: Color) Color {
    return c.lighten(0.35);
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

fn drawNumber(ctx: Ctx, cv: *Canvas, clip: Rect, n: ann_mod.Number, xf: Xform) !void {
    const disc = numberDisc(n, xf);
    const ring = @max(1.5, disc.r * 0.12);
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

const CalloutShape = sdf.Union(sdf.RoundRect, sdf.Triangle);

const CalloutGeom = struct {
    m: LabelMetrics,
    box: sdf.RoundRect,
    pointer: ?sdf.Triangle,
    text_pos: Vec2,

    fn shape(g: CalloutGeom) CalloutShape {
        // Without a pointer, a degenerate triangle inside the box changes nothing.
        const c = g.box.min.add(g.box.max).scale(0.5);
        return .{ .a = g.box, .b = g.pointer orelse .{ .a = c, .b = c, .c = c } };
    }
};

fn calloutGeom(ctx: Ctx, c: ann_mod.Callout, xf: Xform) CalloutGeom {
    const m = LabelMetrics.of(ctx, c.text, c.size, xf);
    const size = m.size;
    const a = xf.apply(c.anchor);
    var min = a.sub(size.scale(0.5)); // centered label
    if (c.target) |t_img| {
        const d = a.sub(xf.apply(t_img));
        if (@abs(d.x) >= @abs(d.y)) {
            min.x = if (d.x >= 0) a.x else a.x - size.x;
        } else {
            min.y = if (d.y >= 0) a.y else a.y - size.y;
        }
    }
    var pointer: ?sdf.Triangle = null;
    if (c.target) |t_img| {
        const tip = xf.apply(t_img);
        const center = min.add(size.scale(0.5));
        const n = center.sub(tip).normalize().perp();
        const half = @min(size.x, size.y) * 0.28;
        pointer = .{ .a = tip, .b = center.add(n.scale(half)), .c = center.sub(n.scale(half)) };
    }
    return .{ .m = m, .box = m.box(min), .pointer = pointer, .text_pos = min.add(.{ .x = m.pad, .y = m.pad }) };
}

fn drawCallout(ctx: Ctx, cv: *Canvas, clip: Rect, c: ann_mod.Callout, xf: Xform, caret: bool) !void {
    const g = calloutGeom(ctx, c, xf);
    drawLabelBody(cv, clip, g.shape(), c.color, g.m);
    try blendText(ctx, cv, clip, c.text, g.m.px, g.text_pos, c.color.contrast(), caret);
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
