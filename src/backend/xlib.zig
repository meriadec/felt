//! Xlib pieces shared by the X11 backends (editor in x11.zig,
//! capture picker in x11_capture.zig): the one C import, the MIT-SHM
//! `Surface` (an XImage the core renders into), and key and modifier translation.
const std = @import("std");
const core = @import("core");

pub const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/keysym.h");
    @cInclude("X11/extensions/XShm.h");
    @cInclude("sys/ipc.h");
    @cInclude("sys/shm.h");
});

pub const xc_crosshair = 34;
pub const xa_atom = 4;

const input = core.input;
const Canvas = core.canvas.Canvas;

/// Off-screen XImage the frame is copied into before XShmPutImage/XPutImage.
pub const Surface = struct {
    img: *c.XImage,
    /// Heap allocated: the XImage keeps a pointer to it (obdata).
    shm: ?*c.XShmSegmentInfo,
    w: u32,
    h: u32,

    pub fn create(dpy: *c.Display, visual: *c.Visual, depth: c_uint, w: u32, h: u32, use_shm: bool) !Surface {
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

    pub fn destroy(self: *Surface, dpy: *c.Display) void {
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
    pub fn canvas(self: *const Surface) Canvas {
        std.debug.assert(self.img.*.bytes_per_line == self.w * 4 and self.img.*.bits_per_pixel == 32);
        const px: [*]u32 = @ptrCast(@alignCast(self.img.*.data));
        return .{ .width = self.w, .height = self.h, .pixels = px[0 .. @as(usize, self.w) * self.h] };
    }

    pub fn present(self: *Surface, dpy: *c.Display, win: c.Window, gc: c.GC, rects: []const core.geom.Rect) void {
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

pub fn translateKey(ks: c.KeySym) ?input.Key {
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

pub fn mods(state: c_uint) input.Mods {
    return .{ .shift = state & c.ShiftMask != 0, .ctrl = state & c.ControlMask != 0, .alt = state & c.Mod1Mask != 0 };
}
