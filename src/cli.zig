//! Command line parsing. `usage` is the --help text.
const std = @import("std");

pub const usage =
    \\Usage: annotate [options] <image>
    \\
    \\Opens <image> full screen for annotation (X11). Esc quits, Ctrl+S saves,
    \\Ctrl+C copies, ? shows the keys. Key map: docs/keymap.md.
    \\
    \\Options:
    \\  -e <image>             Same as the <image> argument (ksnip compatible)
    \\  -o, --output <path>    Ctrl+S writes here (default: overwrite <image>)
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
    \\
    \\Benchmark:
    \\  --bench [<image>]      Measure decode, first frame, drag frames, export
    \\                         (default: synthetic 2560x1440 image, 1920x1080 screen)
    \\
;

pub const Mode = enum { window, headless, bench, help, keymap_md };

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
    if ((o.mode == .window or o.mode == .headless) and o.image == null) {
        msg.* = "no image given";
        return error.BadArgs;
    }
    return o;
}

pub fn parseSize(s: []const u8) ?[2]u32 {
    const x = std.mem.indexOfScalar(u8, s, 'x') orelse return null;
    const w = std.fmt.parseInt(u32, s[0..x], 10) catch return null;
    const h = std.fmt.parseInt(u32, s[x + 1 ..], 10) catch return null;
    if (w == 0 or h == 0 or w > 16384 or h > 16384) return null;
    return .{ w, h };
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
    try std.testing.expectError(error.BadArgs, parse(&.{}, &msg));
    try std.testing.expectEqual(Mode.bench, (try parse(&.{"--bench"}, &msg)).mode);
}
