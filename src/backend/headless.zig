//! Headless backend: replays an event script against an image without any
//! window and writes the UI frame and/or the export to PNG files.
//! Used by golden tests, `zig build shot`, and agents that need to see the UI.
const std = @import("std");
const core = @import("core");
const app_mod = @import("../app.zig");
const script_mod = @import("script.zig");
const config = @import("../config.zig");

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
    /// --canvas-bg. Headless never reads or writes the config file.
    canvas_bg: ?core.settings.CanvasBg = null,
};

/// Replay `script` on a new App that owns `image`. Renders after each event
/// that asks for it, like the window loop, so damage tracking is exercised.
pub fn replay(gpa: std.mem.Allocator, image: Canvas, script: *const script_mod.Script, size_override: ?[2]u32, cfg: app_mod.Config) !*App {
    const size = size_override orelse script.size orelse default_size;
    const app = try App.create(gpa, image, size[0], size[1], cfg);
    errdefer app.destroy();
    _ = try app.render();
    for (script.events.items) |step| switch (step) {
        .event => |ev| {
            try checkOffChrome(app, ev);
            if (try feed(app, ev)) break;
        },
        .ui => |t| {
            const p = try uiPoint(app, t, .click) orelse continue;
            app.editor.chrome_press_ok = true; // `ui` clicks chrome on purpose
            defer app.editor.chrome_press_ok = false;
            if (try feed(app, .{ .mouse_down = .{ .x = p.x, .y = p.y } })) break;
            if (try feed(app, .{ .mouse_up = .{ .x = p.x, .y = p.y } })) break;
        },
        .add_image => |a| {
            try app.addImageFile(a);
            _ = app.editor.syncView();
            _ = try app.render();
        },
        .dropzone => |d| {
            if (d) |z| app.editor.setMontageDrop(z.w, z.h, z.pointer) else app.editor.clearMontageDrop();
            _ = try app.render();
        },
        .browser => |b| {
            if (try browserStep(app, b)) break;
        },
        .touch => |t| try touch(t.path, t.secs),
        .hover => |t| {
            const p = try uiPoint(app, t, .hover) orelse continue;
            if (try feed(app, .{ .mouse_move = .{ .x = p.x, .y = p.y } })) break;
        },
    };
    return app;
}

/// The outcome of a capture script: the last picker frame and, if the
/// script confirmed a selection, the cropped image (of the frozen screen:
/// headless has no live screen, so the delay changes only the pill).
pub const CaptureReplay = struct {
    picker: core.picker.Picker,
    frame: Canvas,
    crop: ?Canvas,
    scene: core.picker_draw.Scene,

    pub fn deinit(self: *CaptureReplay, gpa: std.mem.Allocator) void {
        self.frame.deinit(gpa);
        if (self.crop) |*c| c.deinit(gpa);
    }
};

/// Replay a `capture` script on the picker. `frozen` is the screen: the
/// frame has its size. Borrows `script` (the picker points at its windows).
pub fn replayCapture(gpa: std.mem.Allocator, frozen: *const Canvas, script: *const script_mod.Script) !CaptureReplay {
    var font = try core.font.Font.init(gpa, core.font_ttf);
    defer font.deinit();
    const ctx = core.draw.Ctx{ .gpa = gpa, .font = &font };
    var r = CaptureReplay{
        .picker = core.picker.Picker.init(frozen.width, frozen.height, script.windows.items, script.delay_ms),
        .frame = try Canvas.init(gpa, frozen.width, frozen.height),
        .crop = null,
        .scene = .{},
    };
    errdefer r.deinit(gpa);
    _ = try r.scene.render(ctx, &r.picker, frozen, &r.frame);
    for (script.events.items) |step| switch (step) {
        .event => |ev| {
            if (r.picker.finished()) break;
            if (r.picker.handle(ev).redraw) _ = try r.scene.render(ctx, &r.picker, frozen, &r.frame);
        },
        .ui, .hover, .add_image, .dropzone, .browser, .touch => {
            std.log.err("script: `ui`, `move ui`, `place`, `addimage` and `dropzone` need the editor, not the capture picker", .{});
            return error.BadScript;
        },
    };
    if (r.picker.result) |rect| r.crop = try core.picker.crop(gpa, frozen, rect);
    return r;
}

/// Set the modification time of `path` (repo-relative) to `secs`.
fn touch(path: []const u8, secs: i64) !void {
    var f = try std.fs.cwd().openFile(path, .{}); // a folder opens too
    defer f.close();
    const t = @as(i128, secs) * std.time.ns_per_s;
    try f.updateTimes(t, t);
}

fn mid(b: core.geom.Bounds) core.geom.Vec2 {
    return b.min.add(b.max).scale(0.5);
}

/// The browser row named `name` (`..` for the parent row), scrolled into view.
fn rowNamed(app: *App, name: []const u8) !usize {
    const b = &app.editor.browser;
    var i: usize = 0;
    while (i < b.rowCount()) : (i += 1) {
        const hit = if (b.entryOf(i)) |e| std.mem.eql(u8, e.name, name) else std.mem.eql(u8, name, "..");
        if (!hit) continue;
        const g = b.geo();
        const top = @as(f32, @floatFromInt(i)) * g.row_h;
        if (top < b.scroll or top + g.row_h > b.scroll + g.listHeight()) _ = b.scrollBy(top - b.scroll);
        return i;
    }
    std.log.err("script: browser: no row named {s} in {s}", .{ name, b.path });
    return error.BrowserRowNotFound;
}

/// Run a `browser` command; true on quit.
fn browserStep(app: *App, cmd: script_mod.BrowserCmd) !bool {
    const b = &app.editor.browser;
    switch (cmd) {
        .home => |dir| {
            const abs = try std.fs.cwd().realpathAlloc(app.gpa, dir);
            defer app.gpa.free(abs);
            try b.setHome(abs);
        },
        .up => {
            const p = mid(b.geo().up);
            if (try feed(app, .{ .mouse_down = .{ .x = p.x, .y = p.y } })) return true;
            return feed(app, .{ .mouse_up = .{ .x = p.x, .y = p.y } });
        },
        .cd => |name| {
            const i = try rowNamed(app, name);
            const p = mid(b.geo().row(i, b.scroll));
            if (try feed(app, .{ .mouse_move = .{ .x = p.x, .y = p.y } })) return true;
            if (try feed(app, .{ .mouse_down = .{ .x = p.x, .y = p.y } })) return true;
            return feed(app, .{ .mouse_up = .{ .x = p.x, .y = p.y } });
        },
        .scroll => |n| {
            const p = mid(b.geo().list);
            var k: u32 = 0;
            while (k < @abs(n)) : (k += 1) {
                if (try feed(app, .{ .wheel = .{ .delta = if (n > 0) -1 else 1, .x = p.x, .y = p.y } })) return true;
            }
        },
        .drag => |d| {
            const i = try rowNamed(app, d.name);
            const p0 = mid(b.geo().row(i, b.scroll));
            if (try feed(app, .{ .mouse_move = .{ .x = p0.x, .y = p0.y } })) return true;
            if (try feed(app, .{ .mouse_down = .{ .x = p0.x, .y = p0.y } })) return true;
            const steps = 8;
            var k: u32 = 1;
            while (k <= steps) : (k += 1) {
                const t = @as(f32, @floatFromInt(k)) / steps;
                if (try feed(app, .{ .mouse_move = .{ .x = p0.x + (d.x - p0.x) * t, .y = p0.y + (d.y - p0.y) * t } })) return true;
            }
            if (!d.hold) return feed(app, .{ .mouse_up = .{ .x = d.x, .y = d.y } });
        },
    }
    return false;
}

/// A raw left press of a script that would land on the dock, its style
/// switch or the top bar is an error: chrome moves (a new slot, a switch
/// that shows with a tool), so a script that meant to draw there would
/// silently click a button instead. Scripts click chrome with `ui`.
fn checkOffChrome(app: *App, ev: core.input.Event) !void {
    if (ev != .mouse_down or ev.mouse_down.button != .left) return;
    const ed = &app.editor;
    if (ed.help_visible or ed.mode == .drag or ed.mode == .moving or ed.mode == .image_drag) return;
    const p = core.geom.Vec2.init(ev.mouse_down.x, ev.mouse_down.y);
    if (!ed.onChrome(p)) return;
    std.log.err("script: a press at {d} {d} lands on the dock, its style switch or the top bar: click chrome with `ui ...`, or draw elsewhere", .{ p.x, p.y });
    return error.ScriptPressOnChrome;
}

/// Handle one event, render if asked; true on quit.
fn feed(app: *App, ev: core.input.Event) !bool {
    var r = try app.handle(ev);
    if (app.pump()) r.redraw = true; // headless: results are there already
    // No clock in a replay: an animation ends at once, so frames are deterministic.
    if (app.editor.finishAnimation()) r.redraw = true;
    if (r.redraw) _ = try app.render();
    return r.quit;
}

/// Screen center of a chrome item at the current screen size and tool;
/// null: no click needed (the canvas background or the arrow style is
/// already the one named). A hover always gets the point.
fn uiPoint(app: *App, t: script_mod.UiTarget, why: enum { click, hover }) !?core.geom.Vec2 {
    const w = app.editor.view.screen_w;
    const h = app.editor.view.screen_h;
    const d = core.dock.Dock.of(w, h, app.editor.tool);
    const bar = core.topbar.TopBar.of(w, h);
    const pbar = core.padbar.PadBar.of(w, h);
    return switch (t) {
        .tool => |tool| for (core.keymap.tools, 0..) |info, i| {
            if (info.tool == tool) break mid(d.tools[i]);
        } else unreachable,
        .color => |i| d.swatches[i],
        .size => mid(d.size),
        .help => mid(d.help),
        .undo => mid(bar.slots[0]),
        .redo => mid(bar.slots[1]),
        .browser => mid(core.browsergeo.Geo.of(w, h).folder),
        .canvas_bg => |want| if (why == .click and want != null and want.? == app.editor.settings.canvas_bg) null else mid(bar.slots[2]),
        .padding => |px| {
            const step = core.settings.paddingIndex(px);
            if (why == .click and core.settings.padding_steps[step] == app.editor.settings.padding) return null;
            return .{ .x = pbar.notchX(step), .y = pbar.trackY() };
        },
        .arrow_style => |want| {
            if (d.switch_panel == null) {
                std.log.err("script: ui arrow-style: the switch shows only with the arrow or the callout tool", .{});
                return error.UiItemHidden;
            }
            const cur = app.editor.arrow_style;
            if (why == .click and want != null and want.? == cur) return null;
            const st = want orelse (if (cur == .straight) core.annotation.ArrowStyle.stairs else .straight);
            for (core.dock.arrow_styles, d.styles) |s, b| if (s == st) return mid(b);
            unreachable;
        },
        .text_style => |want| {
            if (d.switch_panel == null or app.editor.tool != .text) {
                std.log.err("script: ui text-style: the switch shows only with the text tool", .{});
                return error.UiItemHidden;
            }
            const cur = app.editor.text_style;
            if (why == .click and want != null and want.? == cur) return null;
            const st = want orelse (if (cur == .plain) core.annotation.TextStyle.boxed else .plain);
            for (core.dock.text_styles, d.styles) |s, b| if (s == st) return mid(b);
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
        std.debug.print("felt: cannot write {s}: {s} (does the directory exist?)\n", .{ path, @errorName(err) });
        return error.WriteReported;
    };
}

/// The app config of a headless run: the defaults and the flag, no config
/// file path, so a settings change (`b`) writes nothing.
fn appConfig(opts: Options) app_mod.Config {
    return .{
        .output_path = opts.output_path,
        .clipboard = if (opts.clipboard_out) |p| .{ .file = p } else .none,
        .settings = config.resolve(.{}, opts.canvas_bg),
        .settings_path = null,
    };
}

pub fn run(gpa: std.mem.Allocator, opts: Options) !void {
    var script = if (opts.script_path) |p| try loadScript(gpa, p) else script_mod.Script{};
    defer script.deinit(gpa);
    const image_path = script.image orelse opts.image_path;
    const image = core.image_io.load(gpa, image_path) catch |err| {
        std.debug.print("felt: cannot load {s}: {s}\n", .{ image_path, @errorName(err) });
        return error.WriteReported;
    };
    if (script.capture) {
        var frozen = image;
        defer frozen.deinit(gpa);
        var r = try replayCapture(gpa, &frozen, &script);
        defer r.deinit(gpa);
        if (opts.frame_out) |p| {
            try save(gpa, &r.frame, p);
            std.debug.print("frame  {d}x{d} -> {s}\n", .{ r.frame.width, r.frame.height, p });
        }
        if (opts.export_out) |p| {
            const crop = r.crop orelse {
                std.debug.print("note: the script did not confirm a selection ({s}), no crop written\n", .{@tagName(r.picker.phase)});
                return;
            };
            try save(gpa, &crop, p);
            std.debug.print("crop   {d}x{d} -> {s}\n", .{ crop.width, crop.height, p });
        }
        return;
    }
    const app = try replay(gpa, image, &script, opts.size, appConfig(opts));
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

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// An environment variable set for a test, put back by `restore`.
const EnvSwap = struct {
    name: [:0]const u8,
    old: ?[:0]u8,

    fn set(gpa: std.mem.Allocator, name: [:0]const u8, value: [:0]const u8) !EnvSwap {
        const old = if (std.posix.getenv(name)) |v| try gpa.dupeZ(u8, v) else null;
        _ = setenv(name, value, 1);
        return .{ .name = name, .old = old };
    }

    fn restore(e: EnvSwap, gpa: std.mem.Allocator) void {
        if (e.old) |v| {
            _ = setenv(e.name, v, 1);
            gpa.free(v);
        } else _ = unsetenv(e.name);
    }
};

test "headless never reads or writes the config file" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(dir);
    const dir_z = try gpa.dupeZ(u8, dir);
    defer gpa.free(dir_z);
    // XDG_CONFIG_HOME and HOME both point at the tmp dir, each with a dark config.
    const cfg = "canvas_bg=dark\n";
    try tmp.dir.makePath("felt");
    try tmp.dir.makePath(".config/felt");
    try tmp.dir.writeFile(.{ .sub_path = "felt/config", .data = cfg });
    try tmp.dir.writeFile(.{ .sub_path = ".config/felt/config", .data = cfg });
    const xdg = try EnvSwap.set(gpa, "XDG_CONFIG_HOME", dir_z);
    defer xdg.restore(gpa);
    const home = try EnvSwap.set(gpa, "HOME", dir_z);
    defer home.restore(gpa);

    // A headless run's config: the default or the flag, never the file's.
    try std.testing.expectEqual(core.settings.CanvasBg.light, appConfig(.{ .image_path = "x" }).settings.canvas_bg);
    try std.testing.expectEqual(core.settings.CanvasBg.dark, appConfig(.{ .image_path = "x", .canvas_bg = .dark }).settings.canvas_bg);
    try std.testing.expectEqual(@as(?[]const u8, null), appConfig(.{ .image_path = "x", .canvas_bg = .dark }).settings_path);
    // A replay with `b` (a settings change): light (not the file's dark), then dark.
    var perr: script_mod.ParseError = undefined;
    var s = try script_mod.parse(gpa, "size 200 150\nkey b\n", &perr);
    defer s.deinit(gpa);
    const app = try replay(gpa, try Canvas.init(gpa, 40, 30), &s, null, appConfig(.{ .image_path = "x" }));
    defer app.destroy();
    try std.testing.expectEqual(core.settings.CanvasBg.dark, app.editor.settings.canvas_bg);
    // Both files stay as they were, with no temp file next to them.
    var buf: [64]u8 = undefined;
    for ([_][]const u8{ "felt", ".config/felt" }) |sub| {
        var d = try tmp.dir.openDir(sub, .{ .iterate = true });
        defer d.close();
        try std.testing.expectEqualStrings(cfg, try d.readFile("config", &buf));
        var it = d.iterate();
        var n: usize = 0;
        while (try it.next()) |_| n += 1;
        try std.testing.expectEqual(@as(usize, 1), n);
    }
}

test "ui arrow-style NAME clicks only if the style is not NAME yet" {
    const gpa = std.testing.allocator;
    var perr: script_mod.ParseError = undefined;
    // Stairs by a click (a toast), a key hides the toast, stairs again: no click, no toast.
    var s = try script_mod.parse(gpa, "size 900 500\nui tool arrow\nui arrow-style stairs\nkey 1\nui arrow-style stairs\n", &perr);
    defer s.deinit(gpa);
    const app = try replay(gpa, try Canvas.init(gpa, 40, 30), &s, null, appConfig(.{ .image_path = "x" }));
    defer app.destroy();
    try std.testing.expectEqual(core.annotation.ArrowStyle.stairs, app.editor.arrow_style);
    try std.testing.expectEqual(@as(?[]const u8, null), app.editor.toast());
}
