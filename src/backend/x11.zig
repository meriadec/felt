//! X11 backend: one full-screen window (WM_CLASS "felt"), Xlib events
//! translated to core input events, frames blitted with MIT-SHM
//! (XShmPutImage, damaged rectangles only). Falls back to XPutImage without SHM.
//! The image decodes on a thread while the window comes up.
const std = @import("std");
const core = @import("core");
const Cursors = @import("x11_cursor.zig").Cursors;
const app_mod = @import("../app.zig");
const config = @import("../config.zig");
const capture = @import("x11_capture.zig");

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
    /// Ctrl+S target once the browser adds an image (see `App.Config.montage_output`).
    montage_output: ?[]const u8 = null,
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
        var t = core.sys.Timer.start() catch unreachable;
        self.image = core.image_io.load(gpa, path);
        self.ns = t.read();
    }
};

/// Seconds east of UTC now (for the dates in the file browser).
fn localOffset() i32 {
    var t: c.time_t = c.time(null);
    var tm: c.struct_tm = undefined;
    if (c.localtime_r(&t, &tm) == null) return 0;
    return @intCast(tm.tm_gmtoff);
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

/// 2 for the second left press of a double click, else 1 (and remember it).
fn clickCount(last: anytype, time: c_ulong, x: f32, y: f32) u8 {
    const double = last.clicks == 1 and time -% last.t <= 400 and @abs(x - last.x) <= 6 and @abs(y - last.y) <= 6;
    last.* = .{ .t = time, .x = x, .y = y, .clicks = if (double) 2 else 1 };
    return last.clicks;
}

var print_grab_error: c_int = 0;

fn recordPrintGrabError(_: ?*c.Display, event: [*c]c.XErrorEvent) callconv(.c) c_int {
    if (event != null) print_grab_error = event.*.error_code;
    return 0;
}

/// Grab bare Print and the CapsLock/NumLock variants on the root window.
fn grabPrint(dpy: *c.Display, root: c.Window, keycode: c.KeyCode) bool {
    if (keycode == 0) {
        std.debug.print("felt: cannot grab global Print key: no X11 keycode\n", .{});
        return false;
    }
    _ = c.XSync(dpy, c.False);
    const previous_handler = c.XSetErrorHandler(recordPrintGrabError);
    const masks = [_]c_uint{ 0, c.LockMask, c.Mod2Mask, c.LockMask | c.Mod2Mask };
    var bare_grabbed = false;
    var last_error: c_int = 0;
    for (masks) |mask| {
        print_grab_error = 0;
        _ = c.XGrabKey(dpy, keycode, mask, root, c.False, c.GrabModeAsync, c.GrabModeAsync);
        _ = c.XSync(dpy, c.False);
        if (print_grab_error == 0) {
            if (mask == 0) bare_grabbed = true;
        } else {
            last_error = print_grab_error;
        }
    }
    _ = c.XSetErrorHandler(previous_handler);
    if (bare_grabbed) return true;
    for (masks) |mask| _ = c.XUngrabKey(dpy, keycode, mask, root);
    _ = c.XSync(dpy, c.False);
    std.debug.print("felt: cannot grab global Print key (X11 error {d}); another client may own it\n", .{last_error});
    return false;
}

/// Ask the window manager to bring the editor back after the picker closes.
fn activateEditor(dpy: *c.Display, root: c.Window, win: c.Window, net_active: c.Atom) void {
    _ = c.XMapRaised(dpy, win);
    var event = std.mem.zeroes(c.XEvent);
    event.xclient.type = c.ClientMessage;
    event.xclient.send_event = c.True;
    event.xclient.display = dpy;
    event.xclient.window = win;
    event.xclient.message_type = net_active;
    event.xclient.format = 32;
    event.xclient.data.l[0] = 1; // source: application
    event.xclient.data.l[1] = c.CurrentTime;
    _ = c.XSendEvent(dpy, root, c.False, c.SubstructureRedirectMask | c.SubstructureNotifyMask, &event);
    _ = c.XFlush(dpy);
}

/// Hide the editor and let the window manager repaint the desktop before the
/// capture backend freezes the root window.
fn hideEditorForCapture(dpy: *c.Display, win: c.Window, screen: c_int) void {
    _ = c.XIconifyWindow(dpy, win, screen);
    _ = c.XSync(dpy, c.False);
    core.sys.sleepNs(100 * std.time.ns_per_ms);
    var attrs: c.XWindowAttributes = undefined;
    if (c.XGetWindowAttributes(dpy, win, &attrs) != 0 and attrs.map_state == c.IsViewable) {
        // If there is no cooperating window manager, at least remove Felt
        // from the root image. activateEditor maps it again afterwards.
        _ = c.XUnmapWindow(dpy, win);
        _ = c.XSync(dpy, c.False);
        core.sys.sleepNs(100 * std.time.ns_per_ms);
    }
}

/// Run the existing picker from the global hotkey and add its result to this App.
fn captureIntoApp(gpa: std.mem.Allocator, dpy: *c.Display, root: c.Window, win: c.Window, screen: c_int, net_active: c.Atom, app: *app_mod.App, config_path: ?[]const u8) void {
    // Print's passive grab became active on this connection. Release it so the
    // capture connection can take the keyboard for the picker.
    _ = c.XUngrabKeyboard(dpy, c.CurrentTime);
    _ = c.XSync(dpy, c.False);
    hideEditorForCapture(dpy, win, screen);
    const image = capture.run(gpa, .{ .config_path = config_path }) catch |err| {
        std.debug.print("felt: global Print capture failed: {s}\n", .{@errorName(err)});
        app.editor.setToast("Capture failed: {s}", .{@errorName(err)});
        activateEditor(dpy, root, win, net_active);
        return;
    };
    if (image) |shot| app.addCapturedImage(shot) catch |err| {
        std.debug.print("felt: cannot add captured screenshot: {s}\n", .{@errorName(err)});
        app.editor.setToast("Screenshot not added: {s}", .{@errorName(err)});
    };
    activateEditor(dpy, root, win, net_active);
}

pub fn run(gpa: std.mem.Allocator, opts: Options, start: *core.sys.Timer) !void {
    var load = Load{};
    var loader: ?std.Thread = null;
    if (opts.image) |img| {
        load.image = img;
    } else loader = try std.Thread.spawn(.{}, Load.run, .{ &load, gpa, opts.image_path.? });
    defer if (loader) |t| t.join();
    // The config file, while the image decodes (a few µs).
    var t_cfg = try core.sys.Timer.start();
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
    _ = c.XSelectInput(dpy, root, c.KeyReleaseMask);

    var class_hint = c.XClassHint{ .res_name = @constCast("felt"), .res_class = @constCast("felt") };
    _ = c.XSetClassHint(dpy, win, &class_hint);
    var title_buf: [512]u8 = undefined;
    const title = std.fmt.bufPrintSentinel(&title_buf, "felt: {s}", .{if (opts.image_path) |p| std.fs.path.basename(p) else "capture"}, 0) catch "felt";
    _ = c.XStoreName(dpy, win, title.ptr);
    var wm_hints = std.mem.zeroes(c.XWMHints);
    wm_hints.flags = c.InputHint;
    wm_hints.input = c.True;
    _ = c.XSetWMHints(dpy, win, &wm_hints);
    var wm_delete = c.XInternAtom(dpy, "WM_DELETE_WINDOW", c.False);
    _ = c.XSetWMProtocols(dpy, win, &wm_delete, 1);
    const net_state = c.XInternAtom(dpy, "_NET_WM_STATE", c.False);
    const net_fullscreen = c.XInternAtom(dpy, "_NET_WM_STATE_FULLSCREEN", c.False);
    const net_active = c.XInternAtom(dpy, "_NET_ACTIVE_WINDOW", c.False);
    _ = c.XChangeProperty(dpy, win, net_state, xa_atom, 32, c.PropModeReplace, @ptrCast(&net_fullscreen), 1);
    var cursors = Cursors.init(dpy);
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

    const app = try app_mod.App.create(gpa, image, sw, sh, .{ .output_path = opts.output_path, .settings = settings, .settings_path = opts.config_path, .montage_output = opts.montage_output });
    defer app.destroy();
    const print_keycode = c.XKeysymToKeycode(dpy, c.XK_Print);
    const print_grabbed = !opts.smoke and grabPrint(dpy, root, print_keycode);
    if (!opts.smoke and !print_grabbed) app.editor.setToast("Global Print key unavailable.", .{});
    // The file browser: background work wakes the loop through a pipe.
    const wake = try core.sys.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    defer core.sys.close(wake[0]);
    defer core.sys.close(wake[1]);
    app.editor.browser.threaded = true;
    app.editor.browser.wake_fd = wake[1];
    try app.editor.browser.setHome(core.sys.getenv("HOME"));
    app.editor.browser.tz_off = localOffset();
    for (opts.extra_paths) |p| {
        app.addImageFile(.{ .path = p, .at = @as(@FieldType(@import("script.zig").AddImage, "at"), .{ .side = .right }) }) catch |err| {
            std.debug.print("felt: cannot open {s}: {s}\n", .{ p, @errorName(err) });
            return error.WriteReported;
        };
    }
    if (opts.extra_paths.len > 0) {
        _ = app.editor.syncView();
        app.editor.fit(); // the initial fit of the whole scene
        app.editor.markSaved(); // the images are the start state, not an edit
    }
    app.comp.setFrameBuffer(surf.canvas());

    var ev: c.XEvent = undefined;
    var exposed = false;
    var need_render = true;
    var frames: u64 = 0;
    var print_armed = false;
    var print_down = false;
    // Double click: a second left press within 400 ms and 6 px of the first.
    var last_press: struct { t: c_ulong = 0, x: f32 = -100, y: f32 = -100, clicks: u8 = 0 } = .{};
    while (true) {
        // Wait for X events, and for the browser's background work while it
        // runs.
        // With none of these the loop blocks in XNextEvent: no idle CPU.
        var have_event = true;
        const working = app.editor.browser.busy();
        if (working and c.XPending(dpy) == 0) {
            var pfds = [2]std.posix.pollfd{
                .{ .fd = c.ConnectionNumber(dpy), .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = wake[0], .events = std.posix.POLL.IN, .revents = 0 },
            };
            _ = std.posix.poll(&pfds, -1) catch 0;
            if (pfds[1].revents != 0) {
                var sink: [64]u8 = undefined;
                while ((std.posix.read(wake[0], &sink) catch 0) == sink.len) {}
            }
            if (app.pump()) need_render = true;
            have_event = c.XPending(dpy) > 0;
        }
        if (have_event) _ = c.XNextEvent(dpy, &ev);
        var quit = false;
        while (have_event) {
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
                    if (print_grabbed and ev.xkey.keycode == print_keycode) {
                        print_down = true; // wait for physical release; ignore key repeat
                    } else {
                        var buf: [8]u8 = undefined;
                        var ks: c.KeySym = 0;
                        _ = c.XLookupString(&ev.xkey, &buf, buf.len, &ks, null);
                        if (translateKey(ks)) |k| {
                            const r = try app.handle(.{ .key = .{ .key = k, .mods = mods(ev.xkey.state) } });
                            quit = quit or r.quit;
                            need_render = need_render or r.redraw;
                        }
                    }
                },
                c.KeyRelease => {
                    if (print_grabbed and ev.xkey.keycode == print_keycode and print_down) {
                        print_down = false;
                        _ = c.XUngrabKeyboard(dpy, c.CurrentTime);
                        _ = c.XSync(dpy, c.False);
                        if (print_armed) {
                            print_armed = false;
                            captureIntoApp(gpa, dpy, root, win, scr, net_active, app, opts.config_path);
                            need_render = true;
                        } else {
                            print_armed = true;
                            hideEditorForCapture(dpy, win, scr);
                            std.debug.print("felt: editor hidden; press Print again to capture\n", .{});
                        }
                    } else {
                        var buf: [8]u8 = undefined;
                        var ks: c.KeySym = 0;
                        _ = c.XLookupString(&ev.xkey, &buf, buf.len, &ks, null);
                        if (translateKey(ks)) |k| {
                            const r = try app.handle(.{ .key_up = .{ .key = k, .mods = mods(ev.xkey.state) } });
                            need_render = need_render or r.redraw;
                        }
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
            var t = try core.sys.Timer.start();
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
