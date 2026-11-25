//! X11 backend: one full-screen window (WM_CLASS "felt"), Xlib events
//! translated to core input events, frames blitted with MIT-SHM
//! (XShmPutImage, damaged rectangles only). Falls back to XPutImage without SHM.
//! The image decodes on a thread while the window comes up.
const std = @import("std");
const core = @import("core");
const Cursors = @import("x11_cursor.zig").Cursors;
const app_mod = @import("../app.zig");
const config = @import("../config.zig");

const xlib = @import("xlib.zig");
const c = xlib.c;

const input = core.input;
const Canvas = core.canvas.Canvas;

pub const Options = struct {
    /// The image file to open, or null when `image` is given.
    image_path: ?[]const u8 = null,
    /// An image already in memory (a capture); the editor owns it. Wins over `image_path`.
    image: ?Canvas = null,
    output_path: []const u8,
    timing: bool = false,
    /// Exit right after the first frame is on screen.
    smoke: bool = false,
    /// More image files, placed one after the other to the right (magnet
    /// slots, as for `addimage right`), after the first one is open.
    extra_paths: []const []const u8 = &.{},
    /// Config file to read at startup and write on a settings change.
    config_path: ?[]const u8 = null,
    /// --canvas-bg: wins over the config file.
    canvas_bg: ?core.settings.CanvasBg = null,
};

const xc_crosshair = xlib.xc_crosshair;
const xa_atom = xlib.xa_atom;
const Surface = xlib.Surface;
const translateKey = xlib.translateKey;
const mods = xlib.mods;

const Load = struct {
    image: anyerror!Canvas = error.NotLoaded,
    ns: u64 = 0,

    fn run(self: *Load, gpa: std.mem.Allocator, path: []const u8) void {
        var t = std.time.Timer.start() catch unreachable;
        self.image = core.image_io.load(gpa, path);
        self.ns = t.read();
    }
};

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

/// 2 for the second left press of a double click, else 1 (and remember it).
fn clickCount(last: anytype, time: c_ulong, x: f32, y: f32) u8 {
    const double = last.clicks == 1 and time -% last.t <= 400 and @abs(x - last.x) <= 6 and @abs(y - last.y) <= 6;
    last.* = .{ .t = time, .x = x, .y = y, .clicks = if (double) 2 else 1 };
    return last.clicks;
}

pub fn run(gpa: std.mem.Allocator, opts: Options, start: *std.time.Timer) !void {
    var load = Load{};
    var loader: ?std.Thread = null;
    if (opts.image) |img| {
        load.image = img;
    } else loader = try std.Thread.spawn(.{}, Load.run, .{ &load, gpa, opts.image_path.? });
    defer if (loader) |t| t.join();
    // The config file, while the image decodes (a few µs).
    var t_cfg = try std.time.Timer.start();
    const settings = config.resolve(if (opts.config_path) |p| config.load(p) else .{}, opts.canvas_bg);
    const cfg_ns = t_cfg.read();

    const dpy = c.XOpenDisplay(null) orelse return error.NoDisplay;
    defer _ = c.XCloseDisplay(dpy);
    const scr = c.XDefaultScreen(dpy);
    const root = c.XRootWindow(dpy, scr);
    const visual = c.XDefaultVisual(dpy, scr);
    const depth: c_uint = @intCast(c.XDefaultDepth(dpy, scr));
    if ((depth != 24 and depth != 32) or visual.*.red_mask != 0xff0000 or visual.*.green_mask != 0xff00 or visual.*.blue_mask != 0xff)
        return error.UnsupportedVisual;
    const sw: u32 = @intCast(c.XDisplayWidth(dpy, scr));
    const sh: u32 = @intCast(c.XDisplayHeight(dpy, scr));

    const bg = core.compositor.background.toPixel() & 0xffffff;
    const win = c.XCreateSimpleWindow(dpy, root, 0, 0, sw, sh, 0, 0, bg);
    defer _ = c.XDestroyWindow(dpy, win);
    // A held key repeats as presses only, with no release in between.
    var autorepeat_ok: c.Bool = c.False;
    _ = c.XkbSetDetectableAutoRepeat(dpy, c.True, &autorepeat_ok);
    _ = c.XSelectInput(dpy, win, c.KeyPressMask | c.KeyReleaseMask | c.FocusChangeMask | c.ButtonPressMask | c.ButtonReleaseMask | c.PointerMotionMask | c.StructureNotifyMask | c.ExposureMask);

    var class_hint = c.XClassHint{ .res_name = @constCast("felt"), .res_class = @constCast("felt") };
    _ = c.XSetClassHint(dpy, win, &class_hint);
    var title_buf: [512]u8 = undefined;
    const title = std.fmt.bufPrintZ(&title_buf, "felt: {s}", .{if (opts.image_path) |p| std.fs.path.basename(p) else "capture"}) catch "felt";
    _ = c.XStoreName(dpy, win, title.ptr);
    var wm_hints = std.mem.zeroes(c.XWMHints);
    wm_hints.flags = c.InputHint;
    wm_hints.input = c.True;
    _ = c.XSetWMHints(dpy, win, &wm_hints);
    var wm_delete = c.XInternAtom(dpy, "WM_DELETE_WINDOW", c.False);
    _ = c.XSetWMProtocols(dpy, win, &wm_delete, 1);
    const net_state = c.XInternAtom(dpy, "_NET_WM_STATE", c.False);
    const net_fullscreen = c.XInternAtom(dpy, "_NET_WM_STATE_FULLSCREEN", c.False);
    _ = c.XChangeProperty(dpy, win, net_state, xa_atom, 32, c.PropModeReplace, @ptrCast(&net_fullscreen), 1);
    var cursors = Cursors.init(dpy);
    defer cursors.deinit();
    var shown_cursor: core.editor.Editor.Cursor = .crosshair;
    _ = c.XDefineCursor(dpy, win, cursors.get(shown_cursor));
    const gc = c.XCreateGC(dpy, win, 0, null);
    defer _ = c.XFreeGC(dpy, gc);
    _ = c.XMapWindow(dpy, win);
    _ = c.XFlush(dpy);
    const t_window = start.read();

    // While the image decodes: create the frame buffer and fault its pages in.
    const use_shm = c.XShmQueryExtension(dpy) == c.True;
    var surf = try Surface.create(dpy, visual, depth, sw, sh, use_shm);
    defer surf.destroy(dpy);
    var frame_cv = surf.canvas();
    frame_cv.fill(core.compositor.background);

    if (loader) |t| t.join();
    loader = null;
    const image = try load.image;
    const t_loaded = start.read();

    const app = try app_mod.App.create(gpa, image, sw, sh, .{ .output_path = opts.output_path, .settings = settings, .settings_path = opts.config_path });
    defer app.destroy();
    for (opts.extra_paths) |p| {
        app.addImageFile(.{ .path = p, .at = @as(@FieldType(@import("script.zig").AddImage, "at"), .{ .side = .right }) }) catch |err| {
            std.debug.print("felt: cannot open {s}: {s}\n", .{ p, @errorName(err) });
            return error.WriteReported;
        };
    }
    if (opts.extra_paths.len > 0) {
        _ = app.editor.syncView(); // refit to the whole scene
        app.editor.markSaved(); // the images are the start state, not an edit
    }
    app.comp.setFrameBuffer(surf.canvas());

    var ev: c.XEvent = undefined;
    var exposed = false;
    var need_render = true;
    var frames: u64 = 0;
    // Double click: a second left press within 400 ms and 6 px of the first.
    var last_press: struct { t: c_ulong = 0, x: f32 = -100, y: f32 = -100, clicks: u8 = 0 } = .{};
    while (true) {
        _ = c.XNextEvent(dpy, &ev);
        var quit = false;
        while (true) {
            switch (ev.type) {
                c.Expose => if (ev.xexpose.count == 0) {
                    exposed = true;
                    app.comp.invalidate();
                    need_render = true;
                },
                c.ConfigureNotify => {
                    const w: u32 = @intCast(ev.xconfigure.width);
                    const h: u32 = @intCast(ev.xconfigure.height);
                    if (w != app.editor.view.screen_w or h != app.editor.view.screen_h) {
                        _ = try app.handle(.{ .resize = .{ .w = w, .h = h } });
                        surf.destroy(dpy);
                        surf = try Surface.create(dpy, visual, depth, w, h, use_shm);
                        app.comp.setFrameBuffer(surf.canvas());
                        need_render = true;
                    }
                },
                c.ClientMessage => if (@as(c.Atom, @intCast(ev.xclient.data.l[0])) == wm_delete) {
                    quit = true;
                },
                c.KeyPress => {
                    var buf: [8]u8 = undefined;
                    var ks: c.KeySym = 0;
                    _ = c.XLookupString(&ev.xkey, &buf, buf.len, &ks, null);
                    if (translateKey(ks)) |k| {
                        const r = try app.handle(.{ .key = .{ .key = k, .mods = mods(ev.xkey.state) } });
                        quit = quit or r.quit;
                        need_render = need_render or r.redraw;
                    }
                },
                c.KeyRelease => {
                    var buf: [8]u8 = undefined;
                    var ks: c.KeySym = 0;
                    _ = c.XLookupString(&ev.xkey, &buf, buf.len, &ks, null);
                    if (translateKey(ks)) |k| {
                        const r = try app.handle(.{ .key_up = .{ .key = k, .mods = mods(ev.xkey.state) } });
                        need_render = need_render or r.redraw;
                    }
                },
                // The window lost the focus: a key released elsewhere would stay down.
                c.FocusOut => {
                    const r = try app.handle(.{ .key_up = .{ .key = .{ .char = ' ' } } });
                    need_render = need_render or r.redraw;
                },
                c.ButtonPress, c.ButtonRelease => {
                    const b = ev.xbutton;
                    const x: f32 = @floatFromInt(b.x);
                    const y: f32 = @floatFromInt(b.y);
                    const down = ev.type == c.ButtonPress;
                    const e: ?input.Event = switch (b.button) {
                        1, 2, 3 => blk: {
                            const btn: input.Button = switch (b.button) {
                                1 => .left,
                                2 => .middle,
                                else => .right,
                            };
                            break :blk if (down) .{ .mouse_down = .{ .x = x, .y = y, .button = btn, .clicks = if (btn == .left) clickCount(&last_press, b.time, x, y) else 1 } } else .{ .mouse_up = .{ .x = x, .y = y, .button = btn } };
                        },
                        4 => if (down) .{ .wheel = .{ .delta = 1, .x = x, .y = y, .mods = mods(b.state) } } else null,
                        5 => if (down) .{ .wheel = .{ .delta = -1, .x = x, .y = y, .mods = mods(b.state) } } else null,
                        else => null,
                    };
                    if (e) |event| {
                        const r = try app.handle(event);
                        quit = quit or r.quit;
                        need_render = need_render or r.redraw;
                    }
                },
                c.MotionNotify => {
                    const r = try app.handle(.{ .mouse_move = .{ .x = @floatFromInt(ev.xmotion.x), .y = @floatFromInt(ev.xmotion.y) } });
                    need_render = need_render or r.redraw;
                },
                else => {},
            }
            // Drain queued events (e.g. a burst of motion) before drawing once.
            if (quit or c.XPending(dpy) == 0) break;
            _ = c.XNextEvent(dpy, &ev);
        }
        if (quit) break;
        if (app.editor.cursor() != shown_cursor) {
            shown_cursor = app.editor.cursor();
            _ = c.XDefineCursor(dpy, win, cursors.get(shown_cursor));
        }
        if (need_render and exposed) {
            var t = try std.time.Timer.start();
            const dmg = try app.render();
            const t_render = t.lap();
            surf.present(dpy, win, gc, dmg.slice());
            const t_present = t.read();
            need_render = false;
            frames += 1;
            if (frames == 1 and opts.timing) {
                std.debug.print(
                    "timing: window mapped {d:.1} ms, image decoded {d:.1} ms (thread, {d:.1} ms), config read {d:.3} ms, first frame on screen {d:.1} ms (render {d:.1} ms, present {d:.1} ms), {d}x{d}, shm={}\n",
                    .{ ms(t_window), ms(t_loaded), ms(load.ns), ms(cfg_ns), ms(start.read()), ms(t_render), ms(t_present), app.editor.view.screen_w, app.editor.view.screen_h, use_shm },
                );
            }
            if (opts.smoke) break;
        }
    }
}
