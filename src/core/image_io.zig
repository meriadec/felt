//! Image files: decode (PNG, JPEG, BMP via stb_image) into an opaque Canvas,
//! and encode a Canvas to PNG (file or memory, via stb_image_write).
//! Transparent pixels are flattened over white: the pipeline is opaque.
const std = @import("std");
const c = @import("c.zig").c;
const Canvas = @import("canvas.zig").Canvas;
const png = @import("png.zig");

pub const Error = error{ DecodeFailed, EncodeFailed, OutOfMemory };

/// Decode an encoded image held in memory: fast path for common PNGs, stb for the rest.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) Error!Canvas {
    return png.decode(gpa, bytes) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Unsupported, error.Corrupt => decodeStb(gpa, bytes),
    };
}

pub fn decodeStb(gpa: std.mem.Allocator, bytes: []const u8) Error!Canvas {
    var w: c_int = 0;
    var h: c_int = 0;
    var n: c_int = 0;
    const data = c.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &n, 4) orelse return error.DecodeFailed;
    defer c.stbi_image_free(data);
    const cv = try Canvas.init(gpa, @intCast(w), @intCast(h));
    const src: [*]const u32 = @ptrCast(@alignCast(data));
    for (cv.pixels, 0..) |*dst, i| dst.* = rgbaToPixel(src[i]);
    return cv;
}

/// Read and decode an image file.
pub fn load(gpa: std.mem.Allocator, path: []const u8) !Canvas {
    const bytes = try std.fs.cwd().readFileAlloc(gpa, path, 512 * 1024 * 1024);
    defer gpa.free(bytes);
    return decode(gpa, bytes);
}

/// Width and height of an image file, read from its header (no decode).
pub fn info(gpa: std.mem.Allocator, path: []const u8) !struct { w: u32, h: u32 } {
    const z = try gpa.dupeZ(u8, path);
    defer gpa.free(z);
    var w: c_int = 0;
    var h: c_int = 0;
    var n: c_int = 0;
    if (c.stbi_info(z.ptr, &w, &h, &n) == 0 or w <= 0 or h <= 0) return error.DecodeFailed;
    return .{ .w = @intCast(w), .h = @intCast(h) };
}

/// RGBA bytes in memory (little-endian u32 = 0xAABBGGRR) to an opaque pixel.
inline fn rgbaToPixel(v: u32) u32 {
    const a = v >> 24;
    var r = v & 0xff;
    var g = (v >> 8) & 0xff;
    var b = (v >> 16) & 0xff;
    if (a != 255) { // flatten over white
        r = (r * a + 255 * (255 - a) + 127) / 255;
        g = (g * a + 255 * (255 - a) + 127) / 255;
        b = (b * a + 255 * (255 - a) + 127) / 255;
    }
    return 0xff000000 | (r << 16) | (g << 8) | b;
}

/// Opaque pixels to packed RGB bytes (PNG color type 2: 25% less to compress).
fn toRgb(gpa: std.mem.Allocator, cv: *const Canvas) ![]u8 {
    const out = try gpa.alloc(u8, cv.pixels.len * 3);
    for (cv.pixels, 0..) |p, i| {
        out[i * 3 + 0] = @truncate(p >> 16);
        out[i * 3 + 1] = @truncate(p >> 8);
        out[i * 3 + 2] = @truncate(p);
    }
    return out;
}

/// Encode to PNG in memory. Caller owns the bytes.
pub fn encodePng(gpa: std.mem.Allocator, cv: *const Canvas) ![]u8 {
    return png.encode(gpa, cv);
}

/// stb_image_write encoder, kept for comparison (tests, --bench).
pub fn encodePngStb(gpa: std.mem.Allocator, cv: *const Canvas) ![]u8 {
    const rgb = try toRgb(gpa, cv);
    defer gpa.free(rgb);
    var sink = Sink{ .gpa = gpa };
    errdefer sink.buf.deinit(gpa);
    // Level 2 is ~30% faster than stb's default 8 for <2% bigger files (zig build bench).
    c.stbi_write_png_compression_level = 2;
    const ok = c.stbi_write_png_to_func(Sink.write, &sink, @intCast(cv.width), @intCast(cv.height), 3, rgb.ptr, @intCast(cv.width * 3));
    if (ok == 0 or sink.failed) return error.EncodeFailed;
    return sink.buf.toOwnedSlice(gpa);
}

/// Encode to PNG and write the file atomically (temp file + rename).
pub fn savePng(gpa: std.mem.Allocator, cv: *const Canvas, path: []const u8) !void {
    const bytes = try encodePng(gpa, cv);
    defer gpa.free(bytes);
    var buf: [4096]u8 = undefined;
    var af = try std.fs.cwd().atomicFile(path, .{ .write_buffer = &buf });
    defer af.deinit();
    try af.file_writer.interface.writeAll(bytes);
    try af.finish();
}

const Sink = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    failed: bool = false,

    fn write(ctx: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        const bytes: [*]const u8 = @ptrCast(data.?);
        self.buf.appendSlice(self.gpa, bytes[0..@intCast(size)]) catch {
            self.failed = true;
        };
    }
};

test "png round trip" {
    const gpa = std.testing.allocator;
    var cv = try Canvas.init(gpa, 3, 2);
    defer cv.deinit(gpa);
    for (cv.pixels, 0..) |*p, i| p.* = 0xff000000 | @as(u32, @intCast(i * 0x102030));
    const bytes = try encodePng(gpa, &cv);
    defer gpa.free(bytes);
    var back = try decode(gpa, bytes);
    defer back.deinit(gpa);
    try std.testing.expectEqualSlices(u32, cv.pixels, back.pixels);
    // stb path agrees with the fast path.
    const stb_bytes = try encodePngStb(gpa, &cv);
    defer gpa.free(stb_bytes);
    var via_stb = try decodeStb(gpa, bytes);
    defer via_stb.deinit(gpa);
    try std.testing.expectEqualSlices(u32, cv.pixels, via_stb.pixels);
    var fast_of_stb = try png.decode(gpa, stb_bytes);
    defer fast_of_stb.deinit(gpa);
    try std.testing.expectEqualSlices(u32, cv.pixels, fast_of_stb.pixels);
}

test "info reads the header of a file" {
    const gpa = std.testing.allocator;
    var cv = try Canvas.init(gpa, 7, 3);
    defer cv.deinit(gpa);
    @memset(cv.pixels, 0xff102030);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "a.png" });
    defer gpa.free(path);
    try savePng(gpa, &cv, path);
    const i = try info(gpa, path);
    try std.testing.expectEqual(@as(u32, 7), i.w);
    try std.testing.expectEqual(@as(u32, 3), i.h);
    try std.testing.expectError(error.DecodeFailed, info(gpa, "/nonexistent.png"));
}
