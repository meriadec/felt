//! Entry point: parses the command line and starts a backend.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const cli = @import("cli.zig");
const headless = @import("backend/headless.zig");
const x11 = @import("backend/x11.zig");
const x11_capture = @import("backend/x11_capture.zig");
const bench = @import("bench.zig");
const config = @import("config.zig");

pub fn main() !u8 {
    var start = try std.time.Timer.start();
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer if (builtin.mode == .Debug) {
        _ = dbg.deinit();
    };
    const gpa = if (builtin.mode == .Debug) dbg.allocator() else std.heap.c_allocator;

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var diag: cli.Diag = .{};
    const opts = cli.parse(args[1..], &diag) catch {
        if (diag.arg) |a| {
            std.debug.print("felt: {s}: {s}\nTry: felt --help\n", .{ diag.msg, a });
        } else {
            std.debug.print("felt: {s}\nTry: felt --help\n", .{diag.msg});
        }
        return 2;
    };

    var default_out: ?[]u8 = null;
    var montage_out: ?[]u8 = null;
    defer if (montage_out) |p| gpa.free(p);
    defer if (default_out) |p| gpa.free(p);
    // Only the window reads and writes the config file (headless: hermetic).
    const config_path = if (opts.mode == .window or opts.mode == .capture) try config.path(gpa, config.Env.ofProcess()) else null;
    defer if (config_path) |p| gpa.free(p);
    switch (opts.mode) {
        .help => try writeStdout(cli.usage),
        .keymap_md => {
            var buf: [16 * 1024]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            try core.keymap.writeMarkdown(&w);
            try writeStdout(w.buffered());
        },
        .headless => headless.run(gpa, .{
            .image_path = opts.image.?,
            .script_path = opts.script,
            .size = opts.size,
            .frame_out = opts.frame_out,
            .export_out = opts.export_out,
            .output_path = opts.output,
            .clipboard_out = opts.clipboard_out,
            .canvas_bg = opts.canvas_bg,
            .ui_font = headlessUiFont(),
        }) catch |err| return fail(err, opts.image.?),
        .capture => {
            // Pick the region first; null: cancelled (no editor, exit status 1).
            const image = (x11_capture.run(gpa, .{ .delay_ms = opts.delay_ms, .timing = opts.timing, .config_path = config_path }) catch |err| return fail(err, "(screen)")) orelse return 1;
            const out = opts.output orelse blk: {
                default_out = try cli.captureOutput(gpa, std.posix.getenv("HOME"), std.time.timestamp());
                break :blk default_out.?;
            };
            x11.run(gpa, .{
                .image = image,
                .output_path = out,
                .timing = opts.timing,
                .config_path = config_path,
                .canvas_bg = opts.canvas_bg,
            }, &start) catch |err| return fail(err, "(capture)");
        },
        .window => x11.run(gpa, .{
            .image_path = opts.image.?,
            .output_path = opts.output orelse blk: {
                default_out = if (opts.n_extra > 0) try cli.montageOutput(gpa, opts.image.?) else try cli.defaultOutput(gpa, opts.image.?);
                break :blk default_out.?;
            },
            .timing = opts.timing,
            .smoke = opts.smoke,
            .extra_paths = opts.extra[0..opts.n_extra],
            .montage_output = if (opts.output == null and opts.n_extra == 0) blk: {
                montage_out = try cli.montageOutput(gpa, opts.image.?);
                break :blk montage_out.?;
            } else null,
            .config_path = config_path,
            .canvas_bg = opts.canvas_bg,
        }, &start) catch |err| return fail(err, opts.image.?),
        .bench => bench.run(gpa, .{
            .image_path = opts.image,
            .size = opts.size orelse .{ 1920, 1080 },
        }) catch |err| return fail(err, opts.image orelse "(synthetic)"),
    }
    return 0;
}

/// Headless only: FELT_UI_FONT (a font file) and FELT_UI_FONT_SIZE, to look
/// at a font in a shot. Never the config file.
fn headlessUiFont() core.settings.Settings {
    var s = core.settings.Settings{};
    const path = std.posix.getenv("FELT_UI_FONT") orelse return s;
    s.ui_font = core.settings.FontPath.of(path);
    if (std.posix.getenv("FELT_UI_FONT_SIZE")) |v| s.ui_font_size = std.fmt.parseInt(u8, v, 10) catch s.ui_font_size;
    return s;
}

fn fail(err: anyerror, image: []const u8) u8 {
    switch (err) {
        error.DecodeFailed => std.debug.print("felt: cannot decode {s} (PNG, JPEG or BMP expected)\n", .{image}),
        error.FileNotFound => std.debug.print("felt: cannot open {s}: file not found\n", .{image}),
        error.IsDir => std.debug.print("felt: {s} is a directory\n", .{image}),
        error.WriteReported => {}, // already printed with the path
        error.BadScript => {}, // already printed with file:line
        error.NoDisplay => std.debug.print("felt: cannot open X display (DISPLAY not set?). Without a display use --headless.\n", .{}),
        error.GrabFailed => std.debug.print("felt: cannot grab the screen, the pointer or the keyboard (another program holds it?)\n", .{}),
        error.UnsupportedVisual => std.debug.print("felt: X visual is not 24/32-bit TrueColor RGB\n", .{}),
        else => std.debug.print("felt: {s}\n", .{@errorName(err)}),
    }
    return 1;
}

fn writeStdout(s: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.writeAll(s);
    try w.interface.flush();
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("backend/script.zig");
    _ = @import("app.zig");
    _ = @import("config.zig");
    _ = @import("golden.zig");
}
