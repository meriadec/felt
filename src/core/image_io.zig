//! Image files: decode (PNG, JPEG, BMP via stb_image) into an opaque Canvas,
//! and encode a Canvas to PNG (file or memory, via stb_image_write).
//! Transparent pixels are flattened over white: the pipeline is opaque.
const std = @import("std");
const c = @import("c.zig").c;
const Canvas = @import("canvas.zig").Canvas;

pub const Error = error{ DecodeFailed, EncodeFailed, OutOfMemory };

/// Decode an encoded image held in memory.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) Error!Canvas {
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

fn toRgba(gpa: std.mem.Allocator, cv: *const Canvas) ![]u32 {
    const out = try gpa.alloc(u32, cv.pixels.len);
    for (cv.pixels, out) |p, *o| {
        o.* = (p & 0xff00ff00) | ((p >> 16) & 0xff) | ((p & 0xff) << 16);
    }
    return out;
}

/// Encode to PNG in memory. Caller owns the bytes.
pub fn encodePng(gpa: std.mem.Allocator, cv: *const Canvas) ![]u8 {
    const rgba = try toRgba(gpa, cv);
    defer gpa.free(rgba);
    var sink = Sink{ .gpa = gpa };
    errdefer sink.buf.deinit(gpa);
    const ok = c.stbi_write_png_to_func(Sink.write, &sink, @intCast(cv.width), @intCast(cv.height), 4, rgba.ptr, @intCast(cv.width * 4));
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
    const png = try encodePng(gpa, &cv);
    defer gpa.free(png);
    var back = try decode(gpa, png);
    defer back.deinit(gpa);
    try std.testing.expectEqualSlices(u32, cv.pixels, back.pixels);
}
