//! Headless backend: replays an event script against an image without any
//! window and writes the UI frame and/or the export to PNG files.
//! Used by golden tests, `zig build shot`, and agents that need to see the UI.
const std = @import("std");
const core = @import("core");
const app_mod = @import("../app.zig");
const script_mod = @import("script.zig");

const App = app_mod.App;
const Canvas = core.canvas.Canvas;

pub const default_size = [2]u32{ 1280, 720 };

pub const Options = struct {
    image_path: []const u8,
    script_path: ?[]const u8 = null,
    size: ?[2]u32 = null,
    frame_out: ?[]const u8 = null,
    export_out: ?[]const u8 = null,
    /// Ctrl+S target inside the script (off when null).
    output_path: ?[]const u8 = null,
    /// Ctrl+C target inside the script (off when null).
    clipboard_out: ?[]const u8 = null,
};

/// Replay `script` on a new App that owns `image`. Renders after each event
/// that asks for it, like the window loop, so damage tracking is exercised.
pub fn replay(gpa: std.mem.Allocator, image: Canvas, script: *const script_mod.Script, size_override: ?[2]u32, cfg: app_mod.Config) !*App {
    const size = size_override orelse script.size orelse default_size;
    const app = try App.create(gpa, image, size[0], size[1], cfg);
    errdefer app.destroy();
    _ = try app.render();
    for (script.events.items) |step| switch (step) {
        .event => |ev| if (try feed(app, ev)) break,
        .ui => |t| {
            const p = try uiPoint(app, t);
            if (try feed(app, .{ .mouse_down = .{ .x = p.x, .y = p.y } })) break;
            if (try feed(app, .{ .mouse_up = .{ .x = p.x, .y = p.y } })) break;
        },
    };
    return app;
}

/// Handle one event, render if asked; true on quit.
fn feed(app: *App, ev: core.input.Event) !bool {
    const r = try app.handle(ev);
    if (r.redraw) _ = try app.render();
    return r.quit;
}

/// Screen center of a chrome item at the current screen size and tool.
fn uiPoint(app: *App, t: script_mod.UiTarget) !core.geom.Vec2 {
    const w = app.editor.view.screen_w;
    const h = app.editor.view.screen_h;
    const d = core.dock.Dock.of(w, h, app.editor.tool);
    const bar = core.topbar.TopBar.of(w, h);
    const mid = struct {
        fn f(b: core.geom.Bounds) core.geom.Vec2 {
            return b.min.add(b.max).scale(0.5);
        }
    }.f;
    return switch (t) {
        .tool => |tool| for (core.keymap.tools, 0..) |info, i| {
            if (info.tool == tool) break mid(d.tools[i]);
        } else unreachable,
        .color => |i| d.swatches[i],
        .size => mid(d.size),
        .help => mid(d.help),
        .undo => mid(bar.slots[0]),
        .redo => mid(bar.slots[1]),
        .arrow_style => |want| {
            if (d.switch_panel == null) {
                std.log.err("script: ui arrow-style: the switch shows only with the arrow tool", .{});
                return error.UiItemHidden;
            }
            const cur = app.editor.arrow_style;
            const st = want orelse (if (cur == .straight) core.annotation.ArrowStyle.stairs else .straight);
            for (core.dock.arrow_styles, d.styles) |s, b| if (s == st) return mid(b);
            unreachable;
        },
    };
}

/// Read and parse a script file; prints `path:line: message` on errors.
pub fn loadScript(gpa: std.mem.Allocator, path: []const u8) !script_mod.Script {
    const src = std.fs.cwd().readFileAlloc(gpa, path, 1 << 20) catch |err| {
        std.debug.print("error: cannot read script {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer gpa.free(src);
    var perr: script_mod.ParseError = undefined;
    return script_mod.parse(gpa, src, &perr) catch |err| {
        if (err == error.BadScript) std.debug.print("{s}:{d}: error: {s}\n", .{ path, perr.line, perr.msg });
        return err;
    };
}

fn save(gpa: std.mem.Allocator, cv: *const Canvas, path: []const u8) !void {
    core.image_io.savePng(gpa, cv, path) catch |err| {
        std.debug.print("annotate: cannot write {s}: {s} (does the directory exist?)\n", .{ path, @errorName(err) });
        return error.WriteReported;
    };
}

pub fn run(gpa: std.mem.Allocator, opts: Options) !void {
    var script = if (opts.script_path) |p| try loadScript(gpa, p) else script_mod.Script{};
    defer script.deinit(gpa);
    const image_path = script.image orelse opts.image_path;
    const image = core.image_io.load(gpa, image_path) catch |err| {
        std.debug.print("annotate: cannot load {s}: {s}\n", .{ image_path, @errorName(err) });
        return error.WriteReported;
    };
    const app = try replay(gpa, image, &script, opts.size, .{
        .output_path = opts.output_path,
        .clipboard = if (opts.clipboard_out) |p| .{ .file = p } else .none,
    });
    defer app.destroy();
    if (opts.frame_out) |p| {
        try save(gpa, app.frame(), p);
        std.debug.print("frame  {d}x{d} -> {s}\n", .{ app.frame().width, app.frame().height, p });
    }
    if (opts.export_out) |p| {
        var out = try app.exportImage();
        defer out.deinit(gpa);
        try save(gpa, &out, p);
        std.debug.print("export {d}x{d} -> {s}\n", .{ out.width, out.height, p });
    }
    if (opts.frame_out == null and opts.export_out == null) {
        std.debug.print("note: no --frame-out or --export-out given, nothing written\n", .{});
    }
}
