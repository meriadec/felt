//! Canvas: an owned or borrowed buffer of opaque ARGB pixels plus the basic
//! pixel operations (fill, copy, alpha blend, multiply, coverage masks, pixelate).
//! Every write takes a clip rectangle; callers never write outside it.
const std = @import("std");
const color = @import("color.zig");
const geom = @import("geom.zig");

const Color = color.Color;
const Pixel = color.Pixel;
const Rect = geom.Rect;

pub const Canvas = struct {
    width: u32,
    height: u32,
    pixels: []Pixel,

    /// Pixel contents are undefined. Big canvases bypass `gpa` (see bigAlloc).
    pub fn init(gpa: std.mem.Allocator, w: u32, h: u32) !Canvas {
        const n = @as(usize, w) * h;
        const px = if (n * 4 >= big_bytes) try bigAlloc(n) else try gpa.alloc(Pixel, n);
        return .{ .width = w, .height = h, .pixels = px };
    }

    pub fn deinit(self: *Canvas, gpa: std.mem.Allocator) void {
        if (self.pixels.len * 4 >= big_bytes) bigFree(self.pixels) else gpa.free(self.pixels);
        self.* = undefined;
    }

    pub fn clone(self: *const Canvas, gpa: std.mem.Allocator) !Canvas {
        const cv = try init(gpa, self.width, self.height);
        @memcpy(cv.pixels, self.pixels);
        return cv;
    }

    pub fn bounds(self: *const Canvas) Rect {
        return Rect.fromSize(0, 0, @intCast(self.width), @intCast(self.height));
    }

    pub inline fn at(self: *const Canvas, x: i32, y: i32) Pixel {
        return self.pixels[@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))];
    }

    pub fn row(self: *const Canvas, y: i32, x0: i32, x1: i32) []Pixel {
        const base = @as(usize, @intCast(y)) * self.width;
        return self.pixels[base + @as(usize, @intCast(x0)) .. base + @as(usize, @intCast(x1))];
    }

    pub fn fill(self: *Canvas, c: Color) void {
        @memset(self.pixels, c.toPixel());
    }

    /// Opaque write of `c` into `r`.
    pub fn fillRect(self: *Canvas, r: Rect, c: Color) void {
        const cr = r.intersect(self.bounds());
        if (cr.isEmpty()) return;
        var y = cr.y0;
        while (y < cr.y1) : (y += 1) @memset(self.row(y, cr.x0, cr.x1), c.toPixel());
    }

    /// Copy `r` from `src` (same size) into self.
    pub fn copyRect(self: *Canvas, src: *const Canvas, r: Rect) void {
        std.debug.assert(src.width == self.width and src.height == self.height);
        const cr = r.intersect(self.bounds());
        if (cr.isEmpty()) return;
        var y = cr.y0;
        while (y < cr.y1) : (y += 1) @memcpy(self.row(y, cr.x0, cr.x1), src.row(y, cr.x0, cr.x1));
    }

    /// Copy all of `src` into self with its top-left at (dx, dy), clipped.
    pub fn blit(self: *Canvas, src: *const Canvas, dx: i32, dy: i32) void {
        const dst = Rect.fromSize(dx, dy, @intCast(src.width), @intCast(src.height)).intersect(self.bounds());
        if (dst.isEmpty()) return;
        var y = dst.y0;
        while (y < dst.y1) : (y += 1) @memcpy(self.row(y, dst.x0, dst.x1), src.row(y - dy, dst.x0 - dx, dst.x1 - dx));
    }

    /// Source-over blend of `c` scaled by `cov` (0..255) into the pixel at `i`.
    pub inline fn blendAt(self: *Canvas, i: usize, c: Color, cov: u32) void {
        self.pixels[i] = blendPixel(self.pixels[i], c, cov * c.a);
    }

    /// Multiply blend (highlighter) of `c` with strength `cov` (0..255).
    pub inline fn multiplyAt(self: *Canvas, i: usize, c: Color, cov: u32) void {
        const d = self.pixels[i];
        const m = Color.fromPixel(d);
        const prod = Color{ .r = mul255(m.r, c.r), .g = mul255(m.g, c.g), .b = mul255(m.b, c.b) };
        self.pixels[i] = blendPixel(d, prod, cov * 255);
    }

    /// Blend a solid color over a rectangle.
    pub fn blendRect(self: *Canvas, r: Rect, c: Color) void {
        const cr = r.intersect(self.bounds());
        var y = cr.y0;
        while (y < cr.y1) : (y += 1) {
            for (self.row(y, cr.x0, cr.x1)) |*p| p.* = blendPixel(p.*, c, @as(u32, c.a) * 255);
        }
    }

    /// Blend `c` through an 8-bit coverage mask whose top-left is at (dx, dy).
    pub fn blendMask(self: *Canvas, mask: []const u8, mw: u32, mh: u32, dx: i32, dy: i32, c: Color, clip: Rect) void {
        const r = Rect.fromSize(dx, dy, @intCast(mw), @intCast(mh)).intersect(clip).intersect(self.bounds());
        if (r.isEmpty()) return;
        var y = r.y0;
        while (y < r.y1) : (y += 1) {
            const mrow = mask[@as(usize, @intCast(y - dy)) * mw ..];
            const base = @as(usize, @intCast(y)) * self.width;
            var x = r.x0;
            while (x < r.x1) : (x += 1) {
                const m = mrow[@intCast(x - dx)];
                if (m != 0) self.blendAt(base + @as(usize, @intCast(x)), c, m);
            }
        }
    }

    /// Replace `r` by blocks of `block` pixels, each the mean color of the block.
    /// Blocks align to `r`'s top-left so a partial redraw gives the same blocks;
    /// only pixels inside `clip` are written.
    pub fn pixelate(self: *Canvas, r: Rect, block: i32, clip: Rect) void {
        const area = r.intersect(self.bounds());
        if (area.isEmpty() or block < 1) return;
        const wclip = clip.intersect(area);
        if (wclip.isEmpty()) return;
        var by = r.y0;
        while (by < r.y1) : (by += block) {
            var bx = r.x0;
            while (bx < r.x1) : (bx += block) {
                const blk = Rect{ .x0 = bx, .y0 = by, .x1 = @min(bx + block, r.x1), .y1 = @min(by + block, r.y1) };
                const w = blk.intersect(wclip);
                if (w.isEmpty()) continue;
                const src = blk.intersect(area);
                var sr: u64 = 0;
                var sg: u64 = 0;
                var sb: u64 = 0;
                var y = src.y0;
                while (y < src.y1) : (y += 1) {
                    for (self.row(y, src.x0, src.x1)) |p| {
                        sr += (p >> 16) & 0xff;
                        sg += (p >> 8) & 0xff;
                        sb += p & 0xff;
                    }
                }
                const n = src.area();
                const avg = Color{ .r = @intCast(sr / n), .g = @intCast(sg / n), .b = @intCast(sb / n) };
                self.fillRect(w, avg);
            }
        }
    }
};

/// Canvases from this size up get their own mapping with transparent huge
/// pages: a 4K frame faults in 16 pages instead of 8100 (zig build bench).
const big_bytes = 4 << 20;
const huge_page = 2 << 20;

fn bigAlloc(n: usize) ![]Pixel {
    const len = std.mem.alignForward(usize, n * 4, huge_page);
    const mem = std.posix.mmap(null, len, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch return error.OutOfMemory;
    std.posix.madvise(mem.ptr, len, std.posix.MADV.HUGEPAGE) catch {};
    const px: [*]Pixel = @ptrCast(mem.ptr);
    return px[0..n];
}

fn bigFree(px: []Pixel) void {
    const len = std.mem.alignForward(usize, px.len * 4, huge_page);
    const p: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(px.ptr));
    std.posix.munmap(p[0..len]);
}

inline fn mul255(a: u8, b: u8) u8 {
    const x = @as(u32, a) * b + 128;
    return @intCast((x + (x >> 8)) >> 8);
}

/// Blend `src` over opaque `dst` with alpha `a16` in 0..255*255.
pub inline fn blendPixel(dst: Pixel, src: Color, a16: u32) Pixel {
    if (a16 == 0) return dst;
    if (a16 >= 255 * 255) return src.withAlpha(255).toPixel();
    const a = (a16 + 128) / 255; // 0..255
    const ia = 255 - a;
    const dr = (dst >> 16) & 0xff;
    const dg = (dst >> 8) & 0xff;
    const db = dst & 0xff;
    const r = div255(@as(u32, src.r) * a + dr * ia);
    const g = div255(@as(u32, src.g) * a + dg * ia);
    const b = div255(@as(u32, src.b) * a + db * ia);
    return 0xff000000 | (r << 16) | (g << 8) | b;
}

inline fn div255(x: u32) u32 {
    return (x + 128 + ((x + 128) >> 8)) >> 8;
}

test "blend" {
    const red = Color.rgb(0xff0000);
    try std.testing.expectEqual(@as(Pixel, 0xffff0000), blendPixel(0xff000000, red, 255 * 255));
    try std.testing.expectEqual(@as(Pixel, 0xff000000), blendPixel(0xff000000, red, 0));
    const half = blendPixel(0xff000000, red, 255 * 128);
    try std.testing.expectEqual(@as(u32, 128), (half >> 16) & 0xff);
}

test "pixelate averages blocks" {
    const gpa = std.testing.allocator;
    var cv = try Canvas.init(gpa, 4, 2);
    defer cv.deinit(gpa);
    cv.fill(color.black);
    cv.fillRect(Rect.fromSize(0, 0, 1, 2), color.white);
    cv.pixelate(cv.bounds(), 2, cv.bounds());
    try std.testing.expectEqual(@as(u32, 0xff7f7f7f), cv.pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xff000000), cv.pixels[3]);
}
