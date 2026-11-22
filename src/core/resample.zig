//! Area-average (box filter) downscaling, separable, fixed point.
//! Used once per window size to build the on-screen copy of the image.
const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;

const one = 1 << 14;

/// Per-output-pixel taps: source start index, tap count, weights (sum = one).
const Taps = struct {
    start: []u32,
    count: []u32,
    weights: []u16,
    max_taps: u32,

    fn init(gpa: std.mem.Allocator, src_n: u32, dst_n: u32) !Taps {
        const ratio = @as(f64, @floatFromInt(src_n)) / @as(f64, @floatFromInt(dst_n));
        const max_taps: u32 = @intFromFloat(@ceil(ratio) + 1);
        var t = Taps{
            .start = try gpa.alloc(u32, dst_n),
            .count = try gpa.alloc(u32, dst_n),
            .weights = try gpa.alloc(u16, @as(usize, dst_n) * max_taps),
            .max_taps = max_taps,
        };
        for (0..dst_n) |i| {
            const s0 = @as(f64, @floatFromInt(i)) * ratio;
            const s1 = @min(s0 + ratio, @as(f64, @floatFromInt(src_n)));
            const j0: u32 = @intFromFloat(@floor(s0));
            const j1: u32 = @min(@as(u32, @intFromFloat(@ceil(s1))), src_n);
            const w = t.weights[i * max_taps ..][0..max_taps];
            var sum: u32 = 0;
            var best: usize = 0;
            var n: u32 = 0;
            var j = j0;
            while (j < j1) : (j += 1) {
                const lo = @max(@as(f64, @floatFromInt(j)), s0);
                const hi = @min(@as(f64, @floatFromInt(j + 1)), s1);
                const wv: u16 = @intFromFloat(@round((hi - lo) / (s1 - s0) * one));
                w[n] = wv;
                sum += wv;
                if (wv > w[best]) best = n;
                n += 1;
            }
            // Fix rounding so weights sum to exactly `one`.
            w[best] = @intCast(@as(i32, w[best]) + (one - @as(i32, @intCast(sum))));
            t.start[i] = j0;
            t.count[i] = n;
        }
        return t;
    }

    fn deinit(t: *Taps, gpa: std.mem.Allocator) void {
        gpa.free(t.start);
        gpa.free(t.count);
        gpa.free(t.weights);
    }
};

/// Downscale `src` to dw x dh (each <= source size). Caller owns the result.
pub fn downscale(gpa: std.mem.Allocator, src: *const Canvas, dw: u32, dh: u32) !Canvas {
    std.debug.assert(dw > 0 and dh > 0);
    if (dw == src.width and dh == src.height) return src.clone(gpa);

    var hx = try Taps.init(gpa, src.width, dw);
    defer hx.deinit(gpa);
    var vy = try Taps.init(gpa, src.height, dh);
    defer vy.deinit(gpa);

    // Horizontal pass: src.height rows of dw pixels.
    var tmp = try Canvas.init(gpa, dw, src.height);
    defer tmp.deinit(gpa);
    for (0..src.height) |y| {
        const srow = src.pixels[y * src.width ..][0..src.width];
        const drow = tmp.pixels[y * dw ..][0..dw];
        for (drow, 0..) |*d, x| {
            const w = hx.weights[x * hx.max_taps ..][0..hx.count[x]];
            const s = srow[hx.start[x]..][0..w.len];
            var r: u32 = 0;
            var g: u32 = 0;
            var b: u32 = 0;
            for (s, w) |p, wv| {
                r += ((p >> 16) & 0xff) * wv;
                g += ((p >> 8) & 0xff) * wv;
                b += (p & 0xff) * wv;
            }
            d.* = pack(r, g, b);
        }
    }

    // Vertical pass with per-row accumulators.
    var out = try Canvas.init(gpa, dw, dh);
    errdefer out.deinit(gpa);
    const acc = try gpa.alloc(u32, @as(usize, dw) * 3);
    defer gpa.free(acc);
    for (0..dh) |y| {
        @memset(acc, 0);
        const w = vy.weights[y * vy.max_taps ..][0..vy.count[y]];
        for (w, 0..) |wv, k| {
            const srow = tmp.pixels[(vy.start[y] + k) * dw ..][0..dw];
            for (srow, 0..) |p, x| {
                acc[x * 3 + 0] += ((p >> 16) & 0xff) * wv;
                acc[x * 3 + 1] += ((p >> 8) & 0xff) * wv;
                acc[x * 3 + 2] += (p & 0xff) * wv;
            }
        }
        const drow = out.pixels[y * dw ..][0..dw];
        for (drow, 0..) |*d, x| d.* = pack(acc[x * 3], acc[x * 3 + 1], acc[x * 3 + 2]);
    }
    return out;
}

inline fn pack(r: u32, g: u32, b: u32) u32 {
    const half = one / 2;
    const rr: u32 = @min((r + half) >> 14, 255);
    const gg: u32 = @min((g + half) >> 14, 255);
    const bb: u32 = @min((b + half) >> 14, 255);
    return 0xff000000 | (rr << 16) | (gg << 8) | bb;
}

test "halving averages 2x2 blocks" {
    const gpa = std.testing.allocator;
    var src = try Canvas.init(gpa, 4, 2);
    defer src.deinit(gpa);
    src.pixels[0..4].* = .{ 0xff000000, 0xffffffff, 0xff000000, 0xff000000 };
    src.pixels[4..8].* = .{ 0xffffffff, 0xff000000, 0xff000000, 0xff000000 };
    var out = try downscale(gpa, &src, 2, 1);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0xff808080), out.pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xff000000), out.pixels[1]);
}
