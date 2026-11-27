//! Background work of the file browser: one worker thread runs two kinds of
//! job, listing a folder (`dirlist.list`, one `stat` per name) and making a
//! thumbnail (`thumbs.make`). The UI never waits on either. The main thread
//! `submit`s jobs and `take`s results; a result also writes one byte to
//! `wake_fd` (when set) so a backend waiting in `poll` wakes up. Without a
//! thread (`threaded = false`, headless runs) `submit` does the job at once,
//! so replays are deterministic.
//! A loader must not move once the first job ran (the thread keeps its address).
const std = @import("std");
const sys = @import("sys.zig");
const dirlist = @import("dirlist.zig");
const thumbs = @import("thumbs.zig");

pub const Job = union(enum) {
    /// `path` is owned by the job.
    list: struct { gen: u32, path: []u8 },
    thumb: struct { key: thumbs.Key, mtime: i64, path: []u8, box_w: u32, box_h: u32 },
};

pub const Result = union(enum) {
    /// `listing` or the error name; `path` is owned.
    list: struct { gen: u32, path: []u8, listing: anyerror!dirlist.Listing },
    thumb: struct { key: thumbs.Key, mtime: i64, thumb: ?thumbs.Thumb },

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .list => |*l| {
                gpa.free(l.path);
                if (l.listing) |*x| {
                    var li = x.*;
                    li.deinit();
                } else |_| {}
            },
            .thumb => |*t| if (t.thumb) |*x| x.canvas.deinit(gpa),
        }
    }
};

fn freeJob(gpa: std.mem.Allocator, j: Job) void {
    switch (j) {
        .list => |l| gpa.free(l.path),
        .thumb => |t| gpa.free(t.path),
    }
}

pub const Loader = struct {
    gpa: std.mem.Allocator,
    threaded: bool,
    /// Written (one byte) after each result, if set.
    wake_fd: ?std.posix.fd_t = null,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    jobs: std.ArrayList(Job) = .empty,
    results: std.ArrayList(Result) = .empty,
    /// A job is running on the worker.
    running: bool = false,
    quit: bool = false,
    thread: ?std.Thread = null,

    pub fn deinit(self: *Loader) void {
        self.mutex.lockUncancelable(sys.io());
        self.quit = true;
        self.cond.signal(sys.io());
        self.mutex.unlock(sys.io());
        if (self.thread) |t| t.join();
        for (self.jobs.items) |j| freeJob(self.gpa, j);
        self.jobs.deinit(self.gpa);
        for (self.results.items) |*r| r.deinit(self.gpa);
        self.results.deinit(self.gpa);
    }

    /// Queue a job (takes its path). A new list job replaces the queued list
    /// jobs and goes first. Threaded: returns at once.
    pub fn submit(self: *Loader, job: Job) !void {
        errdefer freeJob(self.gpa, job);
        if (!self.threaded) {
            const r = execute(self.gpa, job);
            freeJob(self.gpa, job);
            try self.results.append(self.gpa, r);
            return;
        }
        self.mutex.lockUncancelable(sys.io());
        defer self.mutex.unlock(sys.io());
        if (self.thread == null) self.thread = try std.Thread.spawn(.{}, work, .{self});
        if (job == .list) {
            var i: usize = 0;
            while (i < self.jobs.items.len) {
                if (self.jobs.items[i] == .list) {
                    freeJob(self.gpa, self.jobs.orderedRemove(i));
                } else i += 1;
            }
            try self.jobs.insert(self.gpa, 0, job);
        } else try self.jobs.append(self.gpa, job);
        self.cond.signal(sys.io());
    }

    /// Drop the queued thumbnail jobs (the user scrolled away). The one
    /// running finishes. Returns how many were dropped.
    pub fn dropThumbs(self: *Loader) usize {
        self.mutex.lockUncancelable(sys.io());
        defer self.mutex.unlock(sys.io());
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.jobs.items.len) {
            if (self.jobs.items[i] == .thumb) {
                freeJob(self.gpa, self.jobs.orderedRemove(i));
                n += 1;
            } else i += 1;
        }
        return n;
    }

    /// The next finished result, or null. Caller owns it (`Result.deinit`).
    pub fn take(self: *Loader) ?Result {
        self.mutex.lockUncancelable(sys.io());
        defer self.mutex.unlock(sys.io());
        if (self.results.items.len == 0) return null;
        return self.results.orderedRemove(0);
    }

    /// Jobs are queued or running, or results wait.
    pub fn busy(self: *Loader) bool {
        self.mutex.lockUncancelable(sys.io());
        defer self.mutex.unlock(sys.io());
        return self.jobs.items.len > 0 or self.running or self.results.items.len > 0;
    }

    fn work(self: *Loader) void {
        while (true) {
            self.mutex.lockUncancelable(sys.io());
            while (self.jobs.items.len == 0 and !self.quit) self.cond.waitUncancelable(sys.io(), &self.mutex);
            if (self.quit) {
                self.mutex.unlock(sys.io());
                return;
            }
            const job = self.jobs.orderedRemove(0);
            self.running = true;
            self.mutex.unlock(sys.io());
            const r = execute(self.gpa, job);
            freeJob(self.gpa, job);
            self.mutex.lockUncancelable(sys.io());
            self.running = false;
            self.results.append(self.gpa, r) catch {
                var rr = r;
                rr.deinit(self.gpa);
            };
            self.mutex.unlock(sys.io());
            if (self.wake_fd) |fd| _ = sys.write(fd, "x") catch 0;
        }
    }
};

/// Run a job. The result owns copies of what it needs.
fn execute(gpa: std.mem.Allocator, job: Job) Result {
    switch (job) {
        .list => |l| {
            const path = gpa.dupe(u8, l.path) catch return .{ .list = .{ .gen = l.gen, .path = &.{}, .listing = error.OutOfMemory } };
            return .{ .list = .{ .gen = l.gen, .path = path, .listing = dirlist.list(gpa, l.path) } };
        },
        .thumb => |t| {
            const th = thumbs.make(gpa, t.path, t.box_w, t.box_h) catch null;
            return .{ .thumb = .{ .key = t.key, .mtime = t.mtime, .thumb = th } };
        },
    }
}

const testing = std.testing;

fn fixture(tmp: *testing.TmpDir) ![]u8 {
    const Canvas = @import("canvas.zig").Canvas;
    const image_io = @import("image_io.zig");
    var cv = try Canvas.init(testing.allocator, 40, 20);
    defer cv.deinit(testing.allocator);
    @memset(cv.pixels, 0xff336699);
    const dir = try sys.realPathAlloc(tmp.dir, ".", testing.allocator);
    errdefer testing.allocator.free(dir);
    const p = try std.fs.path.join(testing.allocator, &.{ dir, "a.png" });
    defer testing.allocator.free(p);
    try image_io.savePng(testing.allocator, &cv, p);
    return dir;
}

test "loader: sync mode lists and makes thumbnails at once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try fixture(&tmp);
    defer testing.allocator.free(dir);
    var l = Loader{ .gpa = testing.allocator, .threaded = false };
    defer l.deinit();
    try l.submit(.{ .list = .{ .gen = 3, .path = try testing.allocator.dupe(u8, dir) } });
    var r = l.take().?;
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 3), r.list.gen);
    try testing.expectEqual(@as(usize, 1), (try r.list.listing).entries.len);
    const p = try std.fs.path.join(testing.allocator, &.{ dir, "a.png" });
    try l.submit(.{ .thumb = .{ .key = 9, .mtime = 1, .path = p, .box_w = 20, .box_h = 20 } });
    var t = l.take().?;
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 20), t.thumb.thumb.?.canvas.width);
    try testing.expectEqual(@as(u32, 10), t.thumb.thumb.?.canvas.height);
    try testing.expectEqual(@as(u32, 40), t.thumb.thumb.?.w);
    try testing.expect(l.take() == null);
}

test "loader: a worker thread delivers, wakes, and drops queued thumbnails" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try fixture(&tmp);
    defer testing.allocator.free(dir);
    const fds = try sys.pipe2(.{});
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
    var l = Loader{ .gpa = testing.allocator, .threaded = true, .wake_fd = fds[1] };
    defer l.deinit();
    try l.submit(.{ .list = .{ .gen = 1, .path = try testing.allocator.dupe(u8, dir) } });
    var pfd = [1]std.posix.pollfd{.{ .fd = fds[0], .events = std.posix.POLL.IN, .revents = 0 }};
    try testing.expectEqual(@as(usize, 1), try std.posix.poll(&pfd, 5000));
    var r = l.take().?;
    r.deinit(testing.allocator);
    // Queue many, drop: at most the running one remains.
    for (0..20) |i| {
        const p = try std.fs.path.join(testing.allocator, &.{ dir, "a.png" });
        try l.submit(.{ .thumb = .{ .key = i, .mtime = 1, .path = p, .box_w = 20, .box_h = 20 } });
    }
    _ = l.dropThumbs();
    while (l.busy()) {
        if (l.take()) |*x| {
            var y = x.*;
            y.deinit(testing.allocator);
        } else sys.sleepNs(1_000_000);
    }
}
