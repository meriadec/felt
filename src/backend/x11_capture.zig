//! X11 capture backend (`felt --capture`): grab the whole root window, show
//! it frozen and dimmed in a borderless full-screen overlay, run the picker
//! (core/picker.zig) on the translated events, and return the chosen part as
//! a canvas. With a delay the overlay goes away first and the region is
//! grabbed fresh from the live screen. Cancelled: null.
//!
//! The overlay is override-redirect (no window manager, no animation, exact
//! place) and takes the pointer and the keyboard with grabs. The window list
//! for click-to-select is a snapshot of the root's viewable children taken
//! before the overlay exists, so the overlay never hides a window.
const std = @import("std");
const core = @import("core");
const xlib = @import("xlib.zig");

const c = xlib.c;
const Surface = xlib.Surface;
const Canvas = core.canvas.Canvas;
const Rect = core.geom.Rect;
const input = core.input;

pub const Options = struct {
    /// Initial delay before the live grab, ms (Tab toggles it).
    delay_ms: u32 = 0,
    timing: bool = false,
};

/// After the overlay is gone, wait at least this long for the screen to
/// repaint (a compositor may lag a frame or two).
const min_settle_ms = 100;

/// Copy a screen region from the root window into a new canvas (opaque).
fn grabRegion(gpa: std.mem.Allocator, dpy: *c.Display, root: c.Window, r: Rect) !Canvas {
    const img = c.XGetImage(dpy, root, r.x0, r.y0, @intCast(r.width()), @intCast(r.height()), c.AllPlanes, c.ZPixmap) orelse return error.GrabFailed;
    defer _ = img.*.f.destroy_image.?(img);
    if (img.*.bits_per_pixel != 32) return error.UnsupportedVisual;
    var cv = try Canvas.init(gpa, @intCast(r.width()), @intCast(r.height()));
    errdefer cv.deinit(gpa);
    const w: usize = cv.width;
    const bpl: usize = @intCast(img.*.bytes_per_line);
    const data: [*]const u8 = @ptrCast(img.*.data);
    for (0..cv.height) |y| {
        const row: [*]const u32 = @ptrCast(@alignCast(data + y * bpl));
        for (cv.pixels[y * w ..][0..w], row[0..w]) |*d, s| d.* = s | 0xff000000;
    }
    return cv;
}

/// Fill `surf` (screen sized) with the root window: shared memory when the
/// surface has it (no copy through the socket), else XGetImage.
fn grabInto(dpy: *c.Display, root: c.Window, surf: *Surface) !void {
    if (surf.shm != null) {
        if (c.XShmGetImage(dpy, root, surf.img, 0, 0, c.AllPlanes) != 0) return;
    }
    const img = c.XGetImage(dpy, root, 0, 0, surf.w, surf.h, c.AllPlanes, c.ZPixmap) orelse return error.GrabFailed;
    defer _ = img.*.f.destroy_image.?(img);
    const dst = surf.canvas();
    const w: usize = surf.w;
    const bpl: usize = @intCast(img.*.bytes_per_line);
    const data: [*]const u8 = @ptrCast(img.*.data);
    for (0..surf.h) |y| @memcpy(dst.pixels[y * w ..][0..w], @as([*]const u32, @ptrCast(@alignCast(data + y * bpl)))[0..w]);
}

/// Viewable top-level windows of the screen with their frames, topmost
/// first. Caller frees.
fn windowList(gpa: std.mem.Allocator, dpy: *c.Display, root: c.Window) ![]Rect {
    var list: std.ArrayList(Rect) = .empty;
    errdefer list.deinit(gpa);
    var root_ret: c.Window = 0;
    var parent_ret: c.Window = 0;
    var kids: [*c]c.Window = null;
    var n: c_uint = 0;
    if (c.XQueryTree(dpy, root, &root_ret, &parent_ret, &kids, &n) == 0) return list.toOwnedSlice(gpa);
    defer _ = c.XFree(kids);
    var i: usize = n;
    while (i > 0) { // the tree lists bottom to top
        i -= 1;
        var at: c.XWindowAttributes = undefined;
        if (c.XGetWindowAttributes(dpy, kids[i], &at) == 0) continue;
        if (at.map_state != c.IsViewable or at.class == c.InputOnly) continue;
        const bw = at.border_width;
        const r = Rect.fromSize(at.x, at.y, at.width + 2 * bw, at.height + 2 * bw);
        if (r.width() < 8 or r.height() < 8) continue;
        try list.append(gpa, r);
    }
    return list.toOwnedSlice(gpa);
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

pub fn run(gpa: std.mem.Allocator, opts: Options) !?Canvas {
    var timer = try std.time.Timer.start();
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
    const use_shm = c.XShmQueryExtension(dpy) == c.True;

    // 1. Freeze the screen, before anything of ours is on it.
    var frozen = try Surface.create(dpy, visual, depth, sw, sh, use_shm);
    defer frozen.destroy(dpy);
    try grabInto(dpy, root, &frozen);
    const t_grab = timer.read();
    const windows = try windowList(gpa, dpy, root);
    defer gpa.free(windows);
    const frozen_cv = frozen.canvas();

    // 2. The overlay: borderless, full screen, over everything.
    var attrs = std.mem.zeroes(c.XSetWindowAttributes);
    attrs.override_redirect = c.True;
    attrs.event_mask = c.KeyPressMask | c.ButtonPressMask | c.ButtonReleaseMask | c.PointerMotionMask | c.ExposureMask;
    const win = c.XCreateWindow(dpy, root, 0, 0, sw, sh, 0, @intCast(depth), c.InputOutput, visual, c.CWOverrideRedirect | c.CWEventMask, &attrs);
    var overlay_alive = true;
    defer if (overlay_alive) {
        _ = c.XDestroyWindow(dpy, win);
    };
    var class_hint = c.XClassHint{ .res_name = @constCast("felt"), .res_class = @constCast("felt-capture") };
    _ = c.XSetClassHint(dpy, win, &class_hint);
    _ = c.XStoreName(dpy, win, "felt capture");
    const cursor = c.XCreateFontCursor(dpy, xlib.xc_crosshair);
    _ = c.XDefineCursor(dpy, win, cursor);
    const gc = c.XCreateGC(dpy, win, 0, null);
    defer _ = c.XFreeGC(dpy, gc);
    var frame = try Surface.create(dpy, visual, depth, sw, sh, use_shm);
    defer frame.destroy(dpy);
    var frame_cv = frame.canvas();
    _ = c.XMapRaised(dpy, win);
    _ = c.XSync(dpy, c.False);
    try grabInput(dpy, win, cursor);

    var font = try core.font.Font.init(gpa, core.font_ttf);
    defer font.deinit();
    const ctx = core.draw.Ctx{ .gpa = gpa, .font = &font };
    var picker = core.picker.Picker.init(sw, sh, windows, opts.delay_ms);
    var scene = core.picker_draw.Scene{};

    // The pointer is somewhere already: hover from the first frame.
    {
        var rr: c.Window = 0;
        var cr: c.Window = 0;
        var rx: c_int = 0;
        var ry: c_int = 0;
        var wx: c_int = 0;
        var wy: c_int = 0;
        var m: c_uint = 0;
        if (c.XQueryPointer(dpy, win, &rr, &cr, &rx, &ry, &wx, &wy, &m) != 0)
            _ = picker.handle(.{ .mouse_move = .{ .x = @floatFromInt(rx), .y = @floatFromInt(ry) } });
    }

    var ev: c.XEvent = undefined;
    var need_render = true;
    var exposed = false;
    var frames: u64 = 0;
    while (!picker.finished()) {
        _ = c.XNextEvent(dpy, &ev);
        while (true) {
            switch (ev.type) {
                c.Expose => if (ev.xexpose.count == 0) {
                    exposed = true;
                    scene = .{}; // repaint everything
                    need_render = true;
                },
                c.KeyPress => {
                    var buf: [8]u8 = undefined;
                    var ks: c.KeySym = 0;
                    _ = c.XLookupString(&ev.xkey, &buf, buf.len, &ks, null);
                    if (xlib.translateKey(ks)) |k| {
                        need_render = picker.handle(.{ .key = .{ .key = k, .mods = xlib.mods(ev.xkey.state) } }).redraw or need_render;
                    }
                },
                c.ButtonPress, c.ButtonRelease => {
                    const b = ev.xbutton;
                    const btn: ?input.Button = switch (b.button) {
                        1 => .left,
                        3 => .right,
                        else => null,
                    };
                    if (btn) |bt| {
                        const x: f32 = @floatFromInt(b.x);
                        const y: f32 = @floatFromInt(b.y);
                        const e: input.Event = if (ev.type == c.ButtonPress) .{ .mouse_down = .{ .x = x, .y = y, .button = bt } } else .{ .mouse_up = .{ .x = x, .y = y, .button = bt } };
                        need_render = picker.handle(e).redraw or need_render;
                    }
                },
                c.MotionNotify => {
                    need_render = picker.handle(.{ .mouse_move = .{ .x = @floatFromInt(ev.xmotion.x), .y = @floatFromInt(ev.xmotion.y) } }).redraw or need_render;
                },
                else => {},
            }
            if (picker.finished() or c.XPending(dpy) == 0) break; // drain a burst of motion, draw once
            _ = c.XNextEvent(dpy, &ev);
        }
        if (need_render and exposed and !picker.finished()) {
            const dmg = try scene.render(ctx, &picker, &frozen_cv, &frame_cv);
            frame.present(dpy, win, gc, dmg.slice());
            need_render = false;
            frames += 1;
            if (frames == 1 and opts.timing)
                std.debug.print("timing: root grab {d:.1} ms, first picker frame {d:.1} ms, {d}x{d}, {d} windows, shm={}\n", .{ ms(t_grab), ms(timer.read()), sw, sh, windows.len, use_shm });
        }
    }

    // 3. Done: release the grabs and the screen.
    _ = c.XUngrabPointer(dpy, c.CurrentTime);
    _ = c.XUngrabKeyboard(dpy, c.CurrentTime);
    const rect = picker.result orelse {
        _ = c.XDestroyWindow(dpy, win);
        overlay_alive = false;
        _ = c.XSync(dpy, c.False);
        return null;
    };
    if (picker.delay_ms == 0) return try core.picker.crop(gpa, &frozen_cv, rect);

    _ = c.XDestroyWindow(dpy, win);
    overlay_alive = false;
    _ = c.XSync(dpy, c.False);
    std.Thread.sleep(@as(u64, @max(picker.delay_ms, min_settle_ms)) * std.time.ns_per_ms);
    return try grabRegion(gpa, dpy, root, rect);
}

/// Take the pointer and the keyboard. A key of the binding that started us
/// may still be down, so retry for a while.
fn grabInput(dpy: *c.Display, win: c.Window, cursor: c.Cursor) !void {
    var tries: usize = 0;
    while (tries < 50) : (tries += 1) {
        const p = c.XGrabPointer(dpy, win, c.False, c.ButtonPressMask | c.ButtonReleaseMask | c.PointerMotionMask, c.GrabModeAsync, c.GrabModeAsync, c.None, cursor, c.CurrentTime);
        const k = c.XGrabKeyboard(dpy, win, c.False, c.GrabModeAsync, c.GrabModeAsync, c.CurrentTime);
        if (p == c.GrabSuccess and k == c.GrabSuccess) return;
        _ = c.XUngrabPointer(dpy, c.CurrentTime);
        _ = c.XUngrabKeyboard(dpy, c.CurrentTime);
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    return error.GrabFailed;
}
