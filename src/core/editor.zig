//! Editor: the input state machine. Turns input events into document changes,
//! tool/color/size state, an in-progress preview, and commands (save, copy,
//! quit) for the app to run. It never draws and never does IO.
const std = @import("std");
const geom = @import("geom.zig");
const input = @import("input.zig");
const keymap = @import("keymap.zig");
const style = @import("style.zig");
const color = @import("color.zig");
const ann = @import("annotation.zig");
const Document = @import("document.zig").Document;
const View = @import("view.zig").View;
const Dock = @import("dock.zig").Dock;

const Vec2 = geom.Vec2;
const Tool = keymap.Tool;
const Annotation = ann.Annotation;

pub const Command = enum { save, copy, quit };

pub const Effect = struct {
    redraw: bool = false,
    command: ?Command = null,
};

/// Screen distance under which a press-release counts as a click.
const click_slop = 4;

const Drag = struct {
    tool: Tool,
    start: Vec2, // image px
    cur: Vec2, // image px
    start_screen: Vec2,
    cur_screen: Vec2,
};

const Typing = struct {
    kind: enum { text, callout },
    /// text: top-left of the block; callout: box anchor. Image px.
    pos: Vec2,
    target: ?Vec2 = null,
};

pub const Mode = union(enum) {
    idle,
    drag: Drag,
    typing: Typing,
};

pub const Editor = struct {
    gpa: std.mem.Allocator,
    doc: *Document,
    view: View,
    tool: Tool = .arrow,
    /// Tool to go back to after a crop.
    tool_before_crop: Tool = .arrow,
    color_idx: u8 = 0,
    size_idx: u8 = style.default_size,
    /// The shortcut overlay (`?`/F1).
    help_visible: bool = false,
    /// The icon dock (Space hides it to see the bottom of the image).
    dock_visible: bool = true,
    mode: Mode = .idle,
    draft: std.ArrayList(u8) = .empty,
    quit_armed: bool = false,
    saved_revision: u64 = 0,
    toast_buf: [256]u8 = undefined,
    toast_len: usize = 0,
    hint_buf: [96]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator, doc: *Document, view: View) Editor {
        return .{ .gpa = gpa, .doc = doc, .view = view, .saved_revision = doc.revision };
    }

    pub fn deinit(self: *Editor) void {
        self.draft.deinit(self.gpa);
    }

    pub fn currentColor(self: *const Editor) color.Color {
        return color.palette[self.color_idx].color;
    }

    /// Screen px to image px, with the UI scale.
    fn toImg(self: *const Editor, screen_px_1080: f32) f32 {
        return screen_px_1080 * style.uiScale(self.view.screen_h) / self.view.xf.scale;
    }

    fn strokeImg(self: *const Editor) f32 {
        return self.toImg(style.sizes[self.size_idx].stroke);
    }

    fn fontImg(self: *const Editor) f32 {
        return self.toImg(style.sizes[self.size_idx].font);
    }

    pub fn dirty(self: *const Editor) bool {
        return self.doc.revision != self.saved_revision;
    }

    pub fn markSaved(self: *Editor) void {
        self.saved_revision = self.doc.revision;
    }

    pub fn setToast(self: *Editor, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.toast_buf, fmt, args) catch blk: {
            @memcpy(self.toast_buf[self.toast_buf.len - 3 ..], "...");
            break :blk self.toast_buf[0..];
        };
        self.toast_len = s.len;
    }

    pub fn toast(self: *const Editor) ?[]const u8 {
        if (self.toast_len > 0) return self.toast_buf[0..self.toast_len];
        if (self.cropRect()) |r| return std.fmt.bufPrint(@constCast(&self.hint_buf), "Crop to {d} x {d} px. Release to crop, Esc to cancel.", .{ r.width(), r.height() }) catch null;
        if (self.mode == .typing) return "Type. Enter or Esc: done. Shift+Enter: new line.";
        return null;
    }

    pub fn resize(self: *Editor, w: u32, h: u32) void {
        self.view = View.fitRect(self.view.image_w, self.view.image_h, self.view.src, w, h);
    }

    /// Refit the view when the document crop changed (crop, undo, redo).
    fn syncView(self: *Editor) bool {
        const want = self.doc.visible(self.view.image_w, self.view.image_h);
        if (std.meta.eql(want, self.view.src)) return false;
        self.view = View.fitRect(self.view.image_w, self.view.image_h, want, self.view.screen_w, self.view.screen_h);
        return true;
    }

    /// Image rectangle a crop drag selects: whole pixels, inside the kept part.
    fn cropRectOf(self: *const Editor, a: Vec2, b: Vec2) geom.Rect {
        const lo = a.min(b);
        const hi = a.max(b);
        const r = geom.Rect{
            .x0 = @intFromFloat(@round(lo.x)),
            .y0 = @intFromFloat(@round(lo.y)),
            .x1 = @intFromFloat(@round(hi.x)),
            .y1 = @intFromFloat(@round(hi.y)),
        };
        return r.intersect(self.view.src);
    }

    /// The crop in progress, in image pixels.
    pub fn cropRect(self: *const Editor) ?geom.Rect {
        if (self.mode != .drag or self.mode.drag.tool != .crop) return null;
        return self.cropRectOf(self.mode.drag.start, self.mode.drag.cur);
    }

    /// The crop in progress on screen: the compositor dims everything outside.
    pub fn cropPreview(self: *const Editor) ?geom.Rect {
        const r = self.cropRect() orelse return null;
        const b = r.toBounds();
        return (geom.Bounds{ .min = self.view.toScreen(b.min), .max = self.view.toScreen(b.max) }).toRect();
    }

    /// The shape in progress, for drawing. Borrows the draft text.
    pub fn preview(self: *const Editor) ?Annotation {
        const c = self.currentColor();
        return switch (self.mode) {
            .idle => null,
            .drag => |d| self.shapeFromDrag(d),
            .typing => |t| switch (t.kind) {
                .text => .{ .text = .{ .pos = t.pos, .text = self.draft.items, .size = self.fontImg(), .color = c } },
                .callout => .{ .callout = .{ .target = t.target, .anchor = t.pos, .text = self.draft.items, .size = self.fontImg(), .color = c } },
            },
        };
    }

    fn shapeFromDrag(self: *const Editor, d: Drag) ?Annotation {
        const c = self.currentColor();
        return switch (d.tool) {
            .arrow => .{ .arrow = .{ .tail = d.start, .head = d.cur, .width = self.strokeImg(), .color = c } },
            .rect => .{ .rect = .{ .a = d.start, .b = d.cur, .width = self.strokeImg(), .color = c } },
            .highlight => .{ .highlight = .{ .a = d.start, .b = d.cur, .color = c } },
            .pixelate => .{ .pixelate = .{ .a = d.start, .b = d.cur, .block = self.toImg(style.pixelate_block) } },
            .callout => .{ .callout = .{ .target = d.start, .anchor = d.cur, .text = "", .size = self.fontImg(), .color = c } },
            .text, .number, .crop => null,
        };
    }

    pub fn handle(self: *Editor, ev: input.Event) !Effect {
        var eff = try self.handleEvent(ev);
        if (self.syncView()) eff.redraw = true;
        return eff;
    }

    fn handleEvent(self: *Editor, ev: input.Event) !Effect {
        switch (ev) {
            .key, .mouse_down => {
                // Any deliberate input hides the toast and disarms quit.
                const was_armed = self.quit_armed;
                self.quit_armed = false;
                const had_toast = self.toast_len > 0;
                self.toast_len = 0;
                var eff = if (ev == .key) try self.onKey(ev.key, was_armed) else try self.onDown(ev.mouse_down.x, ev.mouse_down.y, ev.mouse_down.button);
                eff.redraw = eff.redraw or had_toast or was_armed;
                return eff;
            },
            .mouse_up => |m| return self.onUp(m.x, m.y, m.button),
            .mouse_move => |m| {
                if (self.mode == .drag) {
                    const p = Vec2.init(m.x, m.y);
                    self.mode.drag.cur_screen = p;
                    self.mode.drag.cur = self.view.toImage(p);
                    return .{ .redraw = true };
                }
                return .{};
            },
            .wheel => |n| {
                self.changeSize(n);
                return .{ .redraw = true };
            },
            .resize => |r| {
                self.resize(r.w, r.h);
                return .{ .redraw = true };
            },
        }
    }

    fn changeSize(self: *Editor, delta: i32) void {
        const n: i32 = @intCast(style.sizes.len);
        self.size_idx = @intCast(std.math.clamp(@as(i32, self.size_idx) + delta, 0, n - 1));
    }

    fn onDown(self: *Editor, x: f32, y: f32, button: input.Button) !Effect {
        if (self.help_visible) { // any click closes the help
            self.help_visible = false;
            return .{ .redraw = true };
        }
        if (self.mode != .drag and self.dock_visible) {
            const d = Dock.of(self.view.screen_w, self.view.screen_h);
            if (d.contains(.{ .x = x, .y = y })) {
                if (button == .left) if (d.hit(.{ .x = x, .y = y })) |h| switch (h) {
                    .tool => |t| try self.setTool(t),
                    .color => |i| self.color_idx = i,
                    .size => self.size_idx = @intCast((@as(usize, self.size_idx) + 1) % style.sizes.len),
                    .help => self.help_visible = true,
                };
                return .{ .redraw = true };
            }
        }
        if (button == .right) {
            self.cancel();
            return .{ .redraw = true };
        }
        if (button != .left) return .{};
        if (self.mode == .typing) try self.commitTyping();
        if (self.mode == .drag) self.mode = .idle; // lost release: start over
        const sp = Vec2.init(x, y);
        const ip = self.view.toImage(sp);
        switch (self.tool) {
            .number => {
                try self.doc.add(self.gpa, .{ .number = .{ .center = ip, .value = self.doc.nextNumber(), .size = self.fontImg(), .color = self.currentColor() } });
            },
            .text => self.startTyping(.{ .kind = .text, .pos = ip.sub(.{ .x = 0, .y = self.fontImg() * 0.5 }) }),
            else => self.mode = .{ .drag = .{ .tool = self.tool, .start = ip, .cur = ip, .start_screen = sp, .cur_screen = sp } },
        }
        return .{ .redraw = true };
    }

    fn onUp(self: *Editor, x: f32, y: f32, button: input.Button) !Effect {
        if (button != .left or self.mode != .drag) return .{};
        const d = self.mode.drag;
        const sp = Vec2.init(x, y);
        const ip = self.view.toImage(sp);
        self.mode = .idle;
        const is_click = sp.dist(d.start_screen) < click_slop;
        if (d.tool == .callout) {
            self.startTyping(.{ .kind = .callout, .pos = ip, .target = if (is_click) null else d.start });
            return .{ .redraw = true };
        }
        if (is_click) return .{ .redraw = true };
        if (d.tool == .crop) {
            const r = self.cropRectOf(d.start, ip);
            if (!r.isEmpty()) {
                try self.doc.setCrop(self.gpa, r);
                self.tool = self.tool_before_crop;
            }
            return .{ .redraw = true };
        }
        var fin = d;
        fin.cur = ip;
        if (self.shapeFromDrag(fin)) |a| try self.doc.add(self.gpa, a);
        return .{ .redraw = true };
    }

    fn startTyping(self: *Editor, t: Typing) void {
        self.draft.clearRetainingCapacity();
        self.mode = .{ .typing = t };
    }

    /// Drop any shape or text in progress.
    pub fn cancel(self: *Editor) void {
        self.draft.clearRetainingCapacity();
        self.mode = .idle;
    }

    /// Turn the text in progress into an annotation (nothing if blank).
    pub fn commitTyping(self: *Editor) !void {
        if (self.mode != .typing) return;
        defer self.cancel();
        if (std.mem.trim(u8, self.draft.items, " \t\n").len == 0) return;
        var a = self.preview().?;
        const owned = try self.gpa.dupe(u8, self.draft.items);
        errdefer self.gpa.free(owned);
        switch (a) {
            .text => |*t| t.text = owned,
            .callout => |*c| c.text = owned,
            else => unreachable,
        }
        try self.doc.add(self.gpa, a);
    }

    fn onKey(self: *Editor, k: input.KeyEvent, was_armed: bool) !Effect {
        if (self.mode == .typing and !k.mods.ctrl and !k.mods.alt) {
            switch (k.key) {
                .char => |cp| {
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch return .{};
                    try self.draft.appendSlice(self.gpa, buf[0..n]);
                    return .{ .redraw = true };
                },
                .named => |n| switch (n) {
                    .tab => {}, // not text: falls through to the key map (finish, next tool)
                    .enter => {
                        if (k.mods.shift) try self.draft.append(self.gpa, '\n') else try self.commitTyping();
                        return .{ .redraw = true };
                    },
                    .escape => {
                        try self.commitTyping();
                        return .{ .redraw = true };
                    },
                    .backspace => {
                        const s = self.draft.items;
                        var i = s.len;
                        while (i > 0) {
                            i -= 1;
                            if (s[i] & 0xc0 != 0x80) break; // start of a UTF-8 sequence
                        }
                        self.draft.shrinkRetainingCapacity(i);
                        return .{ .redraw = true };
                    },
                    else => return .{},
                },
            }
        }
        if (k.key == .named and k.key.named == .escape) {
            if (self.mode == .drag) {
                self.cancel();
                return .{ .redraw = true };
            }
            if (self.help_visible) {
                self.help_visible = false;
                return .{ .redraw = true };
            }
        }
        const action = keymap.lookup(k) orelse return .{};
        return self.run(action, was_armed);
    }

    /// Finish any text in progress, drop any shape in progress, switch tool.
    fn setTool(self: *Editor, t: Tool) !void {
        try self.commitTyping();
        self.cancel();
        if (t == .crop and self.tool != .crop) self.tool_before_crop = self.tool;
        self.tool = t;
    }

    fn run(self: *Editor, action: keymap.Action, was_armed: bool) !Effect {
        switch (action) {
            .tool => |t| try self.setTool(t),
            .next_tool => try self.setTool(keymap.cycleTool(self.tool, 1)),
            .prev_tool => try self.setTool(keymap.cycleTool(self.tool, -1)),
            .color => |i| self.color_idx = i,
            .size_up => self.changeSize(1),
            .size_down => self.changeSize(-1),
            .undo => {
                if (self.mode != .idle) self.cancel() else _ = try self.doc.undo(self.gpa);
            },
            .redo => {
                self.cancel();
                _ = try self.doc.redo(self.gpa);
            },
            .save, .copy => {
                try self.commitTyping();
                return .{ .redraw = true, .command = if (action == .save) .save else .copy };
            },
            .quit => {
                if (!self.dirty() or was_armed) return .{ .command = .quit };
                self.quit_armed = true;
                self.setToast("Unsaved changes. Esc again to quit, Ctrl+S to save, Ctrl+C to copy.", .{});
            },
            .toggle_help => self.help_visible = !self.help_visible,
            .toggle_dock => self.dock_visible = !self.dock_visible,
        }
        return .{ .redraw = true };
    }
};

// ---- tests -------------------------------------------------------------

const T = struct {
    doc: Document = .{},
    ed: Editor = undefined,

    fn init(self: *T) void {
        self.ed = Editor.init(std.testing.allocator, &self.doc, View.fit(200, 100, 200, 100));
    }
    fn deinit(self: *T) void {
        self.ed.deinit();
        self.doc.deinit(std.testing.allocator);
    }
    fn key(self: *T, chord: []const u8) !Effect {
        return self.ed.handle(.{ .key = try input.parseChord(chord) });
    }
    fn drag(self: *T, x0: f32, y0: f32, x1: f32, y1: f32) !void {
        _ = try self.ed.handle(.{ .mouse_down = .{ .x = x0, .y = y0 } });
        _ = try self.ed.handle(.{ .mouse_move = .{ .x = x1, .y = y1 } });
        _ = try self.ed.handle(.{ .mouse_up = .{ .x = x1, .y = y1 } });
    }
};

test "arrow drag adds one arrow; a click adds nothing" {
    var t = T{};
    t.init();
    defer t.deinit();
    try t.drag(10, 10, 50, 40);
    try t.drag(10, 10, 11, 10);
    try std.testing.expectEqual(@as(usize, 1), t.doc.items.items.len);
    try std.testing.expectEqual(Vec2.init(50, 40), t.doc.items.items[0].arrow.head);
}

test "numbers count up and undo takes them back" {
    var t = T{};
    t.init();
    defer t.deinit();
    _ = try t.key("n");
    for (0..3) |_| _ = try t.ed.handle(.{ .mouse_down = .{ .x = 5, .y = 5 } });
    _ = try t.key("ctrl+z");
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 5, .y = 5 } });
    try std.testing.expectEqual(@as(u32, 3), t.doc.items.items[2].number.value);
}

test "typing text, backspace, enter commits; digits are text" {
    var t = T{};
    t.init();
    defer t.deinit();
    _ = try t.key("t");
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 5, .y = 50 } });
    for ("ab1x") |c| _ = try t.key(&[_]u8{c});
    _ = try t.key("backspace");
    _ = try t.key("enter");
    try std.testing.expectEqualStrings("ab1", t.doc.items.items[0].text.text);
    try std.testing.expectEqual(@as(u8, 0), t.ed.color_idx);
}

test "quit asks once when dirty" {
    var t = T{};
    t.init();
    defer t.deinit();
    try std.testing.expectEqual(Command.quit, (try t.key("esc")).command.?);
    try t.drag(10, 10, 50, 40);
    try std.testing.expectEqual(@as(?Command, null), (try t.key("esc")).command);
    try std.testing.expectEqual(Command.quit, (try t.key("esc")).command.?);
}

test "tab cycles tools; tab while typing commits first" {
    var t = T{};
    t.init();
    defer t.deinit();
    _ = try t.key("tab");
    try std.testing.expectEqual(keymap.cycleTool(.arrow, 1), t.ed.tool);
    _ = try t.key("shift+tab");
    _ = try t.key("shift+tab");
    try std.testing.expectEqual(keymap.cycleTool(.arrow, -1), t.ed.tool);
    _ = try t.key("t");
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 5, .y = 50 } });
    _ = try t.key("x");
    _ = try t.key("tab");
    try std.testing.expectEqualStrings("x", t.doc.items.items[0].text.text);
    try std.testing.expectEqual(keymap.cycleTool(.text, 1), t.ed.tool);
    try std.testing.expect(t.ed.mode == .idle);
}

test "crop drag crops, refits the view, goes back to the tool; undo restores" {
    var t = T{};
    t.init();
    defer t.deinit();
    _ = try t.key("r");
    _ = try t.key("x");
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 20, .y = 10 } });
    _ = try t.ed.handle(.{ .mouse_move = .{ .x = 120, .y = 60 } });
    try std.testing.expectEqual(geom.Rect{ .x0 = 20, .y0 = 10, .x1 = 120, .y1 = 60 }, t.ed.cropPreview().?);
    try std.testing.expect(t.ed.toast() != null);
    _ = try t.ed.handle(.{ .mouse_up = .{ .x = 120, .y = 60 } });
    try std.testing.expectEqual(geom.Rect{ .x0 = 20, .y0 = 10, .x1 = 120, .y1 = 60 }, t.doc.crop.?);
    try std.testing.expectEqual(geom.Rect{ .x0 = 20, .y0 = 10, .x1 = 120, .y1 = 60 }, t.ed.view.src);
    try std.testing.expectEqual(Tool.rect, t.ed.tool);
    // Screen (50, 25) is the image point (20, 10) after the refit (centered 1:1).
    try std.testing.expectEqual(Vec2.init(20, 10), t.ed.view.toImage(.{ .x = 50, .y = 25 }));
    _ = try t.key("ctrl+z");
    try std.testing.expectEqual(@as(u32, 200), @as(u32, @intCast(t.ed.view.src.width())));
    _ = try t.key("ctrl+y");
    try std.testing.expectEqual(@as(u32, 100), @as(u32, @intCast(t.ed.view.src.width())));
}

test "dock clicks pick tools and colors and never draw; help closes on click and Esc" {
    var t = T{};
    t.init();
    defer t.deinit();
    t.ed.resize(1920, 1080);
    const d = Dock.of(1920, 1080);
    const tb = d.tools[2];
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = (tb.min.x + tb.max.x) / 2, .y = (tb.min.y + tb.max.y) / 2 } });
    _ = try t.ed.handle(.{ .mouse_up = .{ .x = (tb.min.x + tb.max.x) / 2, .y = (tb.min.y + tb.max.y) / 2 } });
    try std.testing.expectEqual(keymap.tools[2].tool, t.ed.tool);
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = d.swatches[4].x, .y = d.swatches[4].y } });
    try std.testing.expectEqual(@as(u8, 4), t.ed.color_idx);
    try std.testing.expectEqual(@as(usize, 0), t.doc.items.items.len);
    _ = try t.key("?");
    try std.testing.expect(t.ed.help_visible);
    _ = try t.key("esc");
    try std.testing.expect(!t.ed.help_visible);
    _ = try t.key("f1");
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 10, .y = 10 } });
    try std.testing.expect(!t.ed.help_visible);
    try std.testing.expect(t.ed.mode == .idle);
    // Hidden dock: a click there draws.
    _ = try t.key("space");
    try t.drag(d.panel.min.x + 2, d.panel.min.y + 2, d.panel.max.x - 2, d.panel.max.y - 2);
    try std.testing.expectEqual(@as(usize, 1), t.doc.items.items.len);
}

test "callout drag then type" {
    var t = T{};
    t.init();
    defer t.deinit();
    _ = try t.key("c");
    try t.drag(10, 10, 80, 60);
    for ("Hi") |c| _ = try t.key(&[_]u8{c});
    _ = try t.key("enter");
    const c = t.doc.items.items[0].callout;
    try std.testing.expectEqualStrings("Hi", c.text);
    try std.testing.expectEqual(Vec2.init(10, 10), c.target.?);
}
