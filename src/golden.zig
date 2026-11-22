//! Golden tests: replay every tests/scripts/*.txt on tests/fixtures/screenshot.png
//! (or the script's `image`) and compare the UI frame and the export with tests/golden/<name>.{frame,export}.png.
//! Mismatches write <name>.*.{actual,expected,diff}.png to test-out/golden/.
//! Update goldens: `zig build test -Dupdate-goldens=true`.
//! Also checks that incremental (damage-tracked) frames equal a full repaint.
const std = @import("std");
const core = @import("core");
const headless = @import("backend/headless.zig");
const App = @import("app.zig").App;

const Canvas = core.canvas.Canvas;

pub const fixture = "tests/fixtures/screenshot.png";
pub const scripts_dir = "tests/scripts";
pub const golden_dir = "tests/golden";
pub const out_dir = "test-out/golden";

/// A pixel counts as different when a channel differs by more than this.
const channel_tolerance = 8;
/// A image fails when more than this fraction of pixels differ.
const max_bad_fraction = 0.0005;

fn updating() bool {
    return std.process.hasEnvVarConstant("ANNOTATE_UPDATE_GOLDENS");
}

const Diff = struct { bad: usize, max_delta: u32 };

fn compare(a: *const Canvas, b: *const Canvas, diff_img: ?*Canvas) Diff {
    var d = Diff{ .bad = 0, .max_delta = 0 };
    for (a.pixels, b.pixels, 0..) |pa, pb, i| {
        var m: u32 = 0;
        inline for (.{ 0, 8, 16 }) |sh| {
            const x: i32 = @intCast((pa >> sh) & 0xff);
            const y: i32 = @intCast((pb >> sh) & 0xff);
            m = @max(m, @abs(x - y));
        }
        d.max_delta = @max(d.max_delta, m);
        const bad = m > channel_tolerance;
        if (bad) d.bad += 1;
        if (diff_img) |img| {
            const g = (((pb >> 16) & 0xff) + ((pb >> 8) & 0xff) + (pb & 0xff)) / 12; // dim gray
            img.pixels[i] = if (bad) 0xffff00ff else 0xff000000 | (g << 16) | (g << 8) | g;
        }
    }
    return d;
}

fn writeOut(gpa: std.mem.Allocator, cv: *const Canvas, name: []const u8, kind: []const u8) void {
    std.fs.cwd().makePath(out_dir) catch {};
    const p = std.fmt.allocPrint(gpa, "{s}/{s}.{s}.png", .{ out_dir, name, kind }) catch return;
    defer gpa.free(p);
    core.image_io.savePng(gpa, cv, p) catch {};
}

/// Compare `actual` to tests/golden/<name>.png. Returns false on mismatch.
pub fn check(gpa: std.mem.Allocator, name: []const u8, actual: *const Canvas) !bool {
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ golden_dir, name });
    defer gpa.free(path);
    var expected = core.image_io.load(gpa, path) catch |err| {
        if (updating()) {
            try core.image_io.savePng(gpa, actual, path);
            std.debug.print("golden {s}: created\n", .{name});
            return true;
        }
        std.debug.print("golden {s}: cannot load {s} ({s}). New script? Run: zig build test -Dupdate-goldens=true\n", .{ name, path, @errorName(err) });
        writeOut(gpa, actual, name, "actual");
        return false;
    };
    defer expected.deinit(gpa);
    if (updating()) {
        // Rewrite only on a pixel change: no churn from encoder changes.
        if (expected.width == actual.width and expected.height == actual.height and std.mem.eql(u32, expected.pixels, actual.pixels)) return true;
        try core.image_io.savePng(gpa, actual, path);
        std.debug.print("golden {s}: updated\n", .{name});
        return true;
    }
    if (expected.width != actual.width or expected.height != actual.height) {
        std.debug.print("golden {s}: size {d}x{d}, expected {d}x{d}\n", .{ name, actual.width, actual.height, expected.width, expected.height });
        writeOut(gpa, actual, name, "actual");
        return false;
    }
    var diff = try Canvas.init(gpa, actual.width, actual.height);
    defer diff.deinit(gpa);
    const d = compare(actual, &expected, &diff);
    const limit: usize = @intFromFloat(@as(f64, @floatFromInt(actual.pixels.len)) * max_bad_fraction);
    if (d.bad <= limit) return true;
    std.debug.print("golden {s}: {d} pixels differ (limit {d}, max channel delta {d}). See {s}/{s}.{{actual,expected,diff}}.png\n", .{ name, d.bad, limit, d.max_delta, out_dir, name });
    writeOut(gpa, actual, name, "actual");
    writeOut(gpa, &expected, name, "expected");
    writeOut(gpa, &diff, name, "diff");
    return false;
}

/// Script names (without .txt), sorted. Caller frees.
pub fn listScripts(gpa: std.mem.Allocator) ![][]const u8 {
    var dir = try std.fs.cwd().openDir(scripts_dir, .{ .iterate = true });
    defer dir.close();
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".txt")) continue;
        try names.append(gpa, try gpa.dupe(u8, e.name[0 .. e.name.len - 4]));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return names.toOwnedSlice(gpa);
}

fn replayScript(gpa: std.mem.Allocator, name: []const u8) !*App {
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}.txt", .{ scripts_dir, name });
    defer gpa.free(path);
    var script = try headless.loadScript(gpa, path);
    defer script.deinit(gpa);
    const image = try core.image_io.load(gpa, script.image orelse fixture);
    return headless.replay(gpa, image, &script, null, .{ .output_path = null, .clipboard = .none });
}

test "golden replays" {
    const gpa = std.testing.allocator;
    std.fs.cwd().deleteTree(out_dir) catch {};
    const names = try listScripts(gpa);
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    try std.testing.expect(names.len > 0);
    var failed: usize = 0;
    for (names) |name| {
        const app = try replayScript(gpa, name);
        defer app.destroy();

        // Damage tracking must give the same pixels as a full repaint.
        var fresh = core.compositor.Compositor{ .gpa = gpa };
        defer fresh.deinit();
        _ = try fresh.render(app.ctx(), &app.image, &app.doc, &app.editor);
        const d = compare(app.frame(), &fresh.frame.?, null);
        if (d.bad > 0) {
            std.debug.print("golden {s}: incremental frame differs from a full repaint in {d} pixels (damage tracking bug). See {s}/{s}.damage.*.png\n", .{ name, d.bad, out_dir, name });
            writeOut(gpa, app.frame(), name, "damage.incremental");
            writeOut(gpa, &fresh.frame.?, name, "damage.full");
            failed += 1;
        }

        const frame_name = try std.fmt.allocPrint(gpa, "{s}.frame", .{name});
        defer gpa.free(frame_name);
        if (!try check(gpa, frame_name, app.frame())) failed += 1;

        var exp = try app.exportImage();
        defer exp.deinit(gpa);
        const export_name = try std.fmt.allocPrint(gpa, "{s}.export", .{name});
        defer gpa.free(export_name);
        if (!try check(gpa, export_name, &exp)) failed += 1;
    }
    if (updating()) std.debug.print("checked {d} scripts; goldens with new pixels were rewritten in {s}/\n", .{ names.len, golden_dir });
    if (failed > 0) {
        std.debug.print("{d} golden check(s) failed. Look at the PNGs in {s}/. If the change is intended: zig build test -Dupdate-goldens=true\n", .{ failed, out_dir });
        return error.GoldenMismatch;
    }
}

test "export is at original resolution with annotations mapped from screen" {
    const gpa = std.testing.allocator;
    var image = try Canvas.init(gpa, 400, 300);
    image.fill(core.color.Color.rgb(0x808080));
    const app = try App.create(gpa, image, 200, 150, .{ .output_path = null, .clipboard = .none });
    defer app.destroy();
    try std.testing.expectEqual(@as(f32, 0.5), app.editor.view.xf.scale);
    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'r' } } });
    _ = try app.handle(.{ .mouse_down = .{ .x = 20, .y = 20 } });
    _ = try app.handle(.{ .mouse_move = .{ .x = 180, .y = 130 } });
    _ = try app.handle(.{ .mouse_up = .{ .x = 180, .y = 130 } });
    _ = try app.render();
    var out = try app.exportImage();
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 400), out.width);
    try std.testing.expectEqual(@as(u32, 300), out.height);
    const red = core.color.palette[0].color.toPixel();
    // Screen (20, 20)..(180, 130) is image (40, 40)..(360, 260).
    try std.testing.expectEqual(red, out.at(40, 150));
    try std.testing.expectEqual(red, out.at(360, 150));
    try std.testing.expectEqual(red, out.at(200, 260));
    try std.testing.expectEqual(@as(u32, 0xff808080), out.at(200, 150));
    try std.testing.expectEqual(red, app.frame().at(20, 75)); // left edge on screen, clear of the panels
}

test "crop exports the kept part at original resolution; undo restores" {
    const gpa = std.testing.allocator;
    var image = try Canvas.init(gpa, 400, 300);
    image.fill(core.color.Color.rgb(0x808080));
    const app = try App.create(gpa, image, 200, 150, .{ .output_path = null, .clipboard = .none });
    defer app.destroy();
    const ev = struct {
        fn key(c: u21) core.input.Event {
            return .{ .key = .{ .key = .{ .char = c } } };
        }
        fn drag(a: *App, x0: f32, y0: f32, x1: f32, y1: f32) !void {
            _ = try a.handle(.{ .mouse_down = .{ .x = x0, .y = y0 } });
            _ = try a.handle(.{ .mouse_move = .{ .x = x1, .y = y1 } });
            _ = try a.handle(.{ .mouse_up = .{ .x = x1, .y = y1 } });
            _ = try a.render();
        }
    };
    _ = try app.handle(ev.key('r'));
    try ev.drag(app, 20, 20, 180, 130); // image (40, 40)..(360, 260)
    _ = try app.handle(ev.key('x'));
    try ev.drag(app, 10, 10, 110, 80); // image (20, 20)..(220, 160)
    var out = try app.exportImage();
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 200), out.width);
    try std.testing.expectEqual(@as(u32, 140), out.height);
    const red = core.color.palette[0].color.toPixel();
    try std.testing.expectEqual(red, out.at(20, 100)); // left edge of the rect, shifted by the crop origin
    try std.testing.expectEqual(red, out.at(100, 20)); // top edge
    try std.testing.expectEqual(@as(u32, 0xff808080), out.at(100, 100));

    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'z' }, .mods = .{ .ctrl = true } } });
    var full = try app.exportImage();
    defer full.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 400), full.width);
    try std.testing.expectEqual(@as(u32, 300), full.height);
    try std.testing.expectEqual(red, full.at(40, 150));
}

test "drawing past the image grows the exported PNG with white; undo shrinks it" {
    const gpa = std.testing.allocator;
    var image = try Canvas.init(gpa, 100, 50);
    image.fill(core.color.Color.rgb(0x808080));
    image.fillRect(core.geom.Rect.fromSize(0, 0, 10, 10), core.color.Color.rgb(0x102030));
    std.fs.cwd().makePath(out_dir) catch {};
    const path = out_dir ++ "/grow-test.png";
    const app = try App.create(gpa, image, 400, 300, .{ .output_path = path, .clipboard = .none });
    defer app.destroy();
    // Image at 1:1 in (150, 125)..(250, 175). Arrow from inside to 60 px past the right edge.
    _ = try app.handle(.{ .mouse_down = .{ .x = 200, .y = 150 } });
    _ = try app.handle(.{ .mouse_move = .{ .x = 310, .y = 150 } });
    _ = try app.handle(.{ .mouse_up = .{ .x = 310, .y = 150 } });
    _ = try app.render();
    const canvas = app.editor.canvas;
    try std.testing.expectEqual(@as(i32, 0), canvas.x0);
    try std.testing.expectEqual(@as(i32, 0), canvas.y0);
    try std.testing.expectEqual(@as(i32, 50), canvas.y1);
    try std.testing.expect(canvas.x1 >= 160 + core.extent.pad);

    _ = try app.handle(.{ .key = .{ .key = .{ .char = 's' }, .mods = .{ .ctrl = true } } });
    var saved = try core.image_io.load(gpa, path);
    defer saved.deinit(gpa);
    try std.testing.expectEqual(@as(u32, @intCast(canvas.width())), saved.width);
    try std.testing.expectEqual(@as(u32, @intCast(canvas.height())), saved.height);
    // Image pixels unchanged away from the arrow; the extension is white.
    try std.testing.expectEqual(app.image.at(5, 5), saved.at(5, 5));
    try std.testing.expectEqual(app.image.at(50, 10), saved.at(50, 10));
    try std.testing.expectEqual(@as(u32, 0xffffffff), saved.at(@intCast(canvas.x1 - 2), 2));
    try std.testing.expectEqual(@as(u32, 0xffffffff), saved.at(105, 45));
    try std.testing.expectEqual(core.color.palette[0].color.toPixel(), saved.at(130, 25)); // the arrow, past the edge
    // On screen too: white past the image edge, background past the canvas.
    try std.testing.expectEqual(@as(u32, 0xffffffff), app.frame().at(255, 130));
    try std.testing.expectEqual(core.compositor.background.toPixel(), app.frame().at(150 + canvas.x1 + 2, 130));

    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'z' }, .mods = .{ .ctrl = true } } });
    var out = try app.exportImage();
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 100), out.width);
    try std.testing.expectEqual(@as(u32, 50), out.height);
    try std.testing.expect(std.mem.eql(u32, app.image.pixels, out.pixels));
}

test "panning scrolls the scene to the same pixels as a full repaint" {
    const gpa = std.testing.allocator;
    const image = try core.image_io.load(gpa, fixture);
    const app = try App.create(gpa, image, 900, 500, .{ .output_path = null, .clipboard = .none });
    defer app.destroy();
    const key = struct {
        fn ev(c: u21) core.input.Event {
            return .{ .key = .{ .key = .{ .char = c } } };
        }
    }.ev;
    _ = try app.handle(key('-'));
    // Shapes of every kind across the screen, some past the image.
    const kinds = [_]u21{ 'a', 'r', 'h', 'c' };
    for (kinds, 0..) |k, i| {
        _ = try app.handle(key(k));
        const x: f32 = 60 + 200 * @as(f32, @floatFromInt(i));
        _ = try app.handle(.{ .mouse_down = .{ .x = x, .y = 40 } });
        _ = try app.handle(.{ .mouse_move = .{ .x = x + 150, .y = 300 } });
        _ = try app.handle(.{ .mouse_up = .{ .x = x + 150, .y = 300 } });
        if (k == 'c') for ("Note") |ch| {
            _ = try app.handle(key(ch));
        };
        _ = try app.render();
    }
    _ = try app.handle(key('n'));
    _ = try app.handle(.{ .mouse_down = .{ .x = 880, .y = 20 } });
    _ = try app.handle(key('t'));
    _ = try app.handle(.{ .mouse_down = .{ .x = 10, .y = 400 } });
    for ("Text") |ch| _ = try app.handle(key(ch));
    _ = try app.handle(.{ .key = .{ .key = .{ .named = .enter } } });
    _ = try app.render();
    const moves = [_][2]f32{ .{ 450, 250 }, .{ 437, 263 }, .{ 500, 240 }, .{ 500, 241 }, .{ 380, 300 }, .{ 120, 90 } };
    _ = try app.handle(.{ .mouse_down = .{ .x = moves[0][0], .y = moves[0][1], .button = .middle } });
    for (moves[1..]) |m| {
        _ = try app.handle(.{ .mouse_move = .{ .x = m[0], .y = m[1] } });
        _ = try app.render();
        var fresh = core.compositor.Compositor{ .gpa = gpa };
        defer fresh.deinit();
        _ = try fresh.render(app.ctx(), &app.image, &app.doc, &app.editor);
        const d = compare(app.frame(), &fresh.frame.?, null);
        if (d.bad > 0) {
            writeOut(gpa, app.frame(), "pan", "damage.incremental");
            writeOut(gpa, &fresh.frame.?, "pan", "damage.full");
        }
        try std.testing.expectEqual(@as(usize, 0), d.bad);
    }
}

test "docs/keymap.md is up to date" {
    const gpa = std.testing.allocator;
    var buf: [16 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try core.keymap.writeMarkdown(&w);
    const on_disk = std.fs.cwd().readFileAlloc(gpa, "docs/keymap.md", 1 << 20) catch "";
    defer if (on_disk.len > 0) gpa.free(on_disk);
    if (!std.mem.eql(u8, on_disk, w.buffered())) {
        std.debug.print("docs/keymap.md is stale. Run: zig build docs\n", .{});
        return error.StaleKeymapDoc;
    }
}
