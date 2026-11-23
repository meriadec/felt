//! Config file: where the settings (core/settings.zig) persist across
//! sessions, `$XDG_CONFIG_HOME/felt/config` (else
//! `~/.config/felt/config`). Only the window mode reads it (at startup,
//! while the image decodes) and writes it (on a settings change, by atomic
//! rename). Headless runs and the bench never do: tests stay hermetic. A
//! missing, unreadable or broken file gives the defaults. The command line
//! (`--canvas-bg`) wins over the file for one session.
const std = @import("std");
const core = @import("core");

const settings = core.settings;
const Settings = settings.Settings;

/// The environment variables that place the file.
pub const Env = struct {
    xdg_config_home: ?[]const u8 = null,
    home: ?[]const u8 = null,

    pub fn ofProcess() Env {
        return .{ .xdg_config_home = std.posix.getenv("XDG_CONFIG_HOME"), .home = std.posix.getenv("HOME") };
    }
};

/// Path of the config file, or null without a usable base directory. An
/// empty or relative XDG_CONFIG_HOME is ignored (XDG base directory spec).
/// Caller frees with `gpa`.
pub fn path(gpa: std.mem.Allocator, env: Env) !?[]u8 {
    if (env.xdg_config_home) |x| if (x.len > 0 and std.fs.path.isAbsolute(x)) {
        return try std.fs.path.join(gpa, &.{ x, "felt", "config" });
    };
    if (env.home) |h| if (h.len > 0 and std.fs.path.isAbsolute(h)) {
        return try std.fs.path.join(gpa, &.{ h, ".config", "felt", "config" });
    };
    return null;
}

/// The settings in the file at `p`; the defaults if it is missing, too
/// big or unreadable (a bad line keeps its default, see settings.parse).
pub fn load(p: []const u8) Settings {
    var buf: [settings.max_file + 1]u8 = undefined;
    const src = std.fs.cwd().readFile(p, &buf) catch return .{};
    return settings.parse(src); // a file over max_file reads as the defaults
}

/// Write `s` to `p`: a temporary file in the same directory, renamed over
/// the old one, so a reader sees the old file or the new one, never a part.
/// Creates the directory. No fsync: after a crash the file may be old or
/// empty, and an empty file reads as the defaults.
pub fn save(p: []const u8, s: Settings) !void {
    var buf: [512]u8 = undefined;
    var af = try std.fs.cwd().atomicFile(p, .{ .make_path = true, .write_buffer = &buf });
    defer af.deinit();
    try settings.write(s, &af.file_writer.interface);
    try af.finish();
}

/// The settings for a session: the file's, with the command line flag on top.
pub fn resolve(file: Settings, flag: ?settings.CanvasBg) Settings {
    var s = file;
    if (flag) |bg| s.canvas_bg = bg;
    return s;
}

test "path: XDG_CONFIG_HOME, else ~/.config, else none" {
    const gpa = std.testing.allocator;
    const a = (try path(gpa, .{ .xdg_config_home = "/x/cfg", .home = "/home/u" })).?;
    defer gpa.free(a);
    try std.testing.expectEqualStrings("/x/cfg/felt/config", a);
    for ([_]?[]const u8{ null, "", "rel/cfg" }) |x| {
        const b = (try path(gpa, .{ .xdg_config_home = x, .home = "/home/u" })).?;
        defer gpa.free(b);
        try std.testing.expectEqualStrings("/home/u/.config/felt/config", b);
    }
    try std.testing.expectEqual(@as(?[]u8, null), try path(gpa, .{}));
    try std.testing.expectEqual(@as(?[]u8, null), try path(gpa, .{ .home = "" }));
}

/// `name` inside the test's tmp dir, as an absolute path.
fn tmpPath(gpa: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    const dir = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(dir);
    return std.fs.path.join(gpa, &.{ dir, name });
}

test "load: missing, good, bad, too big" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const p = try tmpPath(gpa, &tmp, "config");
    defer gpa.free(p);
    try std.testing.expectEqual(Settings{}, load(p)); // missing
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = "canvas_bg=dark\n" });
    try std.testing.expectEqual(settings.CanvasBg.dark, load(p).canvas_bg);
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = "canvas_bg=\xff\x00black\n" });
    try std.testing.expectEqual(Settings{}, load(p));
    const big = [_]u8{'#'} ** (settings.max_file + 10);
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = "canvas_bg=dark\n" ++ big });
    try std.testing.expectEqual(Settings{}, load(p));
    try tmp.dir.makeDir("dir");
    const d = try tmpPath(gpa, &tmp, "dir");
    defer gpa.free(d);
    try std.testing.expectEqual(Settings{}, load(d)); // not a file
}

test "save: creates the directory, replaces atomically, leaves no temp file" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const p = try tmpPath(gpa, &tmp, "felt/config");
    defer gpa.free(p);
    try save(p, .{ .canvas_bg = .dark });
    try std.testing.expectEqual(settings.CanvasBg.dark, load(p).canvas_bg);
    try save(p, .{ .canvas_bg = .light });
    try std.testing.expectEqual(settings.CanvasBg.light, load(p).canvas_bg);
    var dir = try tmp.dir.openDir("felt", .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next()) |e| {
        try std.testing.expectEqualStrings("config", e.name);
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "the command line flag wins over the file" {
    const dark = Settings{ .canvas_bg = .dark };
    try std.testing.expectEqual(settings.CanvasBg.light, resolve(dark, .light).canvas_bg);
    try std.testing.expectEqual(settings.CanvasBg.dark, resolve(dark, null).canvas_bg);
    try std.testing.expectEqual(settings.CanvasBg.dark, resolve(.{}, .dark).canvas_bg);
    try std.testing.expectEqual(settings.CanvasBg.light, resolve(.{}, null).canvas_bg);
}
