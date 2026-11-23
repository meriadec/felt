//! Annotation model. All coordinates and lengths are in image pixels, so the
//! export at full resolution renders exactly what the screen shows.
const std = @import("std");
const geom = @import("geom.zig");
const Color = @import("color.zig").Color;

const Vec2 = geom.Vec2;

/// How an arrow runs from the tail to the head: a straight line, or stairs
/// (an elbow with two round corners, see stairs.zig).
pub const ArrowStyle = enum { straight, stairs };

/// Where a stairs path turns (see stairs.zig): `at` is the place of the
/// middle segment along the first axis, as a fraction of the way from the
/// tail to the head (0.5: halfway); `flip` runs along the other axis first
/// (the minor one: vertical-horizontal-vertical for a wide arrow). The
/// router (route.zig) sets both to keep paths apart, unless `pinned` (the
/// user dragged the middle segment: the elbow stays as set). A straight
/// arrow ignores it.
pub const Elbow = struct { at: f32 = 0.5, flip: bool = false, pinned: bool = false };

pub const Arrow = struct { tail: Vec2, head: Vec2, width: f32, color: Color, style: ArrowStyle = .straight, elbow: Elbow = .{} };

/// Rectangle outline.
pub const Box = struct { a: Vec2, b: Vec2, width: f32, color: Color };

/// How free text looks: plain letters in the annotation color, no
/// shadow (the start style), or on a filled rounded box like a callout.
pub const TextStyle = enum { plain, boxed };

/// Free text; `pos` is the top-left of the first line.
pub const Text = struct { pos: Vec2, text: []const u8, size: f32, color: Color, style: TextStyle = .plain };

/// Numbered bubble centered on `center`; `size` is the font size.
pub const Number = struct { center: Vec2, value: u32, size: f32, color: Color };

/// Text box attached at `anchor`, with an arrow pointer to `target` (none =
/// label). The box sits on the far side of `anchor` from the target, so
/// `anchor` is the middle of the box side that faces the target: the
/// pointer starts there. The pointer is an arrow of stroke `width` and
/// `style`, drawn under the box. A stairs pointer leaves across that side:
/// its `elbow` never flips.
pub const Callout = struct { target: ?Vec2, anchor: Vec2, text: []const u8, size: f32, color: Color, width: f32, style: ArrowStyle = .straight, elbow: Elbow = .{} };

/// Pixelated rectangle a..b with square blocks of `block` pixels.
pub const Pixelate = struct { a: Vec2, b: Vec2, block: f32 };

pub const Annotation = union(enum) {
    arrow: Arrow,
    rect: Box,
    text: Text,
    number: Number,
    callout: Callout,
    pixelate: Pixelate,

    /// Text owned by the annotation, if any.
    pub fn ownedText(self: Annotation) ?[]const u8 {
        return switch (self) {
            .text => |t| t.text,
            .callout => |c| c.text,
            else => null,
        };
    }

    pub fn deinit(self: Annotation, gpa: std.mem.Allocator) void {
        if (self.ownedText()) |t| gpa.free(t);
    }

    /// The annotation with `part` shifted by `d` (image px). It shares the
    /// text. The bend is no shift (the editor sets the elbow).
    pub fn moved(self: Annotation, part: Part, d: Vec2) Annotation {
        if (part == .bend) return self;
        var a = self;
        switch (a) {
            .arrow => |*x| {
                if (part != .head) x.tail = x.tail.add(d);
                if (part != .tail) x.head = x.head.add(d);
            },
            .rect => |*x| {
                x.a = x.a.add(d);
                x.b = x.b.add(d);
            },
            .pixelate => |*x| {
                x.a = x.a.add(d);
                x.b = x.b.add(d);
            },
            .text => |*x| x.pos = x.pos.add(d),
            .number => |*x| x.center = x.center.add(d),
            // The box moves alone, the tip stays on its target; or the tip alone.
            .callout => |*x| if (part == .tip) {
                if (x.target) |t| x.target = t.add(d);
            } else {
                x.anchor = x.anchor.add(d);
            },
        }
        return a;
    }

    /// The annotation with the elbow `e` on its arrow path (an arrow or a
    /// callout); others unchanged.
    pub fn withElbow(self: Annotation, e: Elbow) Annotation {
        var a = self;
        switch (a) {
            .arrow => |*x| x.elbow = e,
            .callout => |*x| x.elbow = e,
            else => {},
        }
        return a;
    }
};

/// What a move drags: the whole annotation (a callout: its box), one end of
/// an arrow, the tip of a callout pointer, or the bend (the middle segment
/// of a stairs path: it pins the elbow).
pub const Part = enum { whole, tail, head, tip, bend };

test "moved shifts the dragged part only" {
    const c = Color{ .r = 0, .g = 0, .b = 0 };
    const d = Vec2.init(10, 5);
    const ar = Annotation{ .arrow = .{ .tail = .{ .x = 0, .y = 0 }, .head = .{ .x = 100, .y = 0 }, .width = 4, .color = c } };
    try std.testing.expectEqual(Vec2.init(10, 5), ar.moved(.whole, d).arrow.tail);
    try std.testing.expectEqual(Vec2.init(110, 5), ar.moved(.whole, d).arrow.head);
    try std.testing.expectEqual(Vec2.init(0, 0), ar.moved(.head, d).arrow.tail);
    try std.testing.expectEqual(Vec2.init(110, 5), ar.moved(.head, d).arrow.head);
    const co = Annotation{ .callout = .{ .target = Vec2.init(1, 1), .anchor = Vec2.init(50, 50), .text = "x", .size = 10, .color = c, .width = 2 } };
    try std.testing.expectEqual(Vec2.init(1, 1), co.moved(.whole, d).callout.target.?);
    try std.testing.expectEqual(Vec2.init(60, 55), co.moved(.whole, d).callout.anchor);
    try std.testing.expectEqual(Vec2.init(11, 6), co.moved(.tip, d).callout.target.?);
    try std.testing.expectEqual(Vec2.init(50, 50), co.moved(.tip, d).callout.anchor);
}
