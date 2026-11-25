//! File browser state: the folder shown, its listing (folders and images,
//! newest first, see dirlist.zig), the scroll offset, the hovered row, the
//! thumbnails (cache + loader thread). It lists and decodes through the
//! loader, never on the caller's thread (headless: at once, see loader.zig),
//! and asks only for the thumbnails of the rows that show. Pure otherwise: it
//! knows the screen size only for the geometry (browsergeo.zig). The editor
//! owns one and routes the input; browser_draw.zig draws it.
const std = @import("std");
const dirlist = @import("dirlist.zig");
const thumbs = @import("thumbs.zig");
const loader_mod = @import("loader.zig");
const browsergeo = @import("browsergeo.zig");
const geom = @import("geom.zig");

const Geo = browsergeo.Geo;
const Hit = browsergeo.Hit;
const Entry = dirlist.Entry;
const Vec2 = geom.Vec2;

pub const Status = enum { empty, loading, ready, failed };

pub const Browser = struct {
    gpa: std.mem.Allocator,
    /// The panel shows.
    open: bool = false,
    /// The folder shown (absolute, owned); empty until the first open.
    path: []u8 = &.{},
    listing: ?dirlist.Listing = null,
    status: Status = .empty,
    /// Why the folder does not list (an error name).
    err: []const u8 = "",
    /// Number of the list job we wait for; older results are dropped.
    gen: u32 = 0,
    scroll: f32 = 0,
    /// The row or the up button under the pointer.
    hover: ?Hit = null,
    /// Changes with everything the panel shows (damage signature).
    rev: u32 = 1,
    cache: thumbs.Cache,
    loader: ?*loader_mod.Loader = null,
    /// Work on a thread (the X11 loop), or at once (headless).
    threaded: bool = false,
    wake_fd: ?std.posix.fd_t = null,
    /// Where the browser starts and what `~` stands for (owned); null: "/".
    home: ?[]u8 = null,
    /// Seconds east of UTC for the dates shown.
    tz_off: i32 = 0,
    screen: [2]u32 = .{ 1280, 720 },
    /// The rows (first, end) whose thumbnails were asked for last.
    asked: [2]usize = .{ 0, 0 },

    pub fn init(gpa: std.mem.Allocator) Browser {
        return .{ .gpa = gpa, .cache = .{ .gpa = gpa } };
    }

    pub fn deinit(self: *Browser) void {
        if (self.loader) |l| {
            l.deinit();
            self.gpa.destroy(l);
        }
        self.cache.deinit();
        if (self.listing) |*l| l.deinit();
        self.gpa.free(self.path);
        if (self.home) |h| self.gpa.free(h);
    }

    pub fn setHome(self: *Browser, home: ?[]const u8) !void {
        if (self.home) |h| self.gpa.free(h);
        self.home = if (home) |h| try self.gpa.dupe(u8, h) else null;
    }

    pub fn geo(self: *const Browser) Geo {
        return Geo.of(self.screen[0], self.screen[1]);
    }

    /// `..` is the first row, but at the root.
    pub fn hasParent(self: *const Browser) bool {
        return !std.mem.eql(u8, self.path, "/");
    }

    pub fn rowCount(self: *const Browser) usize {
        const n = if (self.listing) |l| l.entries.len else 0;
        return n + @intFromBool(self.hasParent());
    }

    /// The entry of a row; null for the `..` row.
    pub fn entryOf(self: *const Browser, row: usize) ?*const Entry {
        const off: usize = @intFromBool(self.hasParent());
        if (row < off) return null;
        const l = self.listing orelse return null;
        if (row - off >= l.entries.len) return null;
        return &l.entries[row - off];
    }

    pub fn bump(self: *Browser) void {
        self.rev +%= 1;
    }

    /// Show or hide the panel. Opening lists the folder again (the last one
    /// of the session; the first time, the home folder).
    pub fn toggle(self: *Browser) !void {
        self.open = !self.open;
        self.bump();
        if (!self.open) return;
        if (self.path.len == 0) {
            self.path = try self.gpa.dupe(u8, self.home orelse "/");
            self.scroll = 0;
        }
        try self.startList();
    }

    pub fn close(self: *Browser) void {
        if (self.open) {
            self.open = false;
            self.bump();
        }
    }

    fn startList(self: *Browser) !void {
        if (self.loader == null) {
            const l = try self.gpa.create(loader_mod.Loader);
            l.* = .{ .gpa = self.gpa, .threaded = self.threaded, .wake_fd = self.wake_fd };
            self.loader = l;
        }
        self.gen += 1;
        if (self.listing == null) self.status = .loading;
        const p = try self.gpa.dupe(u8, self.path);
        try self.loader.?.submit(.{ .list = .{ .gen = self.gen, .path = p } });
        _ = self.pump();
    }

    /// Go to the folder `path` (the browser copies it).
    pub fn enter(self: *Browser, path: []const u8) !void {
        const owned = try self.gpa.dupe(u8, path);
        self.gpa.free(self.path);
        self.path = owned;
        if (self.listing) |*l| l.deinit();
        self.listing = null;
        self.status = .loading;
        self.err = "";
        self.scroll = 0;
        self.hover = null;
        self.asked = .{ 0, 0 };
        self.bump();
        try self.startList();
    }

    pub fn goUp(self: *Browser) !void {
        if (!self.hasParent()) return;
        try self.enter(dirlist.parent(self.path)); // `enter` copies before it frees
    }

    /// Click on a row: `..` and folders are entered; an image does nothing
    /// (it is dragged onto the canvas). True if the panel changed.
    pub fn activate(self: *Browser, row: usize) !bool {
        if (self.entryOf(row)) |e| {
            if (!e.is_dir) return false;
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const p = self.pathOf(&buf, e.name) orelse return false;
            try self.enter(p);
        } else if (row == 0 and self.hasParent()) {
            try self.goUp();
        } else return false;
        return true;
    }

    /// Full path of `name` in the folder shown; null if it does not fit.
    pub fn pathOf(self: *const Browser, buf: []u8, name: []const u8) ?[]const u8 {
        const sep: []const u8 = if (std.mem.eql(u8, self.path, "/")) "" else "/";
        return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ self.path, sep, name }) catch null;
    }

    /// The hit under `p` (the folder button, the up button, a row, the panel).
    pub fn hitAt(self: *const Browser, p: Vec2) ?Hit {
        return self.geo().hit(p, self.open, self.scroll, self.rowCount());
    }

    /// Set the hover; true if it changed (redraw).
    pub fn setHover(self: *Browser, h: ?Hit) bool {
        const same = if (h) |a| (if (self.hover) |b| a.eql(b) else false) else self.hover == null;
        if (same) return false;
        self.hover = h;
        self.bump();
        return true;
    }

    /// Scroll by `delta` px (positive: down), clamped.
    pub fn scrollBy(self: *Browser, delta: f32) bool {
        const to = self.geo().clampScroll(self.scroll + delta, self.rowCount());
        if (to == self.scroll) return false;
        self.scroll = to;
        self.bump();
        self.refresh();
        return true;
    }

    /// The screen changed size.
    pub fn resize(self: *Browser, w: u32, h: u32) void {
        self.screen = .{ w, h };
        self.scroll = self.geo().clampScroll(self.scroll, self.rowCount());
        self.bump();
        self.refresh();
    }

    /// Take the finished jobs of the loader. True if the panel changed.
    pub fn pump(self: *Browser) bool {
        const l = self.loader orelse return false;
        var changed = false;
        while (l.take()) |r0| {
            var r = r0;
            switch (r) {
                .list => |*x| {
                    if (x.gen == self.gen) {
                        if (x.listing) |li| {
                            if (self.listing) |*old| old.deinit();
                            self.listing = li;
                            self.status = .ready;
                            self.err = "";
                            self.scroll = self.geo().clampScroll(self.scroll, self.rowCount());
                            self.asked = .{ 0, 0 };
                        } else |e| {
                            self.status = .failed;
                            self.err = @errorName(e);
                            if (self.listing) |*old| old.deinit();
                            self.listing = null;
                        }
                        x.listing = error.Taken; // the browser owns the listing now
                        changed = true;
                    }
                },
                .thumb => |*t| {
                    self.cache.put(t.key, t.mtime, t.thumb) catch {};
                    t.thumb = null; // the cache owns it (or freed it)
                    changed = true;
                },
            }
            r.deinit(self.gpa);
        }
        if (changed) {
            self.bump();
            self.refresh();
        }
        return changed;
    }

    /// Ask for the thumbnails of the rows that show and have none yet; drop
    /// the queued requests of rows that scrolled away.
    pub fn refresh(self: *Browser) void {
        if (!self.open) return;
        const l = self.loader orelse return;
        const g = self.geo();
        self.cache.setBox(@intFromFloat(@round(g.thumb_h)));
        const v = g.visible(self.scroll, self.rowCount());
        if (v[0] != self.asked[0] or v[1] != self.asked[1]) {
            if (l.dropThumbs() > 0) self.cache.clearPending();
            self.asked = v;
        }
        var i = v[0];
        while (i < v[1]) : (i += 1) {
            const e = self.entryOf(i) orelse continue;
            if (e.is_dir) continue;
            const k = thumbs.key(self.path, e.name);
            if (self.cache.get(k, e.mtime) != null) continue;
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const full = self.pathOf(&buf, e.name) orelse continue;
            const owned = self.gpa.dupe(u8, full) catch continue;
            self.cache.markPending(k, e.mtime) catch {
                self.gpa.free(owned);
                continue;
            };
            l.submit(.{ .thumb = .{ .key = k, .mtime = e.mtime, .path = owned, .box_w = @intFromFloat(@round(g.thumb_w)), .box_h = @intFromFloat(@round(g.thumb_h)) } }) catch {};
        }
        if (!self.threaded) {
            // Results are there already; store them without another refresh.
            while (l.take()) |r0| {
                var r = r0;
                if (r == .thumb) {
                    self.cache.put(r.thumb.key, r.thumb.mtime, r.thumb.thumb) catch {};
                    r.thumb.thumb = null;
                    self.bump();
                }
                r.deinit(self.gpa);
            }
        }
    }

    /// Work is queued or running: the backend must wake for the results.
    pub fn busy(self: *Browser) bool {
        const l = self.loader orelse return false;
        return l.busy();
    }

    /// The thumbnail of the entry (ready or not), without touching the cache order.
    pub fn thumbOf(self: *const Browser, e: *const Entry) ?*const thumbs.Slot {
        if (e.is_dir) return null;
        const s = self.cache.map.getPtr(thumbs.key(self.path, e.name)) orelse return null;
        return if (s.mtime == e.mtime) s else null;
    }

    /// Signature of what the panel shows (with its place, for the compositor).
    pub fn sig(self: *const Browser) u64 {
        return @as(u64, self.rev) << 1 | @intFromBool(self.open);
    }
};

const testing = std.testing;

/// A folder with 3 PNGs, a subfolder and a text file, mtimes set.
fn fixtureDir(tmp: *testing.TmpDir) ![]u8 {
    const Canvas = @import("canvas.zig").Canvas;
    const image_io = @import("image_io.zig");
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    errdefer testing.allocator.free(dir);
    var cv = try Canvas.init(testing.allocator, 30, 20);
    defer cv.deinit(testing.allocator);
    @memset(cv.pixels, 0xff224466);
    const names = [_][]const u8{ "a.png", "b.png", "c.png" };
    for (names, 0..) |n, i| {
        const p = try std.fs.path.join(testing.allocator, &.{ dir, n });
        defer testing.allocator.free(p);
        try image_io.savePng(testing.allocator, &cv, p);
        var f = try tmp.dir.openFile(n, .{ .mode = .read_write });
        defer f.close();
        const t: i128 = (1000 + @as(i128, @intCast(i)) * 100) * std.time.ns_per_s;
        try f.updateTimes(t, t);
    }
    try tmp.dir.makeDir("sub");
    try tmp.dir.writeFile(.{ .sub_path = "t.txt", .data = "x" });
    var d = try tmp.dir.openDir("sub", .{});
    defer d.close();
    try d.writeFile(.{ .sub_path = "x.png", .data = "not an image" });
    return dir;
}

test "browser: open lists mixed by date, thumbnails for the rows that show, enter and up" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try fixtureDir(&tmp);
    defer testing.allocator.free(dir);
    var b = Browser.init(testing.allocator);
    defer b.deinit();
    try b.setHome(dir);
    try b.toggle();
    try testing.expect(b.open);
    try testing.expectEqual(Status.ready, b.status);
    // sub (just made) first, then c, b, a.
    try testing.expectEqual(@as(usize, 5), b.rowCount()); // .. + 4
    try testing.expect(b.entryOf(0) == null);
    try testing.expectEqualStrings("sub", b.entryOf(1).?.name);
    try testing.expectEqualStrings("c.png", b.entryOf(2).?.name);
    try testing.expectEqualStrings("a.png", b.entryOf(4).?.name);
    const th = b.thumbOf(b.entryOf(2).?).?;
    try testing.expectEqual(thumbs.State.ready, th.state);
    try testing.expectEqual(@as(u32, 30), th.thumb.?.w);
    // Click on `sub`: enters it; its x.png does not decode: failed, no crash.
    try testing.expect(try b.activate(1));
    try testing.expectEqual(@as(usize, 2), b.rowCount());
    try testing.expectEqual(thumbs.State.failed, b.thumbOf(b.entryOf(1).?).?.state);
    try testing.expect(try b.activate(0)); // `..`
    try testing.expectEqualStrings(dir, b.path);
    try testing.expect(!(try b.activate(2))); // an image: nothing
    try b.enter("/nonexistent-felt-dir");
    try testing.expectEqual(Status.failed, b.status);
    try testing.expectEqualStrings("FileNotFound", b.err);
    try testing.expectEqual(@as(usize, 1), b.rowCount()); // only `..`
    try b.enter("/");
    try testing.expect(!b.hasParent());
    try testing.expect(b.entryOf(0) != null or b.rowCount() == 0); // no `..` row at the root
}

test "browser: scroll clamps, hover changes bump the signature, worker thread" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try fixtureDir(&tmp);
    defer testing.allocator.free(dir);
    var b = Browser.init(testing.allocator);
    defer b.deinit();
    b.threaded = true;
    try b.setHome(dir);
    try b.toggle();
    var spins: usize = 0;
    while (b.status != .ready and spins < 5000) : (spins += 1) {
        _ = b.pump();
        std.Thread.sleep(1_000_000);
    }
    try testing.expectEqual(Status.ready, b.status);
    spins = 0;
    while (b.busy() and spins < 5000) : (spins += 1) {
        _ = b.pump();
        std.Thread.sleep(1_000_000);
    }
    try testing.expectEqual(thumbs.State.ready, b.thumbOf(b.entryOf(2).?).?.state);
    try testing.expect(!b.scrollBy(100)); // all rows fit
    const s0 = b.sig();
    try testing.expect(b.setHover(.{ .row = 2 }));
    try testing.expect(b.sig() != s0);
    try testing.expect(!b.setHover(.{ .row = 2 }));
}
