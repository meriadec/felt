//! The pointer shapes of the editor window: a crosshair, a move cross, an
//! open and a closed hand. Taken from the user's cursor theme through
//! libXcursor (loaded when the window opens, no build-time dependency);
//! the core X font cursors stand in when it or a name is missing.
const std = @import("std");
const xlib = @import("xlib.zig");
const core = @import("core");

const c = xlib.c;
const Kind = core.editor.Editor.Cursor;

const LoadFn = *const fn (*c.Display, [*:0]const u8) callconv(.c) c.Cursor;

pub const Cursors = struct {
    dpy: *c.Display,
    load: ?LoadFn,
    cache: [4]c.Cursor = .{ 0, 0, 0, 0 },

    pub fn init(dpy: *c.Display) Cursors {
        var lib = std.DynLib.open("libXcursor.so.1") catch null;
        const load: ?LoadFn = if (lib) |*l| l.lookup(LoadFn, "XcursorLibraryLoadCursor") else null;
        // The library stays loaded: libX11 calls back into it from XCloseDisplay.
        return .{ .dpy = dpy, .load = load };
    }

    /// The cursor for `kind`, made on first use.
    pub fn get(self: *Cursors, kind: Kind) c.Cursor {
        const i = @backingInt(kind);
        if (self.cache[i] == 0) self.cache[i] = self.make(kind);
        return self.cache[i];
    }

    fn make(self: *Cursors, kind: Kind) c.Cursor {
        const names: []const [:0]const u8 = switch (kind) {
            .crosshair => &.{"crosshair"},
            .move => &.{ "move", "fleur", "all-scroll" },
            .grab => &.{ "grab", "openhand", "hand1" },
            .grabbing => &.{ "grabbing", "closedhand", "dnd-none" },
        };
        if (self.load) |load| for (names) |n| {
            const cur = load(self.dpy, n.ptr);
            if (cur != 0) return cur;
        };
        const font: c_uint = switch (kind) {
            .crosshair => xlib.xc_crosshair,
            .move, .grabbing => 52, // XC_fleur
            .grab => 58, // XC_hand1
        };
        return c.XCreateFontCursor(self.dpy, font);
    }
};
