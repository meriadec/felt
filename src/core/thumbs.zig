//! Thumbnails of the file browser: `make` decodes an image file and
//! downscales it to fit a box (area average, `resample`); `Cache` keeps the
//! finished ones, at most `capacity` (least recently used leave first). The
//! key is a hash of the file path; a changed modification time is a miss.
//! `make` runs on the loader thread (loader.zig); the cache belongs to the
//! main thread.
const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;
const image_io = @import("image_io.zig");
const resample = @import("resample.zig");

pub const Thumb = struct {
    /// The image scaled to fit the box (never above 1:1).
    canvas: Canvas,
    /// Size of the file's image.
    w: u32,
    h: u32,
};

/// Size of `w` x `h` scaled to fit `box_w` x `box_h`, never up; at least 1 x 1.
pub fn fitSize(w: u32, h: u32, box_w: u32, box_h: u32) [2]u32 {
    const sx = @as(f64, @floatFromInt(box_w)) / @as(f64, @floatFromInt(w));
    const sy = @as(f64, @floatFromInt(box_h)) / @as(f64, @floatFromInt(h));
    const f = @min(1.0, @min(sx, sy));
    const dw: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(w)) * f))));
    const dh: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(h)) * f))));
    return .{ @min(dw, w), @min(dh, h) };
}

/// Decode `path` and scale it into the box. Caller owns the canvas.
pub fn make(gpa: std.mem.Allocator, path: []const u8, box_w: u32, box_h: u32) !Thumb {
    var full = try image_io.load(gpa, path);
    defer full.deinit(gpa);
    const d = fitSize(full.width, full.height, box_w, box_h);
    return .{ .canvas = try resample.downscale(gpa, &full, d[0], d[1]), .w = full.width, .h = full.height };
}

pub const Key = u64;

/// Key of the file `name` in the folder `dir`.
pub fn key(dir: []const u8, name: []const u8) Key {
    var h = std.hash.Wyhash.init(0x7468756d);
    h.update(dir);
    h.update("/");
    h.update(name);
    return h.final();
}

pub const State = enum { pending, ready, failed };

pub const Slot = struct {
    state: State,
    mtime: i64,
    thumb: ?Thumb = null,
    last_use: u64 = 0,
};

pub const capacity = 200;

pub const Cache = struct {
    gpa: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged(Key, Slot) = .empty,
    clock: u64 = 0,
    /// Number of `ready` slots.
    ready: usize = 0,
    cap: usize = capacity,
    /// Box height the thumbnails were made for; another one clears the cache.
    box_h: u32 = 0,

    pub fn deinit(self: *Cache) void {
        self.clear();
        self.map.deinit(self.gpa);
    }

    pub fn clear(self: *Cache) void {
        var it = self.map.valueIterator();
        while (it.next()) |s| if (s.thumb) |*t| t.canvas.deinit(self.gpa);
        self.map.clearRetainingCapacity();
        self.ready = 0;
    }

    /// The box changed height (another screen size): the old ones do not fit.
    pub fn setBox(self: *Cache, box_h: u32) void {
        if (box_h != self.box_h) {
            self.clear();
            self.box_h = box_h;
        }
    }

    /// The slot of `k` for a file of this mtime (touched: it was just used).
    pub fn get(self: *Cache, k: Key, mtime: i64) ?*Slot {
        const s = self.map.getPtr(k) orelse return null;
        if (s.mtime != mtime) {
            self.remove(k);
            return null;
        }
        self.clock += 1;
        s.last_use = self.clock;
        return s;
    }

    fn remove(self: *Cache, k: Key) void {
        if (self.map.fetchRemove(k)) |kv| {
            var s = kv.value;
            if (s.thumb) |*t| t.canvas.deinit(self.gpa);
            if (s.state == .ready) self.ready -= 1;
        }
    }

    pub fn markPending(self: *Cache, k: Key, mtime: i64) !void {
        self.remove(k);
        try self.map.put(self.gpa, k, .{ .state = .pending, .mtime = mtime });
    }

    /// Forget the requests that never ran (the loader dropped them).
    pub fn clearPending(self: *Cache) void {
        var gone: [64]Key = undefined;
        while (true) {
            var n: usize = 0;
            var it = self.map.iterator();
            while (it.next()) |e| if (e.value_ptr.state == .pending and n < gone.len) {
                gone[n] = e.key_ptr.*;
                n += 1;
            };
            for (gone[0..n]) |k| _ = self.map.remove(k);
            if (n < gone.len) break;
        }
    }

    /// Store a result (`null`: the file does not decode). Takes the thumb.
    /// Over capacity, the least recently used ready slot goes.
    pub fn put(self: *Cache, k: Key, mtime: i64, thumb: ?Thumb) !void {
        self.remove(k);
        errdefer if (thumb) |t| {
            var c = t.canvas;
            c.deinit(self.gpa);
        };
        self.clock += 1;
        try self.map.put(self.gpa, k, .{ .state = if (thumb != null) .ready else .failed, .mtime = mtime, .thumb = thumb, .last_use = self.clock });
        if (thumb != null) self.ready += 1;
        while (self.ready > self.cap) {
            var oldest: ?Key = null;
            var best: u64 = std.math.maxInt(u64);
            var it = self.map.iterator();
            while (it.next()) |e| if (e.value_ptr.state == .ready and e.value_ptr.last_use < best and e.key_ptr.* != k) {
                best = e.value_ptr.last_use;
                oldest = e.key_ptr.*;
            };
            self.remove(oldest orelse break);
        }
    }
};

const testing = std.testing;

test "fit: aspect kept, never up" {
    try testing.expectEqual([2]u32{ 100, 50 }, fitSize(1200, 600, 100, 56));
    try testing.expectEqual([2]u32{ 28, 56 }, fitSize(100, 200, 100, 56));
    try testing.expectEqual([2]u32{ 10, 10 }, fitSize(10, 10, 100, 56));
    try testing.expectEqual([2]u32{ 100, 1 }, fitSize(5000, 3, 100, 56));
}

fn tiny(gpa: std.mem.Allocator) !Thumb {
    return .{ .canvas = try Canvas.init(gpa, 2, 2), .w = 4, .h = 4 };
}

test "cache: least recently used leaves first, mtime change is a miss" {
    var c = Cache{ .gpa = testing.allocator, .cap = 2 };
    defer c.deinit();
    try c.put(1, 10, try tiny(testing.allocator));
    try c.put(2, 10, try tiny(testing.allocator));
    try testing.expect(c.get(1, 10) != null); // 1 is now newer than 2
    try c.put(3, 10, try tiny(testing.allocator));
    try testing.expect(c.get(2, 10) == null);
    try testing.expect(c.get(1, 10) != null);
    try testing.expect(c.get(3, 10) != null);
    try testing.expect(c.get(1, 11) == null);
    try testing.expectEqual(@as(usize, 1), c.ready);
}

test "cache: pending, failed, clear" {
    var c = Cache{ .gpa = testing.allocator };
    defer c.deinit();
    try c.markPending(5, 1);
    try testing.expectEqual(State.pending, c.get(5, 1).?.state);
    try c.put(6, 1, null);
    try testing.expectEqual(State.failed, c.get(6, 1).?.state);
    c.clearPending();
    try testing.expect(c.get(5, 1) == null);
    try testing.expect(c.get(6, 1) != null);
    c.setBox(56);
    c.setBox(56);
    try testing.expect(c.get(6, 1) == null);
}

test "key depends on folder and name" {
    try testing.expect(key("/a", "b") != key("/a", "c"));
    try testing.expect(key("/a", "b") != key("/b", "b"));
    try testing.expectEqual(key("/a", "b"), key("/a", "b"));
}
