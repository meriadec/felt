//! Fast PNG codec for the common case: 8-bit RGB or RGBA, not interlaced
//! (what screenshot tools write). zlib streams via libdeflate. Any other PNG
//! gives error.Unsupported and image_io falls back to stb_image.
const std = @import("std");
const c = @import("c.zig").c;
const canvas_mod = @import("canvas.zig");
const Canvas = canvas_mod.Canvas;

const signature = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

pub const DecodeError = error{ Unsupported, Corrupt, OutOfMemory };

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) DecodeError!Canvas {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &signature)) return error.Unsupported;
    var w: u32 = 0;
    var h: u32 = 0;
    var bpp: usize = 0;
    var idat_len: usize = 0;
    var idat_count: usize = 0;
    var first_idat: []const u8 = &.{};

    // Pass 1: header and IDAT size.
    var pos: usize = 8;
    while (pos + 12 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const kind = bytes[pos + 4 ..][0..4];
        if (pos + 12 + len > bytes.len) return error.Corrupt;
        const body = bytes[pos + 8 ..][0..len];
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len != 13) return error.Corrupt;
            w = std.mem.readInt(u32, body[0..4], .big);
            h = std.mem.readInt(u32, body[4..8], .big);
            const depth = body[8];
            const color_type = body[9];
            const interlace = body[12];
            if (depth != 8 or interlace != 0) return error.Unsupported;
            bpp = switch (color_type) {
                2 => 3,
                6 => 4,
                else => return error.Unsupported,
            };
            if (w == 0 or h == 0 or w > 1 << 15 or h > 1 << 15) return error.Unsupported;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            if (idat_count == 0) first_idat = body;
            idat_len += len;
            idat_count += 1;
        } else if (std.mem.eql(u8, kind, "IEND")) break;
        pos += 12 + len;
    }
    if (bpp == 0 or idat_count == 0) return error.Corrupt;

    // One contiguous zlib stream.
    var joined: ?[]u8 = null;
    defer if (joined) |j| gpa.free(j);
    const zdata: []const u8 = if (idat_count == 1) first_idat else blk: {
        const buf = try gpa.alloc(u8, idat_len);
        joined = buf;
        var at: usize = 0;
        pos = 8;
        while (pos + 12 <= bytes.len) {
            const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
            if (std.mem.eql(u8, bytes[pos + 4 ..][0..4], "IDAT")) {
                @memcpy(buf[at..][0..len], bytes[pos + 8 ..][0..len]);
                at += len;
            }
            pos += 12 + len;
        }
        break :blk buf;
    };

    const stride = @as(usize, w) * bpp;
    const raw = try canvas_mod.allocBytes(gpa, (stride + 1) * h);
    defer canvas_mod.freeBytes(gpa, raw);
    const d = c.libdeflate_alloc_decompressor() orelse return error.OutOfMemory;
    defer c.libdeflate_free_decompressor(d);
    var actual: usize = 0;
    if (c.libdeflate_zlib_decompress(d, zdata.ptr, zdata.len, raw.ptr, raw.len, &actual) != c.LIBDEFLATE_SUCCESS or actual != raw.len)
        return error.Corrupt;

    var cv = try Canvas.init(gpa, w, h);
    errdefer cv.deinit(gpa);
    switch (bpp) {
        inline 3, 4 => |n| try unfilter(n, raw, &cv),
        else => unreachable,
    }
    return cv;
}

/// Undo PNG row filters in place and convert each row to pixels.
fn unfilter(comptime bpp: usize, raw: []u8, cv: *Canvas) DecodeError!void {
    const V = @Vector(bpp, u8);
    const W = @Vector(bpp, u16);
    const stride = @as(usize, cv.width) * bpp;
    const h = cv.height;
    var y: usize = 0;
    while (y < h) {
        const row = raw[y * (stride + 1) ..][0 .. stride + 1];
        const cur = row[1..];
        const first = y == 0;
        const prev: []const u8 = if (first) &.{} else raw[(y - 1) * (stride + 1) + 1 ..][0..stride];
        switch (row[0]) {
            0 => {},
            1 => {
                var a: V = @splat(0);
                var i: usize = 0;
                while (i < stride) : (i += bpp) {
                    a +%= @as(V, cur[i..][0..bpp].*);
                    cur[i..][0..bpp].* = a;
                }
            },
            2 => if (!first) addRows(cur, prev),
            3 => {
                var a: W = @splat(0);
                var i: usize = 0;
                while (i < stride) : (i += bpp) {
                    const b: W = if (first) @splat(0) else @as(V, prev[i..][0..bpp].*);
                    const x: W = @as(V, cur[i..][0..bpp].*);
                    a = (x + ((a + b) >> @splat(1))) & @as(W, @splat(0xff));
                    cur[i..][0..bpp].* = @as(V, @intCast(a));
                }
            },
            4 => if (first) {
                paethRows(bpp, 1, &.{cur}, null);
            } else {
                // Runs of Paeth rows go 4 at a time: 4 independent dependency chains.
                var k: usize = 1;
                while (k < paeth_group and y + k < h and raw[(y + k) * (stride + 1)] == 4) k += 1;
                if (k == paeth_group) {
                    var rows: [paeth_group][]u8 = undefined;
                    for (&rows, 0..) |*r, t| r.* = raw[(y + t) * (stride + 1) + 1 ..][0..stride];
                    paethRows(bpp, paeth_group, &rows, prev);
                    y += paeth_group;
                    continue;
                }
                paethRows(bpp, 1, &.{cur}, prev);
            },
            else => return error.Corrupt,
        }
        y += 1;
    }
    convertRows(bpp, raw, cv, 0, h);
}

/// Unfiltered rows [y0, y1) to opaque pixels (alpha flattened over white).
fn convertRows(comptime bpp: usize, raw: []const u8, cv: *Canvas, y0: usize, y1: usize) void {
    const w = cv.width;
    const stride = @as(usize, w) * bpp;
    for (y0..y1) |y| {
        const cur = raw[y * (stride + 1) + 1 ..][0..stride];
        const out = cv.pixels[y * w ..][0..w];
        for (out, 0..) |*px, x| {
            const s = cur[x * bpp ..][0..bpp];
            var r: u32 = s[0];
            var g: u32 = s[1];
            var b: u32 = s[2];
            if (bpp == 4 and s[3] != 255) {
                const a: u32 = s[3];
                r = (r * a + 255 * (255 - a) + 127) / 255;
                g = (g * a + 255 * (255 - a) + 127) / 255;
                b = (b * a + 255 * (255 - a) + 127) / 255;
            }
            px.* = 0xff000000 | (r << 16) | (g << 8) | b;
        }
    }
}

const paeth_group = 4;

/// Undo the Paeth filter on `k` consecutive rows, row t lagging t pixels
/// behind row t-1, so the k per-pixel dependency chains run in parallel
/// (1.7x on a 4K screenshot). `above` is the row before rows[0] (null: none).
fn paethRows(comptime bpp: usize, comptime k: usize, rows: *const [k][]u8, above: ?[]const u8) void {
    const V = @Vector(bpp, i32);
    const U = @Vector(bpp, u8);
    const z: V = @splat(0);
    var a: [k]V = @splat(z);
    var upleft: [k]V = @splat(z);
    const n = rows[0].len / bpp;
    var x: usize = 0;
    while (x < n + k - 1) : (x += 1) {
        inline for (0..k) |t| {
            if (x >= t and x - t < n) {
                const i = (x - t) * bpp;
                const up: ?[]const u8 = if (t == 0) above else rows[t - 1];
                const b: V = if (up) |u| @as(U, u[i..][0..bpp].*) else z;
                const v = paethPixel(bpp, a[t], b, upleft[t], @as(U, rows[t][i..][0..bpp].*));
                rows[t][i..][0..bpp].* = @as(U, @intCast(v));
                a[t] = v;
                upleft[t] = b;
            }
        }
    }
}

/// cur += prev, bytewise. Explicit 32-byte vectors: with Zig 0.17 (LLVM 21+)
/// the plain loop is no longer auto-vectorized here (12x slower).
fn addRows(cur: []u8, prev: []const u8) void {
    const L = 32;
    var i: usize = 0;
    while (i + L <= cur.len) : (i += L) {
        const a: @Vector(L, u8) = cur[i..][0..L].*;
        const b: @Vector(L, u8) = prev[i..][0..L].*;
        cur[i..][0..L].* = a +% b;
    }
    while (i < cur.len) : (i += 1) cur[i] +%= prev[i];
}

inline fn paethPixel(comptime bpp: usize, a: @Vector(bpp, i32), b: @Vector(bpp, i32), ul: @Vector(bpp, i32), x: @Vector(bpp, i32)) @Vector(bpp, i32) {
    const bc = b - ul;
    const ac = a - ul;
    const pa = @abs(bc);
    const pb = @abs(ac);
    const pc = @abs(ac + bc);
    const pred = @select(i32, (pa <= pb) & (pa <= pc), a, @select(i32, pb <= pc, b, ul));
    return (x + pred) & @as(@Vector(bpp, i32), @splat(0xff));
}

/// Encode an opaque canvas as an 8-bit RGB PNG. Caller owns the bytes.
pub fn encode(gpa: std.mem.Allocator, cv: *const Canvas) ![]u8 {
    const w = cv.width;
    const h = cv.height;
    const stride = @as(usize, w) * 3;
    const raw = try canvas_mod.allocBytes(gpa, (stride + 1) * h);
    defer canvas_mod.freeBytes(gpa, raw);
    const rgb_prev = try gpa.alloc(u8, stride);
    defer gpa.free(rgb_prev);
    const rgb_cur = try gpa.alloc(u8, stride);
    defer gpa.free(rgb_cur);
    @memset(rgb_prev, 0);

    for (0..h) |y| {
        const src = cv.pixels[y * w ..][0..w];
        for (src, 0..) |p, x| {
            rgb_cur[x * 3 + 0] = @truncate(p >> 16);
            rgb_cur[x * 3 + 1] = @truncate(p >> 8);
            rgb_cur[x * 3 + 2] = @truncate(p);
        }
        const row = raw[y * (stride + 1) ..][0 .. stride + 1];
        filterRow(row, rgb_cur, rgb_prev);
        @memcpy(rgb_prev, rgb_cur);
    }

    const comp = c.libdeflate_alloc_compressor(encode_level) orelse return error.OutOfMemory;
    defer c.libdeflate_free_compressor(comp);
    const bound = c.libdeflate_zlib_compress_bound(comp, raw.len);
    const head_len = 8 + 25 + 8; // signature, IHDR chunk, IDAT length + type
    const out = try gpa.alloc(u8, head_len + bound + 4 + 12);
    errdefer gpa.free(out);
    const n = c.libdeflate_zlib_compress(comp, raw.ptr, raw.len, out.ptr + head_len, bound);
    if (n == 0) return error.EncodeFailed;

    @memcpy(out[0..8], &signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8..13].* = .{ 8, 2, 0, 0, 0 };
    writeChunkHead(out[8..], "IHDR", 13);
    @memcpy(out[16..29], &ihdr);
    writeCrc(out[12..29], out[29..33]);
    writeChunkHead(out[33..], "IDAT", @intCast(n));
    var at = head_len + n;
    writeCrc(out[37..at], out[at..][0..4]);
    at += 4;
    writeChunkHead(out[at..], "IEND", 0);
    writeCrc(out[at + 4 .. at + 8], out[at + 8 ..][0..4]);
    at += 12;
    if (!gpa.resize(out, at)) {
        const exact = try gpa.dupe(u8, out[0..at]);
        gpa.free(out);
        return exact;
    }
    return out[0..at];
}

/// libdeflate level: 1 is ~5x faster than 6 for ~10% bigger screenshots (docs/perf.md).
const encode_level = 1;

fn writeChunkHead(dst: []u8, kind: *const [4]u8, len: u32) void {
    std.mem.writeInt(u32, dst[0..4], len, .big);
    @memcpy(dst[4..8], kind);
}

fn writeCrc(type_and_data: []const u8, dst: []u8) void {
    const crc: u32 = @intCast(c.libdeflate_crc32(0, type_and_data.ptr, type_and_data.len));
    std.mem.writeInt(u32, dst[0..4], crc, .big);
}

/// Pick the filter with the smallest sum of |signed byte| (libpng heuristic)
/// among Sub, Up and Paeth, and write it to `row` (filter byte + data).
fn filterRow(row: []u8, cur: []const u8, prev: []const u8) void {
    const out = row[1..];
    var best: u8 = 1;
    var best_cost: u64 = std.math.maxInt(u64);
    inline for (.{ 1, 2, 4 }) |ft| {
        var cost: u64 = 0;
        for (cur, 0..) |x, i| {
            const a: u8 = if (i >= 3) cur[i - 3] else 0;
            const b: u8 = prev[i];
            const cc: u8 = if (i >= 3) prev[i - 3] else 0;
            const v: u8 = x -% switch (ft) {
                1 => a,
                2 => b,
                else => paeth(a, b, cc),
            };
            cost += @abs(@as(i8, @bitCast(v)));
        }
        if (cost < best_cost) {
            best_cost = cost;
            best = ft;
        }
    }
    row[0] = best;
    for (cur, 0..) |x, i| {
        const a: u8 = if (i >= 3) cur[i - 3] else 0;
        const b: u8 = prev[i];
        const cc: u8 = if (i >= 3) prev[i - 3] else 0;
        out[i] = x -% switch (best) {
            1 => a,
            2 => b,
            else => paeth(a, b, cc),
        };
    }
}

inline fn paeth(a: u8, b: u8, cc: u8) u8 {
    const p = @as(i16, a) + b - cc;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - cc);
    return if (pa <= pb and pa <= pc) a else if (pb <= pc) b else cc;
}

test "encode then decode round trip, stb agrees" {
    const gpa = std.testing.allocator;
    var cv = try Canvas.init(gpa, 37, 23);
    defer cv.deinit(gpa);
    var rng = std.Random.DefaultPrng.init(1);
    for (cv.pixels, 0..) |*p, i| {
        const v: u32 = if (i % 7 == 0) rng.random().int(u24) else @intCast(i * 1031 % 0xffffff);
        p.* = 0xff000000 | v;
    }
    const bytes = try encode(gpa, &cv);
    defer gpa.free(bytes);
    var back = try decode(gpa, bytes);
    defer back.deinit(gpa);
    try std.testing.expectEqualSlices(u32, cv.pixels, back.pixels);
    var w: c_int = 0;
    var h: c_int = 0;
    var n: c_int = 0;
    const data = c.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &n, 4).?;
    defer c.stbi_image_free(data);
    try std.testing.expectEqual(@as(c_int, 37), w);
    try std.testing.expectEqual(@as(u8, @truncate(cv.pixels[5] >> 16)), data[5 * 4]);
}

test "unsupported PNGs are refused, not misread" {
    try std.testing.expectError(error.Unsupported, decode(std.testing.allocator, "GIF89a..."));
}
