//! OS shim for Zig 0.17: one process-wide `std.Io` plus thin helpers (clock,
//! sleep, env, files, fds), so call sites keep their 0.15 shape.
const std = @import("std");
const Io = std.Io;

/// The process-wide io (blocking, no concurrency; threads use std.Thread).
pub fn io() Io {
    if (@import("builtin").is_test) return std.testing.io;
    return Io.Threaded.global_single_threaded.io();
}

pub fn cwd() Io.Dir {
    return Io.Dir.cwd();
}

/// Monotonic stopwatch, same shape as the old `sys.Timer`.
pub const Timer = struct {
    started: Io.Timestamp,
    pub fn start() error{}!Timer {
        return .{ .started = Io.Clock.awake.now(io()) };
    }
    pub fn read(t: *const Timer) u64 {
        const d = t.started.durationTo(Io.Clock.awake.now(io()));
        return @intCast(@max(0, d.toNanoseconds()));
    }
    pub fn reset(t: *Timer) void {
        t.started = Io.Clock.awake.now(io());
    }
    pub fn lap(t: *Timer) u64 {
        const now = Io.Clock.awake.now(io());
        const d = t.started.durationTo(now);
        t.started = now;
        return @intCast(@max(0, d.toNanoseconds()));
    }
};

/// Wall clock, seconds since the epoch.
pub fn timestamp() i64 {
    return Io.Clock.real.now(io()).toSeconds();
}

pub fn milliTimestamp() i64 {
    return Io.Clock.real.now(io()).toMilliseconds();
}

pub fn sleepNs(ns: u64) void {
    io().sleep(Io.Duration.fromNanoseconds(@intCast(ns)), .awake) catch {};
}

pub fn getenv(name: [:0]const u8) ?[]const u8 {
    const p = std.c.getenv(name) orelse return null;
    return std.mem.span(p);
}

pub fn hasEnv(name: [:0]const u8) bool {
    return std.c.getenv(name) != null;
}

pub fn readFileAlloc(gpa: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    return cwd().readFileAlloc(io(), path, gpa, .limited(max));
}

pub fn lock(m: *Io.Mutex) void {
    m.lockUncancelable(io());
}
pub fn unlock(m: *Io.Mutex) void {
    m.unlock(io());
}

pub fn pipe2(flags: std.posix.O) ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe2(&fds, flags) != 0) return error.PipeFailed;
    return fds;
}
pub fn write(fd: std.posix.fd_t, bytes: []const u8) !usize {
    const n = std.c.write(fd, bytes.ptr, bytes.len);
    if (n < 0) return error.WriteFailed;
    return @intCast(n);
}
pub fn close(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

/// Write the whole of `data` to `path` atomically (temp file + rename).
/// `write_fn` gets a writer; the file is replaced when it returns.
pub fn atomicWrite(path: []const u8, make_path: bool, ctx: anytype, comptime write_fn: anytype) !void {
    var af = try cwd().createFileAtomic(io(), path, .{ .make_path = make_path, .replace = true });
    defer af.deinit(io());
    var buf: [4096]u8 = undefined;
    var fw = af.file.writer(io(), &buf);
    try write_fn(ctx, &fw.interface);
    try fw.interface.flush();
    try af.replace(io());
}

/// Set access and modification time of `f` (ns since the epoch).
pub fn updateTimes(f: Io.File, atime: i128, mtime: i128) !void {
    try f.setTimestamps(io(), .{
        .access_timestamp = .{ .new = Io.Timestamp.fromNanoseconds(@intCast(atime)) },
        .modify_timestamp = .{ .new = Io.Timestamp.fromNanoseconds(@intCast(mtime)) },
    });
}

/// Absolute path of `sub` in `dir`, as a plain slice (free with `gpa.free`).
pub fn realPathAlloc(dir: Io.Dir, sub: []const u8, gpa: std.mem.Allocator) ![]u8 {
    const z = try dir.realPathFileAlloc(io(), sub, gpa);
    defer gpa.free(z);
    return gpa.dupe(u8, z);
}
