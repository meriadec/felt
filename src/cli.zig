//! Command line parsing. `usage` is the --help text.
const std = @import("std");
const core = @import("core");

pub const usage =
    \\Usage: felt [options] <image>
    \\       felt [--capture] [--delay <seconds>] [options]
    \\
    \\Opens <image> full screen for annotation (X11). Esc or q quits, Ctrl+S saves,
    \\Ctrl+C copies, ? shows the keys. Key map: docs/keymap.md.
    \\
    \\With no <image> (or --capture) felt captures the screen first: it freezes all
    \\monitors, dims them, and you drag a rectangle (the capture is taken when you
    \\release the button) or click a window. Tab toggles a delay before the grab
    \\(so you can open a menu); Esc or right click cancels (exit status 1). Then the
    \\editor opens on the capture. Ctrl+S writes $HOME/<unix time>.png unless -o
    \\says otherwise. i3: bindsym Print exec felt --capture
    \\
    \\Options:
    \\  --capture              Capture the screen (the default with no <image>)
    \\  --delay <seconds>      Capture mode: initial delay before the live grab
    \\                         (default 0; Tab toggles it between 0 and this value,
    \\                         or 1 s when it is 0)
    \\  -e <image>             Same as the <image> argument (ksnip compatible)
    \\  -o, --output <path>    Ctrl+S writes a PNG here (default: overwrite <image> if it
    \\                         is a .png, else <image stem>.annotated.png; capture
    \\                         mode: $HOME/<unix time>.png)
    \\  --canvas-bg light|dark
    \\                         Canvas background outside the image for this run
    \\                         (wins over the config file; `b` switches it)
    \\  --timing               Print startup timings to stderr
    \\  --smoke                Open the window, show one frame, print timings, exit
    \\  --keymap-md            Print the key map as Markdown and exit
    \\  -h, --help             Show this help
    \\
    \\Headless (no display needed):
    \\  --headless             Replay a script instead of opening a window
    \\  --script <file>        Event script (format: docs/testing.md)
    \\  --size <W>x<H>         Screen size (default: script `size`, else 1280x720)
    \\  --frame-out <png>      Write the final UI frame
    \\  --export-out <png>     Write the exported image (full resolution)
    \\  --clipboard-out <png>  Ctrl+C in the script writes here
    \\  (headless never reads or writes the config file; --canvas-bg applies)
    \\
    \\Config file: $XDG_CONFIG_HOME/felt/config (default ~/.config/felt/config),
    \\one line `canvas_bg=light` or `canvas_bg=dark`. felt writes it when you
    \\switch the canvas background; a missing or broken file gives the defaults.
    \\
    \\Benchmark:
    \\  --bench [<image>]      Measure decode, first frame, drag frames, export
    \\                         (default: synthetic 2560x1440 image, 1920x1080 screen)
    \\
;

pub const Mode = enum { window, capture, headless, bench, help, keymap_md };

pub const Options = struct {
    mode: Mode = .window,
    image: ?[]const u8 = null,
    output: ?[]const u8 = null,
    script: ?[]const u8 = null,
    size: ?[2]u32 = null,
    frame_out: ?[]const u8 = null,
    export_out: ?[]const u8 = null,
    clipboard_out: ?[]const u8 = null,
    timing: bool = false,
    smoke: bool = false,
    /// --delay, ms: the capture delay at startup.
    delay_ms: u32 = 0,
    /// --canvas-bg: wins over the config file.
    canvas_bg: ?core.settings.CanvasBg = null,
};

pub const Error = error{BadArgs};

/// Why parsing failed: a message and the argument at fault, if any.
pub const Diag = struct {
    msg: []const u8 = "",
    arg: ?[]const u8 = null,
};

/// Parse args (without argv[0]). On error, `diag` says why.
pub fn parse(args: []const []const u8, diag: *Diag) Error!Options {
    const msg = &diag.msg;
    var o = Options{};
    var i: usize = 0;
    var capture = false;
    var delay_given = false;
    const S = struct {
        fn value(a: []const []const u8, idx: *usize, m: *[]const u8, name: []const u8) Error![]const u8 {
            idx.* += 1;
            if (idx.* >= a.len) {
                m.* = name;
                return error.BadArgs;
            }
            return a[idx.*];
        }
    };
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const eq = std.mem.eql;
        if (eq(u8, a, "-h") or eq(u8, a, "--help")) {
            o.mode = .help;
        } else if (eq(u8, a, "--capture")) {
            capture = true;
        } else if (eq(u8, a, "--delay")) {
            const v = try S.value(args, &i, msg, "--delay needs seconds, e.g. 1 or 0.5");
            const secs = std.fmt.parseFloat(f32, v) catch -1;
            if (!(secs >= 0 and secs <= 60)) {
                msg.* = "--delay needs seconds from 0 to 60, e.g. 1 or 0.5";
                diag.arg = v;
                return error.BadArgs;
            }
            o.delay_ms = @intFromFloat(@round(secs * 1000));
            delay_given = true;
        } else if (eq(u8, a, "--keymap-md")) {
            o.mode = .keymap_md;
        } else if (eq(u8, a, "--headless")) {
            o.mode = .headless;
        } else if (eq(u8, a, "--bench")) {
            o.mode = .bench;
        } else if (eq(u8, a, "--timing")) {
            o.timing = true;
        } else if (eq(u8, a, "--smoke")) {
            o.smoke = true;
            o.timing = true;
        } else if (eq(u8, a, "-e")) {
            o.image = try S.value(args, &i, msg, "-e needs an image path");
        } else if (eq(u8, a, "-o") or eq(u8, a, "--output")) {
            o.output = try S.value(args, &i, msg, "-o needs a path");
        } else if (eq(u8, a, "--script")) {
            o.script = try S.value(args, &i, msg, "--script needs a file");
        } else if (eq(u8, a, "--frame-out")) {
            o.frame_out = try S.value(args, &i, msg, "--frame-out needs a path");
        } else if (eq(u8, a, "--export-out")) {
            o.export_out = try S.value(args, &i, msg, "--export-out needs a path");
        } else if (eq(u8, a, "--clipboard-out")) {
            o.clipboard_out = try S.value(args, &i, msg, "--clipboard-out needs a path");
        } else if (eq(u8, a, "--canvas-bg")) {
            const v = try S.value(args, &i, msg, "--canvas-bg needs light or dark");
            o.canvas_bg = std.meta.stringToEnum(core.settings.CanvasBg, v) orelse {
                msg.* = "--canvas-bg needs light or dark";
                diag.arg = v;
                return error.BadArgs;
            };
        } else if (eq(u8, a, "--size")) {
            const v = try S.value(args, &i, msg, "--size needs WxH, e.g. 1920x1080");
            o.size = parseSize(v) orelse {
                msg.* = "--size needs WxH, e.g. 1920x1080";
                return error.BadArgs;
            };
        } else if (a.len > 1 and a[0] == '-') {
            msg.* = "unknown option";
            diag.arg = a;
            return error.BadArgs;
        } else {
            if (o.image != null) {
                msg.* = "more than one image given";
                diag.arg = a;
                return error.BadArgs;
            }
            o.image = a;
        }
    }
    if (capture and o.image != null) {
        msg.* = "--capture takes no image";
        diag.arg = o.image;
        return error.BadArgs;
    }
    if (capture and (o.mode == .headless or o.mode == .bench)) {
        msg.* = "--capture does not combine with --headless or --bench";
        return error.BadArgs;
    }
    if (o.mode == .window and o.image == null) o.mode = .capture; // no image: capture the screen
    if (delay_given and o.mode != .capture) {
        msg.* = "--delay is for capture mode (no image given)";
        return error.BadArgs;
    }
    if (o.mode == .headless and o.image == null) {
        msg.* = "no image given";
        return error.BadArgs;
    }
    return o;
}

/// Where Ctrl+S writes: `-o`, else the input if it is a PNG, else a PNG
/// next to it (never PNG bytes in a .jpg). Caller frees with `gpa`.
pub fn defaultOutput(gpa: std.mem.Allocator, image: []const u8) ![]u8 {
    const ext = std.fs.path.extension(image);
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return gpa.dupe(u8, image);
    return std.fmt.allocPrint(gpa, "{s}.annotated.png", .{image[0 .. image.len - ext.len]});
}

/// Where Ctrl+S writes in capture mode: `$HOME/<unix time>.png` (the old
/// `maim` script's name), else the working directory. Caller frees with `gpa`.
pub fn captureOutput(gpa: std.mem.Allocator, home: ?[]const u8, unix_time: i64) ![]u8 {
    if (home) |h| if (h.len > 0) return std.fmt.allocPrint(gpa, "{s}/{d}.png", .{ std.mem.trimRight(u8, h, "/"), unix_time });
    return std.fmt.allocPrint(gpa, "{d}.png", .{unix_time});
}

pub fn parseSize(s: []const u8) ?[2]u32 {
    const x = std.mem.indexOfScalar(u8, s, 'x') orelse return null;
    const w = std.fmt.parseInt(u32, s[0..x], 10) catch return null;
    const h = std.fmt.parseInt(u32, s[x + 1 ..], 10) catch return null;
    if (w == 0 or h == 0 or w > 16384 or h > 16384) return null;
    return .{ w, h };
}

test "default output never writes PNG into another format" {
    const gpa = std.testing.allocator;
    const a = try defaultOutput(gpa, "/x/shot.PNG");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("/x/shot.PNG", a);
    const b = try defaultOutput(gpa, "/x/photo.jpg");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("/x/photo.annotated.png", b);
}

test "parse" {
    var msg: Diag = .{};
    const o = try parse(&.{ "-e", "shot.png" }, &msg);
    try std.testing.expectEqualStrings("shot.png", o.image.?);
    try std.testing.expectEqual(Mode.window, o.mode);
    const h = try parse(&.{ "--headless", "--size", "800x500", "--script", "s.txt", "in.png" }, &msg);
    try std.testing.expectEqual([2]u32{ 800, 500 }, h.size.?);
    try std.testing.expectError(error.BadArgs, parse(&.{"--nope"}, &msg));
    try std.testing.expectEqualStrings("--nope", msg.arg.?);
    try std.testing.expectEqual(Mode.capture, (try parse(&.{}, &msg)).mode);
    try std.testing.expectError(error.BadArgs, parse(&.{"--headless"}, &msg));
    try std.testing.expectEqual(Mode.bench, (try parse(&.{"--bench"}, &msg)).mode);
    try std.testing.expectEqual(@as(?core.settings.CanvasBg, null), o.canvas_bg);
    try std.testing.expectEqual(core.settings.CanvasBg.dark, (try parse(&.{ "--canvas-bg", "dark", "a.png" }, &msg)).canvas_bg.?);
    try std.testing.expectError(error.BadArgs, parse(&.{ "--canvas-bg", "white", "a.png" }, &msg));
    try std.testing.expectEqualStrings("white", msg.arg.?);
    try std.testing.expectError(error.BadArgs, parse(&.{"--canvas-bg"}, &msg));
}

test "capture mode" {
    var msg: Diag = .{};
    try std.testing.expectEqual(Mode.capture, (try parse(&.{"--capture"}, &msg)).mode);
    const o = try parse(&.{ "--delay", "0.5", "-o", "x.png" }, &msg);
    try std.testing.expectEqual(Mode.capture, o.mode);
    try std.testing.expectEqual(@as(u32, 500), o.delay_ms);
    try std.testing.expectEqualStrings("x.png", o.output.?);
    try std.testing.expectError(error.BadArgs, parse(&.{ "--capture", "a.png" }, &msg));
    try std.testing.expectError(error.BadArgs, parse(&.{ "--delay", "1", "a.png" }, &msg));
    try std.testing.expectError(error.BadArgs, parse(&.{ "--delay", "soon" }, &msg));
    try std.testing.expectEqualStrings("soon", msg.arg.?);
    try std.testing.expectError(error.BadArgs, parse(&.{"--delay"}, &msg));
    try std.testing.expectEqual(Mode.window, (try parse(&.{"a.png"}, &msg)).mode);
}

test "capture output is under HOME" {
    const gpa = std.testing.allocator;
    const a = try captureOutput(gpa, "/home/u/", 1700000000);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("/home/u/1700000000.png", a);
    const b = try captureOutput(gpa, null, 5);
    defer gpa.free(b);
    try std.testing.expectEqualStrings("5.png", b);
}
