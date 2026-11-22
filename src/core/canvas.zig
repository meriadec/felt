//! Canvas: an owned or borrowed buffer of opaque ARGB pixels plus the basic
//! pixel operations (fill, copy, alpha blend, coverage masks, pixelate).
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

    /// New canvas holding the part `r` of self (inside its bounds).
    pub fn copyOut(self: *const Canvas, gpa: std.mem.Allocator, r: Rect) !Canvas {
        std.debug.assert(std.meta.eql(r.intersect(self.bounds()), r) and !r.isEmpty());
        var cv = try init(gpa, @intCast(r.width()), @intCast(r.height()));
        cv.blitRect(self, r, 0, 0);
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
        self.blitRect(src, src.bounds(), dx, dy);
    }

    /// Copy the part `sr` of `src` (inside its bounds) into self with its
    /// top-left at (dx, dy), clipped.
    pub fn blitRect(self: *Canvas, src: *const Canvas, sr: Rect, dx: i32, dy: i32) void {
        const dst = Rect.fromSize(dx, dy, sr.width(), sr.height()).intersect(self.bounds());
        if (dst.isEmpty()) return;
        const ox = sr.x0 - dx;
        const oy = sr.y0 - dy;
        var y = dst.y0;
        while (y < dst.y1) : (y += 1) @memcpy(self.row(y, dst.x0, dst.x1), src.row(y + oy, dst.x0 + ox, dst.x1 + ox));
    }

    /// Move the contents by (dx, dy) whole pixels. Pixels moved in from
    /// outside are left as they were: the caller repaints those strips.
    pub fn scroll(self: *Canvas, dx: i32, dy: i32) void {
        const w: i32 = @intCast(self.width);
        const h: i32 = @intCast(self.height);
        if (@abs(dx) >= w or @abs(dy) >= h or (dx == 0 and dy == 0)) return;
        const n: usize = @intCast(w - @as(i32, @intCast(@abs(dx))));
        const sx: usize = @intCast(@max(0, -dx));
        const tx: usize = @intCast(@max(0, dx));
        const W: usize = self.width;
        if (dy > 0) {
            var y = h - 1;
            while (y >= dy) : (y -= 1) {
                const d = @as(usize, @intCast(y)) * W;
                const src = @as(usize, @intCast(y - dy)) * W;
                @memcpy(self.pixels[d + tx ..][0..n], self.pixels[src + sx ..][0..n]);
            }
        } else if (dy < 0) {
            var y: i32 = 0;
            while (y < h + dy) : (y += 1) {
                const d = @as(usize, @intCast(y)) * W;
                const src = @as(usize, @intCast(y - dy)) * W;
                @memcpy(self.pixels[d + tx ..][0..n], self.pixels[src + sx ..][0..n]);
            }
        } else {
            for (0..self.height) |y| {
                const r = self.pixels[y * W ..][0..W];
                if (dx < 0) std.mem.copyForwards(Pixel, r[0..n], r[sx..][0..n]) else std.mem.copyBackwards(Pixel, r[tx..][0..n], r[0..n]);
            }
        }
    }

    /// Source-over blend of `c` scaled by `cov` (0..255) into the pixel at `i`.
    pub inline fn blendAt(self: *Canvas, i: usize, c: Color, cov: u32) void {
        self.pixels[i] = blendPixel(self.pixels[i], c, cov * c.a);
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
    /// only pixels inside `limit` are read and only pixels inside `clip` are written.
    pub fn pixelate(self: *Canvas, r: Rect, block: i32, limit: Rect, clip: Rect) void {
        const area = r.intersect(self.bounds()).intersect(limit);
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

/// Byte buffer with the same big-allocation policy as canvases.
pub fn allocBytes(gpa: std.mem.Allocator, n: usize) ![]u8 {
    if (n >= big_bytes) {
        const px = try bigAlloc((n + 3) / 4);
        return std.mem.sliceAsBytes(px)[0..n];
    }
    return gpa.alloc(u8, n);
}

pub fn freeBytes(gpa: std.mem.Allocator, b: []u8) void {
    if (b.len >= big_bytes) {
        const px: [*]Pixel = @ptrCast(@alignCast(b.ptr));
        bigFree(px[0 .. (b.len + 3) / 4]);
    } else gpa.free(b);
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
    cv.pixelate(cv.bounds(), 2, cv.bounds(), cv.bounds());
    try std.testing.expectEqual(@as(u32, 0xff7f7f7f), cv.pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xff000000), cv.pixels[3]);
}

test "scroll moves pixels in every direction" {
    const gpa = std.testing.allocator;
    var cv = try Canvas.init(gpa, 4, 3);
    defer cv.deinit(gpa);
    const moves = [_][2]i32{ .{ 1, 0 }, .{ -2, 0 }, .{ 0, 1 }, .{ 0, -1 }, .{ 1, -2 }, .{ -3, 2 } };
    for (moves) |m| {
        for (cv.pixels, 0..) |*p, i| p.* = @intCast(i);
        cv.scroll(m[0], m[1]);
        var y: i32 = 0;
        while (y < 3) : (y += 1) {
            var x: i32 = 0;
            while (x < 4) : (x += 1) {
                const sx = x - m[0];
                const sy = y - m[1];
                if (sx < 0 or sy < 0 or sx >= 4 or sy >= 3) continue;
                try std.testing.expectEqual(@as(u32, @intCast(sy * 4 + sx)), cv.at(x, y));
            }
        }
    }
}
