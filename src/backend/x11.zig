//! X11 backend: one full-screen window (WM_CLASS "annotate"), Xlib events
//! translated to core input events, frames blitted with MIT-SHM
//! (XShmPutImage, damaged rectangles only). Falls back to XPutImage without SHM.
//! The image decodes on a thread while the window comes up.
const std = @import("std");
const core = @import("core");
const app_mod = @import("../app.zig");

const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/keysym.h");
    @cInclude("X11/extensions/XShm.h");
    @cInclude("sys/ipc.h");
    @cInclude("sys/shm.h");
});

const input = core.input;
const Canvas = core.canvas.Canvas;

pub const Options = struct {
    image_path: []const u8,
    output_path: []const u8,
    timing: bool = false,
    /// Exit right after the first frame is on screen.
    smoke: bool = false,
};

const xc_crosshair = 34;
const xa_atom = 4;

const Load = struct {
    image: anyerror!Canvas = error.NotLoaded,
    ns: u64 = 0,

    fn run(self: *Load, gpa: std.mem.Allocator, path: []const u8) void {
        var t = std.time.Timer.start() catch unreachable;
        self.image = core.image_io.load(gpa, path);
        self.ns = t.read();
    }
};

/// Off-screen XImage the frame is copied into before XShmPutImage/XPutImage.
const Surface = struct {
    img: *c.XImage,
    /// Heap allocated: the XImage keeps a pointer to it (obdata).
    shm: ?*c.XShmSegmentInfo,
    w: u32,
    h: u32,

    fn create(dpy: *c.Display, visual: *c.Visual, depth: c_uint, w: u32, h: u32, use_shm: bool) !Surface {
        if (use_shm) shm: {
            const info = try std.heap.c_allocator.create(c.XShmSegmentInfo);
            info.* = std.mem.zeroes(c.XShmSegmentInfo);
            errdefer std.heap.c_allocator.destroy(info);
            const img = c.XShmCreateImage(dpy, visual, depth, c.ZPixmap, null, info, w, h) orelse {
                std.heap.c_allocator.destroy(info);
                break :shm;
            };
            const size: usize = @as(usize, @intCast(img.*.bytes_per_line)) * h;
            info.shmid = c.shmget(c.IPC_PRIVATE, size, c.IPC_CREAT | 0o600);
            if (info.shmid < 0) {
                _ = img.*.f.destroy_image.?(img);
                std.heap.c_allocator.destroy(info);
                break :shm;
            }
            const addr = c.shmat(info.shmid, null, 0);
            if (@intFromPtr(addr) == std.math.maxInt(usize)) {
                _ = c.shmctl(info.shmid, c.IPC_RMID, null);
                _ = img.*.f.destroy_image.?(img);
                std.heap.c_allocator.destroy(info);
                break :shm;
            }
            info.shmaddr = @ptrCast(addr);
            img.*.data = info.shmaddr;
            info.readOnly = c.False;
            _ = c.XShmAttach(dpy, info);
            _ = c.XSync(dpy, c.False);
            _ = c.shmctl(info.shmid, c.IPC_RMID, null); // freed when both sides detach
            return .{ .img = img, .shm = info, .w = w, .h = h };
        }
        const data: [*c]u8 = @ptrCast(std.c.malloc(@as(usize, w) * h * 4) orelse return error.OutOfMemory);
        errdefer std.c.free(data);
        const img = c.XCreateImage(dpy, visual, depth, c.ZPixmap, 0, data, w, h, 32, 0) orelse return error.XCreateImageFailed;
        return .{ .img = img, .shm = null, .w = w, .h = h };
    }

    fn destroy(self: *Surface, dpy: *c.Display) void {
        if (self.shm) |info| {
            _ = c.XShmDetach(dpy, info);
            _ = c.XSync(dpy, c.False);
            _ = self.img.*.f.destroy_image.?(self.img);
            _ = c.shmdt(info.shmaddr);
            std.heap.c_allocator.destroy(info);
        } else {
            _ = self.img.*.f.destroy_image.?(self.img); // frees data with free()
        }
    }

    /// The image memory as a canvas: the compositor renders straight into it.
    fn canvas(self: *const Surface) Canvas {
        std.debug.assert(self.img.*.bytes_per_line == self.w * 4 and self.img.*.bits_per_pixel == 32);
        const px: [*]u32 = @ptrCast(@alignCast(self.img.*.data));
        return .{ .width = self.w, .height = self.h, .pixels = px[0 .. @as(usize, self.w) * self.h] };
    }

    fn present(self: *Surface, dpy: *c.Display, win: c.Window, gc: c.GC, rects: []const core.geom.Rect) void {
        const bounds = core.geom.Rect.fromSize(0, 0, @intCast(self.w), @intCast(self.h));
        for (rects) |r_in| {
            const r = r_in.intersect(bounds);
            if (r.isEmpty()) continue;
            const x: c_int = r.x0;
            const yy: c_int = r.y0;
            const w: c_uint = @intCast(r.width());
            const h: c_uint = @intCast(r.height());
            if (self.shm != null) {
                _ = c.XShmPutImage(dpy, win, gc, self.img, x, yy, x, yy, w, h, c.False);
            } else {
                _ = c.XPutImage(dpy, win, gc, self.img, x, yy, x, yy, w, h);
            }
        }
        // Wait until the server has read the buffer before we write it again.
        _ = c.XSync(dpy, c.False);
    }
};

fn translateKey(ks: c.KeySym) ?input.Key {
    return switch (ks) {
        c.XK_Escape => .{ .named = .escape },
        c.XK_Return, c.XK_KP_Enter => .{ .named = .enter },
        c.XK_BackSpace => .{ .named = .backspace },
        c.XK_Delete => .{ .named = .delete },
        c.XK_Tab, c.XK_ISO_Left_Tab => .{ .named = .tab }, // Shift+Tab sends ISO_Left_Tab
        c.XK_F1 => .{ .named = .f1 },
        c.XK_Left => .{ .named = .left },
        c.XK_Right => .{ .named = .right },
        c.XK_Up => .{ .named = .up },
        c.XK_Down => .{ .named = .down },
        c.XK_Home => .{ .named = .home },
        c.XK_End => .{ .named = .end },
        0x20...0x7e, 0xa0...0xff => .{ .char = @intCast(ks) },
        0x01000100...0x0110ffff => .{ .char = @intCast(ks - 0x01000000) },
        else => null,
    };
}

fn mods(state: c_uint) input.Mods {
    return .{ .shift = state & c.ShiftMask != 0, .ctrl = state & c.ControlMask != 0, .alt = state & c.Mod1Mask != 0 };
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

pub fn run(gpa: std.mem.Allocator, opts: Options, start: *std.time.Timer) !void {
    var load = Load{};
    const loader = try std.Thread.spawn(.{}, Load.run, .{ &load, gpa, opts.image_path });
    var joined = false;
    defer if (!joined) loader.join();

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
    _ = c.XSelectInput(dpy, win, c.KeyPressMask | c.ButtonPressMask | c.ButtonReleaseMask | c.PointerMotionMask | c.StructureNotifyMask | c.ExposureMask);

    var class_hint = c.XClassHint{ .res_name = @constCast("annotate"), .res_class = @constCast("annotate") };
    _ = c.XSetClassHint(dpy, win, &class_hint);
    var title_buf: [512]u8 = undefined;
    const title = std.fmt.bufPrintZ(&title_buf, "annotate: {s}", .{std.fs.path.basename(opts.image_path)}) catch "annotate";
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
    _ = c.XDefineCursor(dpy, win, c.XCreateFontCursor(dpy, xc_crosshair));
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

    loader.join();
    joined = true;
    const image = try load.image;
    const t_loaded = start.read();

    const app = try app_mod.App.create(gpa, image, sw, sh, .{ .output_path = opts.output_path });
    defer app.destroy();
    app.comp.setFrameBuffer(surf.canvas());

    var ev: c.XEvent = undefined;
    var exposed = false;
    var need_render = true;
    var frames: u64 = 0;
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
                            break :blk if (down) .{ .mouse_down = .{ .x = x, .y = y, .button = btn } } else .{ .mouse_up = .{ .x = x, .y = y, .button = btn } };
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
                    "timing: window mapped {d:.1} ms, image decoded {d:.1} ms (thread, {d:.1} ms), first frame on screen {d:.1} ms (render {d:.1} ms, present {d:.1} ms), {d}x{d}, shm={}\n",
                    .{ ms(t_window), ms(t_loaded), ms(load.ns), ms(start.read()), ms(t_render), ms(t_present), app.editor.view.screen_w, app.editor.view.screen_h, use_shm },
                );
            }
            if (opts.smoke) break;
        }
    }
}
