//! Directory listing for the file browser: only folders and images (what
//! `image_io` decodes), no hidden entries, one list sorted by modification
//! time, newest first, folders and images mixed. Plus the small pure helpers
//! the panel needs: image name test, date text, the path shown with `~`.
//! `list` does file IO (one `stat` per folder or image name); the browser
//! runs it on the worker thread (loader.zig).
const std = @import("std");

pub const Entry = struct {
    /// The file name, no path. Owned by the `Listing`.
    name: []const u8,
    is_dir: bool,
    /// Modification time, seconds since the epoch.
    mtime: i64,
    size: u64,
};

/// Entries of one folder; the names live in the arena.
pub const Listing = struct {
    arena: std.heap.ArenaAllocator,
    entries: []Entry,

    pub fn deinit(self: *Listing) void {
        self.arena.deinit();
    }
};

/// File name extensions that `image_io` can decode (stb_image: PNG, JPEG, BMP).
const image_exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".bmp" };

pub fn isImageName(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    for (image_exts) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

pub fn isHidden(name: []const u8) bool {
    return name.len > 0 and name[0] == '.';
}

/// Newest first; the same time: by name (case-insensitive), so the order is stable.
pub fn newerFirst(_: void, a: Entry, b: Entry) bool {
    if (a.mtime != b.mtime) return a.mtime > b.mtime;
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

/// List `path`: folders and images, not hidden, sorted (`newerFirst`).
/// A name that cannot be `stat`ed (a broken link) is skipped.
pub fn list(gpa: std.mem.Allocator, path: []const u8) !Listing {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();
    var out = Listing{ .arena = std.heap.ArenaAllocator.init(gpa), .entries = &.{} };
    errdefer out.arena.deinit();
    const a = out.arena.allocator();
    var entries: std.ArrayList(Entry) = .empty; // freed below: the arena holds only the names
    defer entries.deinit(gpa);
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (isHidden(e.name)) continue;
        switch (e.kind) {
            .directory, .sym_link, .unknown => {},
            .file => if (!isImageName(e.name)) continue,
            else => continue,
        }
        const st = dir.statFile(e.name) catch continue; // follows links
        const is_dir = st.kind == .directory;
        if (!is_dir and !(st.kind == .file and isImageName(e.name))) continue;
        try entries.append(gpa, .{
            .name = try a.dupe(u8, e.name),
            .is_dir = is_dir,
            .mtime = @intCast(@divFloor(st.mtime, std.time.ns_per_s)),
            .size = st.size,
        });
    }
    std.mem.sort(Entry, entries.items, {}, newerFirst);
    out.entries = try a.dupe(Entry, entries.items);
    return out;
}

/// "2025-03-14 12:30" (16 bytes) for `mtime` seconds, shifted by `tz_off` seconds.
pub fn formatDate(buf: *[16]u8, mtime: i64, tz_off: i32) []const u8 {
    const t: u64 = @intCast(@max(0, mtime + tz_off));
    const es = std.time.epoch.EpochSeconds{ .secs = t };
    const ds = es.getDaySeconds();
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(),
    }) catch unreachable;
}

/// The parent folder of `path` ("/" stays "/"). Slice of `path`.
pub fn parent(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse path;
}

/// `path` with the start `home` written as `~` (only at a folder boundary).
/// Written into `buf` (at most its size: the tail wins).
pub fn tildePath(buf: []u8, path: []const u8, home: ?[]const u8) []const u8 {
    var rest = path;
    var pre: []const u8 = "";
    if (home) |h| {
        const hh = std.mem.trimRight(u8, h, "/");
        if (hh.len > 0 and std.mem.startsWith(u8, path, hh) and (path.len == hh.len or path[hh.len] == '/')) {
            pre = "~";
            rest = path[hh.len..];
        }
    }
    const n = @min(buf.len, pre.len + rest.len);
    const skip = pre.len + rest.len - n; // drop the head when too long
    var i: usize = 0;
    for (pre) |ch| {
        if (i >= skip) buf[i - skip] = ch;
        i += 1;
    }
    for (rest) |ch| {
        if (i >= skip) buf[i - skip] = ch;
        i += 1;
    }
    return buf[0..n];
}

const testing = std.testing;

test "image names: extensions, case, hidden" {
    try testing.expect(isImageName("a.png"));
    try testing.expect(isImageName("SHOT.JPG"));
    try testing.expect(isImageName("x.y.jpeg"));
    try testing.expect(isImageName("b.bmp"));
    try testing.expect(!isImageName("a.txt"));
    try testing.expect(!isImageName("png"));
    try testing.expect(!isImageName("a.png.bak"));
    try testing.expect(isHidden(".git"));
    try testing.expect(!isHidden("a.png"));
}

test "sort: newest first, folders and images mixed, ties by name" {
    var v = [_]Entry{
        .{ .name = "old.png", .is_dir = false, .mtime = 10, .size = 0 },
        .{ .name = "dir", .is_dir = true, .mtime = 20, .size = 0 },
        .{ .name = "B.png", .is_dir = false, .mtime = 30, .size = 0 },
        .{ .name = "a.png", .is_dir = false, .mtime = 30, .size = 0 },
    };
    std.mem.sort(Entry, &v, {}, newerFirst);
    try testing.expectEqualStrings("a.png", v[0].name);
    try testing.expectEqualStrings("B.png", v[1].name);
    try testing.expectEqualStrings("dir", v[2].name);
    try testing.expectEqualStrings("old.png", v[3].name);
}

test "list: filters hidden and other files, mixes by mtime" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.png", .data = "x" });
    try tmp.dir.writeFile(.{ .sub_path = ".hidden.png", .data = "x" });
    try tmp.dir.writeFile(.{ .sub_path = "notes.txt", .data = "x" });
    try tmp.dir.makeDir("folder");
    try tmp.dir.makeDir(".dot");
    {
        var f = try tmp.dir.openFile("a.png", .{ .mode = .read_write });
        defer f.close();
        try f.updateTimes(1_000_000_000_000, 1_000_000_000_000); // ns: 1000 s
    }
    const p = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(p);
    var l = try list(testing.allocator, p);
    defer l.deinit();
    try testing.expectEqual(@as(usize, 2), l.entries.len);
    try testing.expectEqualStrings("folder", l.entries[0].name); // made just now: newer
    try testing.expect(l.entries[0].is_dir);
    try testing.expectEqualStrings("a.png", l.entries[1].name);
    try testing.expectEqual(@as(i64, 1000), l.entries[1].mtime);
    try testing.expectError(error.FileNotFound, list(testing.allocator, "/nonexistent-felt-dir"));
}

test "date text" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("2025-03-14 12:30", formatDate(&buf, 1741955400, 0));
    try testing.expectEqualStrings("2025-03-14 14:30", formatDate(&buf, 1741955400, 7200));
}

test "paths: tilde, parent, long path keeps the tail" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("~", tildePath(&buf, "/home/me", "/home/me"));
    try testing.expectEqualStrings("~/Pictures", tildePath(&buf, "/home/me/Pictures", "/home/me/"));
    try testing.expectEqualStrings("/home/meow/x", tildePath(&buf, "/home/meow/x", "/home/me"));
    try testing.expectEqualStrings("/tmp", tildePath(&buf, "/tmp", null));
    var small: [6]u8 = undefined;
    try testing.expectEqualStrings("/b/c/d", tildePath(&small, "/a/b/c/d", null));
    try testing.expectEqualStrings("/home", parent("/home/me"));
    try testing.expectEqualStrings("/", parent("/home"));
    try testing.expectEqualStrings("/", parent("/"));
}
