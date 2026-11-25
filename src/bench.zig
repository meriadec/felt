//! Benchmark (`felt --bench`, `zig build bench`): times decode, startup
//! render, per-frame render while dragging (arrows, a stairs callout) and
//! typing, move drags (arrows, a callout box), auto-routing among stairs
//! paths (drag, move, commits that re-route), undo rebuild, export, crop,
//! a drag that grows the canvas, the canvas background switch, pan and
//! zoom, on a synthetic screenshot or a given image; the config file read
//! and write (in a temp dir, never the user's). Budgets: docs/perf.md.
const std = @import("std");
const core = @import("core");
const App = @import("app.zig").App;
const config = @import("config.zig");

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

/// Per-frame split of the render time (compositor.Prof over `n` frames).
fn reportProf(w: *std.Io.Writer, p: core.compositor.Prof, n: u64) !void {
    const f: f64 = @floatFromInt(n);
    try w.print("{s:<26} scene {d:.3} ms, frame {d:.3} ms (chrome {d:.3}); rects: scene {d:.1}, damage {d:.1}\n", .{
        "  split (avg)",
        ms(p.scene_ns) / f,
        ms(p.frame_ns) / f,
        ms(p.chrome_ns) / f,
        @as(f64, @floatFromInt(p.fix_rects)) / f,
        @as(f64, @floatFromInt(p.dmg_rects)) / f,
    });
}

/// Auto-routing (route.zig) among dense paths: a fan of stairs arrows
/// across the row of numbers (each commit re-routes the ones around it),
/// a stairs arrow dragged through them (routed each frame) and committed,
/// one of the fan moved by its body (routed each frame). Undoes it all:
/// the cases after it see the scene they had (31 annotations, the move
/// tool, straight arrows).
fn benchRouting(gpa: std.mem.Allocator, w: *std.Io.Writer, app: *App, opts: Options) !void {
    const W: f32 = @floatFromInt(opts.size[0]);
    const H: f32 = @floatFromInt(opts.size[1]);
    var t = try std.time.Timer.start();
    const doc = &app.doc;
    app.editor.tool = .callout; // stairs pointers: a drag, then Enter (no text: an arrow)
    app.editor.arrow_style = .stairs;
    if (app.editor.arrow_style != .stairs or app.editor.tool != .callout) return error.BenchNoStairsStyle;
    const n_fan = 8;
    var fan = Stats{};
    defer fan.deinit(gpa);
    const h0 = doc.history.items.len;
    for (0..n_fan) |k| {
        const kf: f32 = @floatFromInt(k);
        _ = try app.handle(.{ .mouse_down = .{ .x = W * 0.1, .y = H * (0.3 + 0.03 * kf) } });
        _ = try app.handle(.{ .mouse_move = .{ .x = W * (0.55 + 0.03 * kf), .y = H * (0.6 + 0.03 * kf) } });
        _ = try app.render();
        t.reset();
        _ = try app.handle(.{ .mouse_up = .{ .x = W * (0.55 + 0.03 * kf), .y = H * (0.6 + 0.03 * kf) } });
        _ = try app.handle(.{ .key = .{ .key = .{ .named = .enter } } }); // no text: the callout becomes an arrow
        _ = try app.render();
        try fan.add(gpa, t.read());
    }
    if (doc.items.items.len != 31 + n_fan) return error.BenchFanMissing;
    try fan.report(w, "commit stairs, re-route");
    try w.print("{s:<26} {d} re-routes in {d} commits\n", .{ "  chained", doc.history.items.len - h0 - n_fan, n_fan });

    var drag = Stats{};
    defer drag.deinit(gpa);
    _ = try app.handle(.{ .mouse_down = .{ .x = W * 0.12, .y = H * 0.28 } });
    for (0..n_moves) |i| {
        const f = @as(f32, @floatFromInt(i + 1)) / n_moves;
        _ = try app.handle(.{ .mouse_move = .{ .x = W * (0.3 + 0.4 * f), .y = H * (0.5 + 0.3 * f) } });
        t.reset();
        _ = try app.render();
        try drag.add(gpa, t.read());
    }
    try drag.report(w, "frame: drag stairs, routed");
    const h1 = doc.history.items.len;
    t.reset();
    _ = try app.handle(.{ .mouse_up = .{ .x = W * 0.7, .y = H * 0.8 } });
    _ = try app.handle(.{ .key = .{ .key = .{ .named = .enter } } }); // no text: the callout becomes an arrow
    const t_settle = t.lap();
    _ = try app.render();
    try w.print("{s:<26} {d:>7.3} ms (event {d:.3} ms: route, settle; {d} re-routed, {d} annotations)\n", .{ "  commit", ms(t_settle + t.read()), ms(t_settle), doc.history.items.len - h1 - 1, doc.items.items.len });

    // Move fan arrow 3 by its first segment.
    var mv = Stats{};
    defer mv.deinit(gpa);
    var ev = Stats{};
    defer ev.deinit(gpa);
    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'm' } } });
    _ = try app.render();
    _ = try app.handle(.{ .mouse_down = .{ .x = W * 0.13, .y = H * 0.39 } });
    if (app.editor.mode != .moving or app.editor.mode.moving.grab.part != .whole or app.editor.mode.moving.grab.index != 31 + 3) return error.BenchMoveMissedTheFanArrow;
    app.comp.prof = .{};
    for (0..n_moves) |i| {
        const f = @as(f32, @floatFromInt(i + 1)) / n_moves;
        t.reset();
        _ = try app.handle(.{ .mouse_move = .{ .x = W * (0.13 + 0.1 * f), .y = H * (0.39 + 0.05 * f) } });
        try ev.add(gpa, t.lap());
        _ = try app.render();
        try mv.add(gpa, t.read());
    }
    try mv.report(w, "frame: move stairs, routed");
    try ev.report(w, "  event (route, hit)");
    try reportProf(w, app.comp.prof, n_moves);
    const h2 = doc.history.items.len;
    t.reset();
    _ = try app.handle(.{ .mouse_up = .{ .x = W * 0.23, .y = H * 0.44 } });
    const t_settle2 = t.lap();
    _ = try app.render();
    try w.print("{s:<26} {d:>7.3} ms (event {d:.3} ms: settle; {d} re-routed)\n", .{ "  commit", ms(t_settle2 + t.read()), ms(t_settle2), doc.history.items.len - h2 - 1 });

    // Undo the move, the routed arrow and the fan.
    for (0..n_fan + 2) |_| _ = try app.handle(.{ .key = .{ .key = .{ .char = 'z' }, .mods = .{ .ctrl = true } } });
    for ("aam") |ch| _ = try app.handle(.{ .key = .{ .key = .{ .char = ch } } });
    if (app.editor.arrow_style != .straight or app.editor.tool != .move or doc.items.items.len != 31) return error.BenchStateNotRestored;
    _ = try app.render();
    try w.print("\n", .{});
}

/// The config file: read (startup, window mode) and atomic write (a
/// switch), in a temp dir: the bench never touches the user's config.
fn benchConfig(gpa: std.mem.Allocator, w: *std.Io.Writer) !void {
    const base = std.posix.getenv("TMPDIR") orelse "/tmp";
    const dir = try std.fmt.allocPrint(gpa, "{s}/felt-bench-{d}", .{ base, std.os.linux.getpid() });
    defer gpa.free(dir);
    defer std.fs.cwd().deleteTree(dir) catch {};
    const p = try std.fs.path.join(gpa, &.{ dir, "felt", "config" });
    defer gpa.free(p);
    var rd = Stats{};
    defer rd.deinit(gpa);
    var wr = Stats{};
    defer wr.deinit(gpa);
    var t = try std.time.Timer.start();
    for (0..startup_runs) |i| {
        t.reset();
        try config.save(p, .{ .canvas_bg = if (i % 2 == 0) .dark else .light });
        try wr.add(gpa, t.lap());
        if (config.load(p).canvas_bg != (if (i % 2 == 0) core.settings.CanvasBg.dark else .light)) return error.BenchConfigMismatch;
        try rd.add(gpa, t.read());
    }
    try rd.reportMin(w, "config read (startup)");
    try wr.reportMin(w, "config write (atomic)");
}

const n_moves = 300;

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

pub fn run(gpa: std.mem.Allocator, opts: Options) !void {
    var buf: [4096]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const w = &fw.interface;
    // A failed case still shows the cases before it.
    errdefer w.flush() catch {};
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
    try w.print("{s:<26} {d:>7.3} ms ({s})\n", .{ "decode PNG, stb reference", ms(t.read()), if (std.mem.eql(u32, ref.pixels, app.image.pixels)) "same pixels" else "PIXELS DIFFER" });
    try benchConfig(gpa, w);
    try w.print("\n", .{});

    const W: f32 = @floatFromInt(opts.size[0]);
    const H: f32 = @floatFromInt(opts.size[1]);

    // Drag an arrow across the screen, one frame per motion event.
    var drag = Stats{};
    defer drag.deinit(gpa);
    var damage_px: u64 = 0;
    // Straight arrows, set here (not the startup defaults): each case below
    // goes on from the tool and style the case before it left.
    app.editor.tool = .callout;
    app.editor.arrow_style = .straight;
    _ = try app.render();
    _ = try app.handle(.{ .mouse_down = .{ .x = W * 0.2, .y = H * 0.7 } });
    for (0..n_moves) |i| {
        const f = @as(f32, @floatFromInt(i)) / n_moves;
        _ = try app.handle(.{ .mouse_move = .{ .x = W * (0.2 + 0.6 * f), .y = H * (0.7 - 0.5 * f) } });
        t.reset();
        const d = try app.render();
        try drag.add(gpa, t.read());
        damage_px += d.area();
    }
    _ = try app.handle(.{ .mouse_up = .{ .x = W * 0.8, .y = H * 0.2 } });
    _ = try app.handle(.{ .key = .{ .key = .{ .named = .enter } } }); // no text: the callout becomes an arrow
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
    app.comp.prof = .{};
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
    try reportProf(w, app.comp.prof, n_moves + 1);
    try w.print("{s:<26} avg {d} px/frame ({d:.1}% of screen)\n", .{ "  damage", damage_px / n_moves, @as(f64, @floatFromInt(damage_px / n_moves)) * 100 / (W * H) });

    // Move tool: drag a long stairs arrow by its first segment among 32
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
    _ = try app.handle(.{ .key = .{ .key = .{ .named = .enter } } }); // no text: the callout becomes an arrow
    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'm' } } });
    _ = try app.render();
    _ = try app.handle(.{ .mouse_down = .{ .x = W * 0.25, .y = H * 0.2 } });
    if (app.editor.mode != .moving or app.editor.mode.moving.grab.part != .whole) return error.BenchMoveMissedTheStairsArrow;
    app.comp.prof = .{};
    for (0..n_moves) |i| {
        const f = @as(f32, @floatFromInt(i + 1)) / n_moves;
        _ = try app.handle(.{ .mouse_move = .{ .x = W * (0.25 + 0.1 * f), .y = H * (0.2 + 0.1 * f) } });
        t.reset();
        const d = try app.render();
        try mvs.add(gpa, t.read());
        damage_px += d.area();
    }
    _ = try app.handle(.{ .mouse_up = .{ .x = W * 0.35, .y = H * 0.3 } });
    _ = try app.render();
    try mvs.report(w, "frame: move drag (stairs)");
    try reportProf(w, app.comp.prof, n_moves + 1);
    try w.print("{s:<26} avg {d} px/frame ({d:.1}% of screen)\n", .{ "  damage", damage_px / n_moves, @as(f64, @floatFromInt(damage_px / n_moves)) * 100 / (W * H) });
    // Take the stairs arrow back (the move, then the add): the cases below
    // keep the scene they had before it.
    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'z' }, .mods = .{ .ctrl = true } } });
    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'z' }, .mods = .{ .ctrl = true } } });
    // Straight arrows again, the move tool active again.
    for ("aam") |ch| _ = try app.handle(.{ .key = .{ .key = .{ .char = ch } } });
    if (app.editor.arrow_style != .straight or app.editor.tool != .move) return error.BenchStateNotRestored;
    _ = try app.render();

    // A stairs callout: drag from the box to the target (the preview), then
    // move its box among 32 annotations (the elbow re-routes each frame).
    var dcs = Stats{};
    defer dcs.deinit(gpa);
    damage_px = 0;
    for ("cc") |ch| _ = try app.handle(.{ .key = .{ .key = .{ .char = ch } } }); // again: stairs
    if (app.editor.arrow_style != .stairs or app.editor.tool != .callout) return error.BenchNoStairsCallout;
    const tip_at = core.geom.Vec2.init(W * 0.15, H * 0.25);
    const box_at = core.geom.Vec2.init(W * 0.6, H * 0.4);
    _ = try app.handle(.{ .mouse_down = .{ .x = box_at.x, .y = box_at.y } });
    for (0..n_moves) |i| {
        const f = @as(f32, @floatFromInt(i + 1)) / n_moves;
        _ = try app.handle(.{ .mouse_move = .{ .x = box_at.x + (tip_at.x - box_at.x) * f, .y = box_at.y + (tip_at.y - box_at.y) * f } });
        t.reset();
        const d = try app.render();
        try dcs.add(gpa, t.read());
        damage_px += d.area();
    }
    _ = try app.handle(.{ .mouse_up = .{ .x = tip_at.x, .y = tip_at.y } });
    for ("Stairs callout") |ch| _ = try app.handle(.{ .key = .{ .key = .{ .char = ch } } });
    _ = try app.handle(.{ .key = .{ .key = .{ .named = .enter } } });
    try dcs.report(w, "frame: drag stairs callout");
    try w.print("{s:<26} avg {d} px/frame ({d:.1}% of screen)\n", .{ "  damage", damage_px / n_moves, @as(f64, @floatFromInt(damage_px / n_moves)) * 100 / (W * H) });
    var mvc = Stats{};
    defer mvc.deinit(gpa);
    damage_px = 0;
    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'm' } } });
    _ = try app.render();
    // The box starts at the anchor and runs right (the target is left).
    const ui = core.style.uiScale(opts.size[1]);
    _ = try app.handle(.{ .mouse_down = .{ .x = box_at.x + 30 * ui, .y = box_at.y } });
    if (app.editor.mode != .moving or app.editor.mode.moving.grab.part != .whole) return error.BenchMoveMissedTheCalloutBox;
    app.comp.prof = .{};
    for (0..n_moves) |i| {
        const f = @as(f32, @floatFromInt(i + 1)) / n_moves;
        _ = try app.handle(.{ .mouse_move = .{ .x = box_at.x + 30 * ui + W * 0.1 * f, .y = box_at.y + H * 0.1 * f } });
        t.reset();
        const d = try app.render();
        try mvc.add(gpa, t.read());
        damage_px += d.area();
    }
    _ = try app.handle(.{ .mouse_up = .{ .x = box_at.x + 30 * ui + W * 0.1, .y = box_at.y + H * 0.1 } });
    _ = try app.render();
    try mvc.report(w, "frame: move callout box");
    try reportProf(w, app.comp.prof, n_moves + 1);
    try w.print("{s:<26} avg {d} px/frame ({d:.1}% of screen)\n", .{ "  damage", damage_px / n_moves, @as(f64, @floatFromInt(damage_px / n_moves)) * 100 / (W * H) });
    // Take the callout back (the move, then the add), straight style and
    // the move tool again: the cases below see the scene they had.
    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'z' }, .mods = .{ .ctrl = true } } });
    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'z' }, .mods = .{ .ctrl = true } } });
    for ("ccm") |ch| _ = try app.handle(.{ .key = .{ .key = .{ .char = ch } } });
    if (app.editor.arrow_style != .straight or app.editor.tool != .move or app.doc.items.items.len != 31) return error.BenchStateNotRestored;
    _ = try app.render();
    try benchRouting(gpa, w, app, opts);

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
    if (app.editor.arrow_style != .straight or app.editor.tool != .callout) return error.BenchNotStraightArrow;
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
    _ = try app.handle(.{ .key = .{ .key = .{ .named = .enter } } }); // no text: the callout becomes an arrow
    t.reset();
    _ = try app.render();
    const t_grow_commit = t.read();
    try grow.report(w, "frame: drag, grow canvas");
    try w.print("{s:<26} avg {d} px/frame ({d:.1}% of screen); commit {d:.3} ms, canvas {d}x{d}\n", .{ "  damage", damage_px / n_moves, @as(f64, @floatFromInt(damage_px / n_moves)) * 100 / (W * H), ms(t_grow_commit), app.editor.canvas.width(), app.editor.canvas.height() });

    // Canvas background switch (`b`) over the grown canvas, both ways: it
    // repaints only the canvas around the image (and the toast).
    var bg = Stats{};
    defer bg.deinit(gpa);
    damage_px = 0;
    app.comp.prof = .{};
    const n_bg = 20;
    for (0..n_bg) |_| {
        t.reset();
        _ = try app.handle(.{ .key = .{ .key = .{ .char = 'b' } } });
        const d = try app.render();
        try bg.add(gpa, t.read());
        damage_px += d.area();
    }
    if (app.editor.settings.canvas_bg != .light) return error.BenchCanvasNotLight;
    try bg.report(w, "frame: canvas bg switch");
    try reportProf(w, app.comp.prof, n_bg);
    try w.print("{s:<26} avg {d} px/frame ({d:.1}% of screen)\n", .{ "  damage", damage_px / n_bg, @as(f64, @floatFromInt(damage_px / n_bg)) * 100 / (W * H) });

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

    // Canvas padding steps (`.` up the list, `,` back down): every clip and
    // the view change, so the whole scene repaints and the view refits.
    var padding = Stats{};
    defer padding.deinit(gpa);
    for (0..3) |_| for ([_]u8{ '.', '.', '.', '.', ',', ',', ',', ',' }) |k| {
        _ = try app.handle(.{ .key = .{ .key = .{ .char = k } } });
        t.reset();
        _ = try app.render();
        try padding.add(gpa, t.read());
    };
    if (app.editor.settings.padding != 0) return error.BenchPaddingNotZero;
    try padding.report(w, "frame: padding step");
    try benchMontage(gpa, w, opts);
    try benchBrowser(gpa, w, opts);
    try benchCapture(gpa, w, opts);
    try w.flush();
}

/// A scene of 4 images (each W/2 x H/2, placed by the magnet: right, bottom,
/// left) on its own App: the first frame (shadows, 4 blits), then the drop-slot
/// overlay with the pointer moving across the slots (one frame per move).
fn benchMontage(gpa: std.mem.Allocator, w: *std.Io.Writer, opts: Options) !void {
    const W = opts.size[0];
    const H = opts.size[1];
    const iw: u32 = W / 2;
    const ih: u32 = H / 2;
    var extra = try synthetic(gpa, iw, ih);
    defer extra.deinit(gpa);
    const app = try App.create(gpa, try synthetic(gpa, iw, ih), W, H, .{ .output_path = null });
    defer app.destroy();
    _ = try app.render();
    var t = try std.time.Timer.start();
    var rect = core.geom.Rect.fromSize(0, 0, @intCast(iw), @intCast(ih));
    for ([_]core.magnet.Side{ .right, .bottom, .left }) |side| {
        rect = core.magnet.slotRect(rect, side, @intCast(iw), @intCast(ih));
        _ = try app.doc.addImage(gpa, iw, ih, rect.x0, rect.y0, &extra, false);
    }
    _ = app.editor.syncView();
    t.reset();
    _ = try app.render();
    try w.print("{s:<26} {d:.3} ms\n", .{ "frame: 4 images placed", ms(t.read()) });
    // Zoom out: the slots lie around the canvas, which fits the screen.
    for (0..3) |_| _ = try app.handle(.{ .key = .{ .key = .{ .char = '-' } } });
    _ = try app.render();
    var st = Stats{};
    defer st.deinit(gpa);
    const n_drop = 60;
    for (0..n_drop) |i| {
        const f = @as(f32, @floatFromInt(i)) / n_drop;
        app.editor.setMontageDrop(@intCast(iw / 2), @intCast(ih / 2), core.geom.Vec2.init(@as(f32, @floatFromInt(W)) * f, @as(f32, @floatFromInt(H)) * (1 - f)));
        t.reset();
        const d = try app.render();
        // A move inside a slot damages nothing; time the frames that repaint.
        if (d.len > 0) try st.add(gpa, t.read());
    }
    try st.report(w, "frame: drop slot changes");
    app.editor.clearMontageDrop();
    _ = try app.render();
    // A real image drag (move tool): the ghost follows the pointer; frames that repaint.
    app.editor.tool = .move;
    const im = app.doc.scene.images.items[1].rect().toBounds();
    const p0 = app.editor.view.toScreen(core.geom.Vec2.init((im.min.x + im.max.x) / 2, (im.min.y + im.max.y) / 2));
    _ = try app.handle(.{ .mouse_down = .{ .x = p0.x, .y = p0.y } });
    var gt = Stats{};
    defer gt.deinit(gpa);
    for (0..n_drop) |i| {
        const f = @as(f32, @floatFromInt(i)) / n_drop;
        _ = try app.handle(.{ .mouse_move = .{ .x = p0.x - 300 * f, .y = p0.y + 200 * f } });
        t.reset();
        const d = try app.render();
        if (d.len > 0) try gt.add(gpa, t.read());
    }
    try gt.report(w, "frame: image drag (ghost)");
    _ = try app.handle(.{ .key = .{ .key = .{ .named = .escape } } });
    _ = try app.render();
}

/// The file browser on a folder of 40 images (1280x720 PNGs, made in a temp
/// folder), run without a thread (every job is done at once): the first
/// thumbnail (decode + downscale), the panel's first frame, a full pass of
/// scrolling with every thumbnail ready (frames that repaint the panel), and
/// hover frames.
fn benchBrowser(gpa: std.mem.Allocator, w: *std.Io.Writer, opts: Options) !void {
    const W = opts.size[0];
    const H = opts.size[1];
    var dir_name: [64]u8 = undefined;
    const rel = try std.fmt.bufPrint(&dir_name, "felt-bench-browser-{d}", .{std.time.milliTimestamp()});
    var tmp = try std.fs.cwd().makeOpenPath("test-out", .{});
    defer tmp.close();
    try tmp.makePath(rel);
    defer tmp.deleteTree(rel) catch {};
    const dir = try tmp.realpathAlloc(gpa, rel);
    defer gpa.free(dir);
    var img = try synthetic(gpa, 1280, 720);
    defer img.deinit(gpa);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    for (0..40) |i| {
        const p = try std.fmt.bufPrint(&path_buf, "{s}/img{d:0>2}.png", .{ dir, i });
        try core.image_io.savePng(gpa, &img, p);
    }
    var t = try std.time.Timer.start();
    var th = try core.thumbs.make(gpa, try std.fmt.bufPrint(&path_buf, "{s}/img00.png", .{dir}), 192, 112);
    th.canvas.deinit(gpa);
    try w.print("{s:<26} {d:.3} ms\n", .{ "thumbnail (decode, scale)", ms(t.read()) });

    const app = try App.create(gpa, try synthetic(gpa, W / 2, H / 2), W, H, .{ .output_path = null });
    defer app.destroy();
    _ = try app.render();
    try app.editor.browser.setHome(dir);
    t.reset();
    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'o' } } }); // lists, thumbnails of the rows that show
    try w.print("{s:<26} {d:.3} ms\n", .{ "open (list + visible thumbs)", ms(t.read()) });
    t.reset();
    const d0 = try app.render();
    try w.print("{s:<26} {d:.3} ms ({d} rects)\n", .{ "frame: panel first paint", ms(t.read()), d0.len });
    // A pass over the list loads every thumbnail; then time the scrolling.
    const b = &app.editor.browser;
    const step = b.geo().row_h * 0.5;
    while (b.scrollBy(step * 4)) {}
    while (b.scrollBy(-step * 4)) {}
    _ = try app.render();
    var st = Stats{};
    defer st.deinit(gpa);
    while (b.scrollBy(step)) {
        t.reset();
        const d = try app.render();
        if (d.len > 0) try st.add(gpa, t.read());
    }
    try st.report(w, "frame: panel scroll");
    var hv = Stats{};
    defer hv.deinit(gpa);
    const g = b.geo();
    for (0..30) |i| {
        const y = g.list.min.y + (@as(f32, @floatFromInt(i)) + 0.5) * g.row_h * 0.5;
        _ = try app.handle(.{ .mouse_move = .{ .x = g.list.min.x + 40, .y = y } });
        t.reset();
        const d = try app.render();
        if (d.len > 0) try hv.add(gpa, t.read());
    }
    try hv.report(w, "frame: row hover");
    _ = try app.handle(.{ .key = .{ .key = .{ .char = 'o' } } });
    _ = try app.render();
}

/// The capture picker on a frozen screen of the screen size: first frame, a
/// drag from 20% to 80% of the screen (one frame per motion event), the crop.
fn benchCapture(gpa: std.mem.Allocator, w: *std.Io.Writer, opts: Options) !void {
    const W = opts.size[0];
    const H = opts.size[1];
    var frozen = try synthetic(gpa, W, H);
    defer frozen.deinit(gpa);
    var frame = try Canvas.init(gpa, W, H);
    defer frame.deinit(gpa);
    var font = try core.font.Font.init(gpa, core.font_ttf);
    defer font.deinit();
    const ctx = core.draw.Ctx{ .gpa = gpa, .font = &font };
    var picker = core.picker.Picker.init(W, H, &.{}, 0);
    var scene = core.picker_draw.Scene{};
    var t = try std.time.Timer.start();
    _ = try scene.render(ctx, &picker, &frozen, &frame);
    try w.print("\n{s:<26} {d:>7.3} ms\n", .{ "capture: first frame", ms(t.read()) });
    const fw: f32 = @floatFromInt(W);
    const fh: f32 = @floatFromInt(H);
    _ = picker.handle(.{ .mouse_down = .{ .x = fw * 0.2, .y = fh * 0.2 } });
    var drag = Stats{};
    defer drag.deinit(gpa);
    var damage_px: u64 = 0;
    for (0..100) |i| {
        const f = @as(f32, @floatFromInt(i + 1)) / 100;
        _ = picker.handle(.{ .mouse_move = .{ .x = fw * (0.2 + 0.6 * f), .y = fh * (0.2 + 0.6 * f) } });
        t.reset();
        const d = try scene.render(ctx, &picker, &frozen, &frame);
        try drag.add(gpa, t.read());
        damage_px += d.area();
    }
    try drag.report(w, "capture: drag frame");
    try w.print("{s:<26} avg {d} px/frame ({d:.1}% of screen)\n", .{ "  damage", damage_px / 100, @as(f64, @floatFromInt(damage_px / 100)) * 100 / (fw * fh) });
    _ = picker.handle(.{ .mouse_up = .{ .x = fw * 0.8, .y = fh * 0.8 } });
    if (picker.result == null) return error.BenchCaptureNotConfirmed;
    t.reset();
    var crop = try core.picker.crop(gpa, &frozen, picker.result.?);
    defer crop.deinit(gpa);
    try w.print("{s:<26} {d:>7.3} ms ({d}x{d})\n", .{ "capture: crop", ms(t.read()), crop.width, crop.height });
}
