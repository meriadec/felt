//! View animation: a short ease-out from one image-to-screen transform to
//! another. Pure and time-injected: the backend passes a monotonic clock
//! (ns) to `step`; the first step sets t = 0, so a frame that is late never
//! eats the animation. Used to bring the view back after an image drag.
const std = @import("std");
const geom = @import("geom.zig");

const Vec2 = geom.Vec2;
const Xform = geom.Xform;

/// Length of the animation (ns).
pub const duration_ns: u64 = 220 * std.time.ns_per_ms;

pub const ViewAnim = struct {
    from: Xform,
    to: Xform,
    /// What `Editor.fitted` becomes when the animation ends.
    fitted_after: bool,
    /// Clock value of the first step; null until then.
    start_ns: ?u64 = null,

    pub const Step = struct { xf: Xform, done: bool };

    /// The view that keeps the point that was at `old` (scene px) on the
    /// same screen position once it sits at `new`: the same scale, the
    /// offset shifted by `scale * (old - new)`, whole pixels.
    pub fn follow(orig: Xform, old: Vec2, new: Vec2) Xform {
        const d = old.sub(new).scale(orig.scale);
        return .{ .scale = orig.scale, .offset = .{ .x = @round(orig.offset.x + d.x), .y = @round(orig.offset.y + d.y) } };
    }

    /// The transform at clock `now_ns`. Offsets are whole pixels. At the
    /// end it is exactly `to`.
    pub fn step(self: *ViewAnim, now_ns: u64) Step {
        const t0 = self.start_ns orelse blk: {
            self.start_ns = now_ns;
            break :blk now_ns;
        };
        const el = now_ns -| t0;
        if (el >= duration_ns) return .{ .xf = self.to, .done = true };
        const t: f32 = @as(f32, @floatFromInt(el)) / @as(f32, @floatFromInt(duration_ns));
        const k = 1 - (1 - t) * (1 - t) * (1 - t); // ease-out cubic
        return .{ .xf = .{
            .scale = lerp(self.from.scale, self.to.scale, k),
            .offset = .{ .x = @round(lerp(self.from.offset.x, self.to.offset.x, k)), .y = @round(lerp(self.from.offset.y, self.to.offset.y, k)) },
        }, .done = false };
    }

    fn lerp(a: f32, b: f32, k: f32) f32 {
        return a + (b - a) * k;
    }
};

test "follow keeps the image at the same screen position" {
    const orig = Xform{ .scale = 0.5, .offset = .{ .x = 10, .y = 20 } };
    const old = Vec2.init(464, 0);
    const new = Vec2.init(0, 264);
    const to = ViewAnim.follow(orig, old, new);
    try std.testing.expectEqual(@as(f32, 0.5), to.scale);
    const before = orig.apply(old);
    const after = to.apply(new);
    try std.testing.expectEqual(before.x, after.x);
    try std.testing.expectEqual(before.y, after.y);
    // The same place: the same view.
    try std.testing.expect(std.meta.eql(orig, ViewAnim.follow(orig, old, old)));
}

test "step: starts at the first clock value, eases out, ends exactly on the target" {
    var a = ViewAnim{ .from = .{ .scale = 0.25, .offset = .{ .x = 0, .y = 0 } }, .to = .{ .scale = 0.5, .offset = .{ .x = 100, .y = -40 } }, .fitted_after = false };
    const s0 = a.step(1_000_000_000);
    try std.testing.expect(!s0.done);
    try std.testing.expectEqual(@as(f32, 0.25), s0.xf.scale);
    const s1 = a.step(1_000_000_000 + duration_ns / 2);
    try std.testing.expect(!s1.done);
    try std.testing.expect(s1.xf.scale > 0.375); // ease-out: past the middle at half time
    try std.testing.expect(s1.xf.scale < 0.5);
    try std.testing.expectEqual(@round(s1.xf.offset.x), s1.xf.offset.x);
    const s2 = a.step(1_000_000_000 + duration_ns);
    try std.testing.expect(s2.done);
    try std.testing.expect(std.meta.eql(a.to, s2.xf));
}
