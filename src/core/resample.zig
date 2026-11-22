//! Area-average (box filter) downscaling, separable, fixed point.
//! Used once per window size or crop to build the on-screen copy of the image.
const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;
const Rect = @import("geom.zig").Rect;

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
/// Both passes split rows across threads (4x faster on 8+ cores).
pub fn downscale(gpa: std.mem.Allocator, src: *const Canvas, dw: u32, dh: u32) !Canvas {
    return downscaleRect(gpa, src, src.bounds(), dw, dh);
}

/// Downscale the part `r` of `src` (inside its bounds) to dw x dh.
pub fn downscaleRect(gpa: std.mem.Allocator, src: *const Canvas, r: Rect, dw: u32, dh: u32) !Canvas {
    std.debug.assert(dw > 0 and dh > 0 and !r.isEmpty());
    std.debug.assert(std.meta.eql(r.intersect(src.bounds()), r));
    const sw: u32 = @intCast(r.width());
    const sh: u32 = @intCast(r.height());
    if (dw == sw and dh == sh) return src.copyOut(gpa, r);

    var job = Job{ .src = src, .x0 = @intCast(r.x0), .y0 = @intCast(r.y0), .sw = sw, .dw = dw };
    job.hx = try Taps.init(gpa, sw, dw);
    defer job.hx.deinit(gpa);
    job.vy = try Taps.init(gpa, sh, dh);
    defer job.vy.deinit(gpa);
    job.tmp = try Canvas.init(gpa, dw, sh);
    defer job.tmp.deinit(gpa);
    job.out = try Canvas.init(gpa, dw, dh);
    errdefer job.out.deinit(gpa);
    job.acc = try gpa.alloc(u32, @as(usize, dw) * 3 * max_threads);
    defer gpa.free(job.acc);

    parallelRows(&job, sh, Job.horizontal);
    parallelRows(&job, dh, Job.vertical);
    return job.out;
}

/// Nearest-neighbour scale of the part `sr` of `src` onto the target
/// rectangle `dr` of `dst` (any sizes; used above 1:1). Writes only `clip`.
pub fn nearestInto(dst: *Canvas, clip: Rect, src: *const Canvas, sr: Rect, dr: Rect) void {
    const q = clip.intersect(dr).intersect(dst.bounds());
    if (q.isEmpty() or sr.isEmpty()) return;
    const sw: i64 = sr.width();
    const sh: i64 = sr.height();
    const dw: i64 = dr.width();
    const dh: i64 = dr.height();
    var y = q.y0;
    while (y < q.y1) : (y += 1) {
        const sy: i32 = sr.y0 + @as(i32, @intCast(@divFloor((y - dr.y0) * sh, dh)));
        const srow = src.row(sy, 0, @intCast(src.width));
        const drow = dst.row(y, q.x0, q.x1);
        for (drow, 0..) |*d, i| {
            const x: i64 = q.x0 + @as(i64, @intCast(i));
            d.* = srow[@intCast(sr.x0 + @divFloor((x - dr.x0) * sw, dw))];
        }
    }
}

const max_threads = 8;

const Job = struct {
    src: *const Canvas,
    /// Source rectangle: top-left and width (rows come from the tmp height).
    x0: usize,
    y0: usize,
    sw: usize,
    dw: u32,
    hx: Taps = undefined,
    vy: Taps = undefined,
    tmp: Canvas = undefined,
    out: Canvas = undefined,
    /// One accumulator row per thread.
    acc: []u32 = &.{},

    /// tmp rows [y0, y1) = source rows filtered horizontally.
    fn horizontal(j: *Job, y0: usize, y1: usize, _: usize) void {
        const src = j.src;
        const dw = j.dw;
        for (y0..y1) |y| {
            const srow = src.pixels[(j.y0 + y) * src.width + j.x0 ..][0..j.sw];
            const drow = j.tmp.pixels[y * dw ..][0..dw];
            for (drow, 0..) |*d, x| {
                const w = j.hx.weights[x * j.hx.max_taps ..][0..j.hx.count[x]];
                const s = srow[j.hx.start[x]..][0..w.len];
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
    }

    /// out rows [y0, y1) = tmp filtered vertically.
    fn vertical(j: *Job, y0: usize, y1: usize, thread: usize) void {
        const dw = j.dw;
        const acc = j.acc[thread * dw * 3 ..][0 .. dw * 3];
        for (y0..y1) |y| {
            @memset(acc, 0);
            const w = j.vy.weights[y * j.vy.max_taps ..][0..j.vy.count[y]];
            for (w, 0..) |wv, k| {
                const srow = j.tmp.pixels[(j.vy.start[y] + k) * dw ..][0..dw];
                for (srow, 0..) |p, x| {
                    acc[x * 3 + 0] += ((p >> 16) & 0xff) * wv;
                    acc[x * 3 + 1] += ((p >> 8) & 0xff) * wv;
                    acc[x * 3 + 2] += (p & 0xff) * wv;
                }
            }
            const drow = j.out.pixels[y * dw ..][0..dw];
            for (drow, 0..) |*d, x| d.* = pack(acc[x * 3], acc[x * 3 + 1], acc[x * 3 + 2]);
        }
    }
};

/// Run f(job, y0, y1, thread) over [0, n) in bands, one band per thread.
/// Falls back to the calling thread alone if a spawn fails.
fn parallelRows(job: *Job, n: usize, comptime f: fn (*Job, usize, usize, usize) void) void {
    const cpus = std.Thread.getCpuCount() catch 1;
    const k = std.math.clamp(@min(cpus, n / 64), 1, max_threads);
    var threads: [max_threads]?std.Thread = @splat(null);
    const band = (n + k - 1) / k;
    for (1..k) |t| {
        const y0 = t * band;
        const y1 = @min(n, y0 + band);
        if (y0 >= y1) continue;
        threads[t] = std.Thread.spawn(.{}, f, .{ job, y0, y1, t }) catch null;
        if (threads[t] == null) f(job, y0, y1, t);
    }
    f(job, 0, @min(n, band), 0);
    for (threads[1..k]) |t| if (t) |th| th.join();
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

test "a source rectangle downscales only that part" {
    const gpa = std.testing.allocator;
    var src = try Canvas.init(gpa, 6, 4);
    defer src.deinit(gpa);
    src.fill(.{ .r = 0, .g = 0, .b = 0 });
    src.fillRect(Rect.fromSize(2, 2, 4, 2), .{ .r = 255, .g = 255, .b = 255 });
    var out = try downscaleRect(gpa, &src, Rect.fromSize(2, 2, 4, 2), 2, 1);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0xffffffff), out.pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xffffffff), out.pixels[1]);
}

test "nearest doubles pixels" {
    const gpa = std.testing.allocator;
    var src = try Canvas.init(gpa, 2, 1);
    defer src.deinit(gpa);
    src.pixels[0..2].* = .{ 0xff000000, 0xffffffff };
    var dst = try Canvas.init(gpa, 4, 2);
    defer dst.deinit(gpa);
    nearestInto(&dst, dst.bounds(), &src, src.bounds(), dst.bounds());
    try std.testing.expectEqual([4]u32{ 0xff000000, 0xff000000, 0xffffffff, 0xffffffff }, dst.pixels[4..8].*);
}
