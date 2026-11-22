//! Benchmark (`annotate --bench`, `zig build bench`): times decode, startup
//! render, per-frame render while dragging and typing, undo rebuild, export,
//! crop, a drag that grows the canvas, pan and zoom, on a synthetic
//! screenshot or a given image. Budgets: docs/perf.md.
const std = @import("std");
const core = @import("core");
const App = @import("app.zig").App;

const Canvas = core.canvas.Canvas;

pub const Options = struct {
    image_path: ?[]const u8 = null,
    size: [2]u32 = .{ 1920, 1080 },
};

/// Deterministic screenshot-like image: panels, text-like strokes, gradients.
pub fn synthetic(gpa: std.mem.Allocator, w: u32, h: u32) !Canvas {
    var cv = try Canvas.init(gpa, w, h);
    var rng = std.Random.DefaultPrng.init(42);
    const r = rng.random();
    for (0..h) |y| for (0..w) |x| {
        const g: u32 = @intCast(235 + (x * 16 / w) - (y * 8 / h));
        cv.pixels[y * w + x] = 0xff000000 | (g << 16) | (g << 8) | g;
    };
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        const x = r.intRangeLessThan(i32, 0, @intCast(w - 200));
        const y = r.intRangeLessThan(i32, 0, @intCast(h - 20));
        const len = r.intRangeLessThan(i32, 40, 400);
        const c = core.color.Color{ .r = r.int(u8) / 3, .g = r.int(u8) / 3, .b = r.int(u8) / 2 };
        cv.fillRect(core.geom.Rect.fromSize(x, y, len, r.intRangeLessThan(i32, 2, 14)), c);
    }
    return cv;
}

const Stats = struct {
    samples: std.ArrayList(u64) = .empty,

    fn add(s: *Stats, gpa: std.mem.Allocator, ns: u64) !void {
        try s.samples.append(gpa, ns);
    }
    fn deinit(s: *Stats, gpa: std.mem.Allocator) void {
        s.samples.deinit(gpa);
    }
    fn reportMin(s: *Stats, w: *std.Io.Writer, name: []const u8) !void {
        const v = s.samples.items;
        std.mem.sort(u64, v, {}, std.sort.asc(u64));
        try w.print("{s:<26} min {d:>7.3} ms  median {d:>7.3}\n", .{ name, ms(v[0]), ms(v[v.len / 2]) });
    }

    fn report(s: *Stats, w: *std.Io.Writer, name: []const u8) !void {
        const v = s.samples.items;
        std.mem.sort(u64, v, {}, std.sort.asc(u64));
        var sum: u64 = 0;
        for (v) |x| sum += x;
        try w.print("{s:<26} avg {d:>7.3} ms  p50 {d:>7.3}  p95 {d:>7.3}  max {d:>7.3}  (n={d})\n", .{
            name, ms(sum / v.len), ms(v[v.len / 2]), ms(v[v.len * 95 / 100]), ms(v[v.len - 1]), v.len,
        });
    }
};

const startup_runs = 7;

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

pub fn run(gpa: std.mem.Allocator, opts: Options) !void {
    var buf: [4096]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const w = &fw.interface;
    var t = try std.time.Timer.start();

    // Input: encode then decode, so decode time is real.
    const png = if (opts.image_path) |p| try std.fs.cwd().readFileAlloc(gpa, p, 512 << 20) else blk: {
        var syn = try synthetic(gpa, 2560, 1440);
        defer syn.deinit(gpa);
        break :blk try core.image_io.encodePng(gpa, &syn);
    };
    defer gpa.free(png);
    // Startup, repeated: desktop timings are noisy, so report min and median.
    var dec = Stats{};
    defer dec.deinit(gpa);
    var ini = Stats{};
    defer ini.deinit(gpa);
    var first = Stats{};
    defer first.deinit(gpa);
    var total = Stats{};
    defer total.deinit(gpa);
    var app: *App = undefined;
    for (0..startup_runs) |run_i| {
        t.reset();
        const image = try core.image_io.decode(gpa, png);
        const t_decode = t.lap();
        app = try App.create(gpa, image, opts.size[0], opts.size[1], .{ .output_path = null, .clipboard = .none });
        const t_create = t.lap();
        _ = try app.render();
        const t_first = t.lap();
        try dec.add(gpa, t_decode);
        try ini.add(gpa, t_create);
        try first.add(gpa, t_first);
        try total.add(gpa, t_decode + t_create + t_first);
        if (run_i + 1 < startup_runs) app.destroy(); // keep the last one
    }
    defer app.destroy();
    try w.print("image {d}x{d} ({d} KiB PNG), screen {d}x{d}, optimize {s}\n", .{ app.image.width, app.image.height, png.len / 1024, opts.size[0], opts.size[1], @tagName(@import("builtin").mode) });
    try w.print("startup x{d}: min / median (desktop noise is +-30%: compare mins)\n\n", .{startup_runs});
    try dec.reportMin(w, "decode PNG");
    try ini.reportMin(w, "app init (font, view)");
    try first.reportMin(w, "first frame render");
    try total.reportMin(w, "startup total");
    // Reference: stb decode of the same bytes (and a correctness check).
    t.reset();
    var ref = try core.image_io.decodeStb(gpa, png);
    defer ref.deinit(gpa);
    try w.print("{s:<26} {d:>7.3} ms ({s})\n\n", .{ "decode PNG, stb reference", ms(t.read()), if (std.mem.eql(u32, ref.pixels, app.image.pixels)) "same pixels" else "PIXELS DIFFER" });

    const W: f32 = @floatFromInt(opts.size[0]);
    const H: f32 = @floatFromInt(opts.size[1]);

    // Drag an arrow across the screen, one frame per motion event.
    var drag = Stats{};
    defer drag.deinit(gpa);
    var damage_px: u64 = 0;
    // The arrow is the default tool: `a` now would switch it to stairs.
    if (app.editor.tool != .arrow or app.editor.arrow_style != .straight) return error.BenchNotStraightArrow;
    _ = try app.handle(.{ .mouse_down = .{ .x = W * 0.2, .y = H * 0.7 } });
    const n_moves = 300;
    for (0..n_moves) |i| {
        const f = @as(f32, @floatFromInt(i)) / n_moves;
        _ = try app.handle(.{ .mouse_move = .{ .x = W * (0.2 + 0.6 * f), .y = H * (0.7 - 0.5 * f) } });
        t.reset();
        const d = try app.render();
        try drag.add(gpa, t.read());
        damage_px += d.area();
    }
    _ = try app.handle(.{ .mouse_up = .{ .x = W * 0.8, .y = H * 0.2 } });
    t.reset();
    _ = try app.render();
    const t_commit = t.read();
    try drag.report(w, "frame: drag arrow");
    try w.print("{s:<26} avg {d} px/frame ({d:.1}% of screen)\n", .{ "  damage", damage_px / n_moves, @as(f64, @floatFromInt(damage_px / n_moves)) * 100 / (W * H) });

    // Drag a stairs arrow the same way (`a` again: stairs), then cancel it
    // and switch back to straight.
    var drag_st = Stats{};
    defer drag_st.deinit(gpa);
    damage_px = 0;
    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'a' } } });
    if (app.editor.arrow_style != .stairs) return error.BenchNoStairsStyle;
    _ = try app.handle(.{ .mouse_down = .{ .x = W * 0.2, .y = H * 0.7 } });
    for (0..n_moves) |i| {
        const f = @as(f32, @floatFromInt(i)) / n_moves;
        _ = try app.handle(.{ .mouse_move = .{ .x = W * (0.2 + 0.6 * f), .y = H * (0.7 - 0.5 * f) } });
        t.reset();
        const d = try app.render();
        try drag_st.add(gpa, t.read());
        damage_px += d.area();
    }
    _ = try app.handle(.{ .key = .{ .key = .{ .named = .escape } } });
    _ = try app.handle(.{ .mouse_up = .{ .x = W * 0.8, .y = H * 0.2 } });
    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'a' } } });
    _ = try app.render();
    try drag_st.report(w, "frame: drag stairs arrow");
    try w.print("{s:<26} avg {d} px/frame ({d:.1}% of screen)\n", .{ "  damage", damage_px / n_moves, @as(f64, @floatFromInt(damage_px / n_moves)) * 100 / (W * H) });

    // Drag a big pixelate region (the most expensive preview).
    var pix = Stats{};
    defer pix.deinit(gpa);
    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'p' } } });
    _ = try app.handle(.{ .mouse_down = .{ .x = W * 0.1, .y = H * 0.1 } });
    for (0..100) |i| {
        const f = @as(f32, @floatFromInt(i)) / 100;
        _ = try app.handle(.{ .mouse_move = .{ .x = W * (0.2 + 0.5 * f), .y = H * (0.2 + 0.5 * f) } });
        t.reset();
        _ = try app.render();
        try pix.add(gpa, t.read());
    }
    _ = try app.handle(.{ .key = .{ .key = .{ .named = .escape } } });
    try pix.report(w, "frame: drag pixelate");

    // Type text.
    var typing = Stats{};
    defer typing.deinit(gpa);
    _ = try app.handle(.{ .key = .{ .key = .{ .char = 't' } } });
    _ = try app.handle(.{ .mouse_down = .{ .x = W * 0.3, .y = H * 0.3 } });
    for ("The quick brown fox jumps over the lazy dog") |ch| {
        _ = try app.handle(.{ .key = .{ .key = .{ .char = ch } } });
        t.reset();
        _ = try app.render();
        try typing.add(gpa, t.read());
    }
    _ = try app.handle(.{ .key = .{ .key = .{ .named = .enter } } });
    _ = try app.render();
    try typing.report(w, "frame: type a character");
    try w.print("{s:<26} {d:>7.3} ms\n", .{ "frame: commit arrow", ms(t_commit) });

    // Many annotations, then undo = full scene rebuild.
    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'n' } } });
    for (0..30) |i| {
        const f = @as(f32, @floatFromInt(i)) / 30;
        _ = try app.handle(.{ .mouse_down = .{ .x = W * (0.1 + 0.8 * f), .y = H * 0.5 } });
    }
    _ = try app.render();
    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'z' }, .mods = .{ .ctrl = true } } });
    t.reset();
    _ = try app.render();
    try w.print("{s:<26} {d:>7.3} ms ({d} annotations)\n", .{ "frame: undo (rebuild)", ms(t.read()), app.doc.items.items.len });

    // Move tool: drag the first arrow by its shaft among 31 annotations.
    // Each frame repaints the old and new arrow bounds of the scene.
    var mv = Stats{};
    defer mv.deinit(gpa);
    var mv_ev = Stats{};
    defer mv_ev.deinit(gpa);
    damage_px = 0;
    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'm' } } });
    _ = try app.handle(.{ .mouse_down = .{ .x = W * 0.35, .y = H * 0.575 } });
    if (app.editor.mode != .moving) return error.BenchMoveMissedTheArrow;
    for (0..n_moves) |i| {
        const f = @as(f32, @floatFromInt(i + 1)) / n_moves;
        t.reset();
        _ = try app.handle(.{ .mouse_move = .{ .x = W * (0.35 + 0.1 * f), .y = H * (0.575 + 0.1 * f) } });
        try mv_ev.add(gpa, t.lap());
        const d = try app.render();
        try mv.add(gpa, t.read());
        damage_px += d.area();
    }
    _ = try app.handle(.{ .mouse_up = .{ .x = W * 0.45, .y = H * 0.675 } });
    _ = try app.render();
    try mv.report(w, "frame: move drag (arrow)");
    try mv_ev.report(w, "  event (hit, canvas)");
    try w.print("{s:<26} avg {d} px/frame ({d:.1}% of screen)\n", .{ "  damage", damage_px / n_moves, @as(f64, @floatFromInt(damage_px / n_moves)) * 100 / (W * H) });

    // Move tool: drag a long stairs arrow by its middle segment among 32
    // annotations. The repaint covers its segments and corners only.
    var mvs = Stats{};
    defer mvs.deinit(gpa);
    damage_px = 0;
    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'a' } } });
    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'a' } } }); // again: stairs
    if (app.editor.arrow_style != .stairs) return error.BenchNoStairsStyle;
    _ = try app.handle(.{ .mouse_down = .{ .x = W * 0.15, .y = H * 0.2 } });
    _ = try app.handle(.{ .mouse_move = .{ .x = W * 0.75, .y = H * 0.4 } });
    _ = try app.handle(.{ .mouse_up = .{ .x = W * 0.75, .y = H * 0.4 } });
    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'm' } } });
    _ = try app.render();
    _ = try app.handle(.{ .mouse_down = .{ .x = W * 0.45, .y = H * 0.3 } });
    if (app.editor.mode != .moving) return error.BenchMoveMissedTheStairsArrow;
    for (0..n_moves) |i| {
        const f = @as(f32, @floatFromInt(i + 1)) / n_moves;
        _ = try app.handle(.{ .mouse_move = .{ .x = W * (0.45 + 0.1 * f), .y = H * (0.3 + 0.1 * f) } });
        t.reset();
        const d = try app.render();
        try mvs.add(gpa, t.read());
        damage_px += d.area();
    }
    _ = try app.handle(.{ .mouse_up = .{ .x = W * 0.55, .y = H * 0.4 } });
    _ = try app.render();
    try mvs.report(w, "frame: move drag (stairs)");
    try w.print("{s:<26} avg {d} px/frame ({d:.1}% of screen)\n", .{ "  damage", damage_px / n_moves, @as(f64, @floatFromInt(damage_px / n_moves)) * 100 / (W * H) });
    // Take the stairs arrow back (the move, then the add): the cases below
    // keep the scene they had before it.
    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'z' }, .mods = .{ .ctrl = true } } });
    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'z' }, .mods = .{ .ctrl = true } } });
    // Straight arrows again, the move tool active again.
    for ("aam") |ch| _ = try app.handle(.{ .key = .{ .key = .{ .char = ch } } });
    if (app.editor.arrow_style != .straight or app.editor.tool != .move) return error.BenchStateNotRestored;
    _ = try app.render();

    // Export.
    t.reset();
    var out = try app.exportImage();
    defer out.deinit(gpa);
    const t_export = t.lap();
    const out_png = try core.image_io.encodePng(gpa, &out);
    defer gpa.free(out_png);
    const t_encode = t.lap();
    try w.print("{s:<26} {d:>7.3} ms\n", .{ "export render", ms(t_export) });
    try w.print("{s:<26} {d:>7.3} ms ({d} KiB)\n", .{ "export PNG encode", ms(t_encode), out_png.len / 1024 });
    const stb_png = try core.image_io.encodePngStb(gpa, &out);
    defer gpa.free(stb_png);
    try w.print("{s:<26} {d:>7.3} ms ({d} KiB)\n", .{ "export PNG encode, stb ref", ms(t.lap()), stb_png.len / 1024 });

    // Crop: drag (dimmed outside), then release = refit + scene rebuild.
    var crop = Stats{};
    defer crop.deinit(gpa);
    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'x' } } });
    _ = try app.handle(.{ .mouse_down = .{ .x = W * 0.1, .y = H * 0.1 } });
    _ = try app.render();
    for (0..100) |i| {
        const f = @as(f32, @floatFromInt(i)) / 100;
        _ = try app.handle(.{ .mouse_move = .{ .x = W * (0.3 + 0.5 * f), .y = H * (0.3 + 0.5 * f) } });
        t.reset();
        _ = try app.render();
        try crop.add(gpa, t.read());
    }
    try crop.report(w, "frame: drag crop");
    _ = try app.handle(.{ .mouse_up = .{ .x = W * 0.8, .y = H * 0.8 } });
    t.reset();
    _ = try app.render();
    try w.print("{s:<26} {d:>7.3} ms ({d}x{d} image px kept)\n", .{ "frame: crop (refit)", ms(t.read()), app.editor.canvas.width(), app.editor.canvas.height() });

    // Zoom out (room around the image), then drag an arrow from the image
    // out past its edge: the canvas grows white, live.
    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'a' } } });
    if (app.editor.arrow_style != .straight or app.editor.tool != .arrow) return error.BenchNotStraightArrow;
    _ = try app.handle(.{ .key = .{ .key = .{ .char = '-' } } });
    t.reset();
    _ = try app.render();
    try w.print("{s:<26} {d:>7.3} ms (scale {d:.3})\n", .{ "frame: zoom out (key -)", ms(t.read()), app.editor.view.xf.scale });
    var grow = Stats{};
    defer grow.deinit(gpa);
    damage_px = 0;
    _ = try app.handle(.{ .mouse_down = .{ .x = W * 0.5, .y = H * 0.5 } });
    for (0..n_moves) |i| {
        const f = @as(f32, @floatFromInt(i)) / n_moves;
        _ = try app.handle(.{ .mouse_move = .{ .x = W * (0.5 + 0.48 * f), .y = H * (0.5 + 0.3 * f) } });
        t.reset();
        const d = try app.render();
        try grow.add(gpa, t.read());
        damage_px += d.area();
    }
    _ = try app.handle(.{ .mouse_up = .{ .x = W * 0.98, .y = H * 0.8 } });
    t.reset();
    _ = try app.render();
    const t_grow_commit = t.read();
    try grow.report(w, "frame: drag, grow canvas");
    try w.print("{s:<26} avg {d} px/frame ({d:.1}% of screen); commit {d:.3} ms, canvas {d}x{d}\n", .{ "  damage", damage_px / n_moves, @as(f64, @floatFromInt(damage_px / n_moves)) * 100 / (W * H), ms(t_grow_commit), app.editor.canvas.width(), app.editor.canvas.height() });

    // Pan with the middle button, one frame per motion event.
    var pan = Stats{};
    defer pan.deinit(gpa);
    _ = try app.handle(.{ .mouse_down = .{ .x = W * 0.5, .y = H * 0.5, .button = .middle } });
    for (0..100) |i| {
        const f = @as(f32, @floatFromInt(i + 1)) / 100;
        _ = try app.handle(.{ .mouse_move = .{ .x = W * (0.5 - 0.1 * f), .y = H * (0.5 - 0.05 * f) } });
        t.reset();
        _ = try app.render();
        try pan.add(gpa, t.read());
    }
    _ = try app.handle(.{ .mouse_up = .{ .x = W * 0.4, .y = H * 0.45, .button = .middle } });
    try pan.report(w, "frame: pan (middle drag)");

    // Ctrl+wheel zoom about the pointer, in and out.
    var zoom = Stats{};
    defer zoom.deinit(gpa);
    for (0..6) |i| {
        const up: i32 = if (i % 2 == 0) 1 else -1;
        _ = try app.handle(.{ .wheel = .{ .delta = up, .x = W * 0.3, .y = H * 0.3, .mods = .{ .ctrl = true } } });
        t.reset();
        _ = try app.render();
        try zoom.add(gpa, t.read());
    }
    try zoom.report(w, "frame: Ctrl+wheel zoom");
    try w.flush();
}
