//! Entry point: parses the command line and starts a backend.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const cli = @import("cli.zig");
const headless = @import("backend/headless.zig");
const x11 = @import("backend/x11.zig");

pub fn main() !u8 {
    var start = try std.time.Timer.start();
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer if (builtin.mode == .Debug) {
        _ = dbg.deinit();
    };
    const gpa = if (builtin.mode == .Debug) dbg.allocator() else std.heap.c_allocator;

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var msg: []const u8 = "";
    const opts = cli.parse(args[1..], &msg) catch {
        std.debug.print("annotate: {s}\nTry: annotate --help\n", .{msg});
        return 2;
    };

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
        }) catch |err| return fail(err, opts.image.?),
        .window => x11.run(gpa, .{
            .image_path = opts.image.?,
            .output_path = opts.output orelse opts.image.?,
            .timing = opts.timing,
            .smoke = opts.smoke,
        }, &start) catch |err| return fail(err, opts.image.?),
        .bench => {
            std.debug.print("annotate: not implemented yet\n", .{});
            return 1;
        },
    }
    return 0;
}

fn fail(err: anyerror, image: []const u8) u8 {
    switch (err) {
        error.DecodeFailed => std.debug.print("annotate: cannot decode {s} (PNG, JPEG or BMP expected)\n", .{image}),
        error.FileNotFound => std.debug.print("annotate: file not found ({s} or a path in the options)\n", .{image}),
        error.BadScript => {}, // already printed with file:line
        error.NoDisplay => std.debug.print("annotate: cannot open X display (DISPLAY not set?). Without a display use --headless.\n", .{}),
        error.UnsupportedVisual => std.debug.print("annotate: X visual is not 24/32-bit TrueColor RGB\n", .{}),
        else => std.debug.print("annotate: {s}\n", .{@errorName(err)}),
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
    _ = @import("golden.zig");
}
