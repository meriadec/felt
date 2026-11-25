//! Capture picker: the state machine of `felt --capture`, with no window
//! system. The user drags a rectangle (confirmed on release) or clicks to
//! take the window under the pointer; Tab toggles the capture delay; Esc
//! cancels. The backend feeds `input.Event`s and the list of windows (a
//! snapshot, topmost first); it reads `phase` and `result` when it is done.
//! Drawing is in picker_draw.zig; `crop` cuts the result out of the frozen screen.
const std = @import("std");
const geom = @import("geom.zig");
const input = @import("input.zig");
const Canvas = @import("canvas.zig").Canvas;

const Rect = geom.Rect;
const Vec2 = geom.Vec2;

/// A press that moves less than this (px, each axis) is a click.
pub const drag_threshold = 4;
/// The delay Tab switches on when `--delay` gave none.
pub const default_delay_ms = 1000;

pub const Phase = enum {
    /// Pointer over no window, no button down.
    idle,
    /// Pointer over a window (`hover`), no button down.
    hover,
    /// Left button down: a drag (`moved`) or a click that may still come.
    dragging,
    /// Released: `result` is the rectangle to capture.
    confirmed,
    /// Esc or right click: capture nothing.
    cancelled,
};

pub const Effect = struct { redraw: bool = false };

pub const Picker = struct {
    w: u32,
    h: u32,
    /// Top-level windows in screen pixels, topmost first. Borrowed.
    windows: []const Rect = &.{},
    phase: Phase = .idle,
    pointer: Vec2 = .zero,
    /// A pointer event came in: `pointer` is real (the ruler shows it).
    seen: bool = false,
    press: Vec2 = .zero,
    /// The press moved past the drag threshold.
    moved: bool = false,
    /// Topmost window under the pointer.
    hover: ?Rect = null,
    /// Delay before the live grab, ms (0: crop the frozen picture).
    delay_ms: u32 = 0,
    /// What Tab switches the delay on to.
    on_ms: u32 = default_delay_ms,
    /// Set when `phase` is `.confirmed`; inside the screen, never empty.
    result: ?Rect = null,

    /// `delay_ms` is the initial delay; Tab switches between 0 and it
    /// (or `default_delay_ms` when it is 0).
    pub fn init(w: u32, h: u32, windows: []const Rect, delay_ms: u32) Picker {
        return .{ .w = w, .h = h, .windows = windows, .delay_ms = delay_ms, .on_ms = if (delay_ms > 0) delay_ms else default_delay_ms };
    }

    pub fn finished(self: *const Picker) bool {
        return self.phase == .confirmed or self.phase == .cancelled;
    }

    fn screen(self: *const Picker) Rect {
        return Rect.fromSize(0, 0, @intCast(self.w), @intCast(self.h));
    }

    /// The rectangle of the drag, from the press to the pointer, inside the screen.
    pub fn dragRect(self: *const Picker) Rect {
        const x0: i32 = @intFromFloat(@floor(@min(self.press.x, self.pointer.x)));
        const y0: i32 = @intFromFloat(@floor(@min(self.press.y, self.pointer.y)));
        const x1: i32 = @intFromFloat(@floor(@max(self.press.x, self.pointer.x)));
        const y1: i32 = @intFromFloat(@floor(@max(self.press.y, self.pointer.y)));
        return (Rect{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 }).intersect(self.screen());
    }

    /// The rectangle to light up and label: the drag, else the hovered window.
    pub fn highlight(self: *const Picker) ?Rect {
        return switch (self.phase) {
            .dragging => if (self.moved) self.dragRect() else self.hover,
            .confirmed => self.result,
            .hover => self.hover,
            else => null,
        };
    }

    fn windowAt(self: *const Picker, p: Vec2) ?Rect {
        const x: i32 = @intFromFloat(@floor(p.x));
        const y: i32 = @intFromFloat(@floor(p.y));
        for (self.windows) |win| {
            const r = win.intersect(self.screen());
            if (x >= r.x0 and x < r.x1 and y >= r.y0 and y < r.y1) return r;
        }
        return null;
    }

    fn setPointer(self: *Picker, p: Vec2) void {
        self.pointer = p;
        self.seen = true;
        self.hover = self.windowAt(p);
        if (self.phase == .idle or self.phase == .hover) self.phase = if (self.hover != null) .hover else .idle;
        if (self.phase == .dragging and !self.moved) {
            self.moved = @abs(p.x - self.press.x) >= drag_threshold or @abs(p.y - self.press.y) >= drag_threshold;
        }
    }

    pub fn delayOn(self: *const Picker) bool {
        return self.delay_ms > 0;
    }

    pub fn handle(self: *Picker, ev: input.Event) Effect {
        if (self.finished()) return .{};
        switch (ev) {
            .mouse_move => |p| {
                self.setPointer(.{ .x = p.x, .y = p.y });
                return .{ .redraw = true };
            },
            .mouse_down => |m| {
                if (m.button == .right) {
                    self.phase = .cancelled;
                    return .{ .redraw = true };
                }
                if (m.button != .left) return .{};
                self.setPointer(.{ .x = m.x, .y = m.y });
                self.press = self.pointer;
                self.moved = false;
                self.phase = .dragging;
                return .{ .redraw = true };
            },
            .mouse_up => |m| {
                if (m.button != .left or self.phase != .dragging) return .{};
                self.setPointer(.{ .x = m.x, .y = m.y });
                const r = if (self.moved) self.dragRect() else (self.hover orelse Rect.empty);
                if (r.isEmpty()) {
                    self.phase = if (self.hover != null) .hover else .idle;
                } else {
                    self.result = r;
                    self.phase = .confirmed;
                }
                return .{ .redraw = true };
            },
            .key => |k| switch (k.key) {
                .named => |n| switch (n) {
                    .escape => {
                        self.phase = .cancelled;
                        return .{ .redraw = true };
                    },
                    .tab => {
                        self.delay_ms = if (self.delay_ms > 0) 0 else self.on_ms;
                        return .{ .redraw = true };
                    },
                    else => {},
                },
                else => {},
            },
            else => {},
        }
        return .{};
    }
};

/// The delay indicator text: "delay 1s: on", "delay 0.5s: on", "delay: off".
pub fn delayLabel(buf: []u8, delay_ms: u32) []const u8 {
    if (delay_ms == 0) return "delay: off";
    const r = if (delay_ms % 1000 == 0)
        std.fmt.bufPrint(buf, "delay {d}s: on", .{delay_ms / 1000})
    else
        std.fmt.bufPrint(buf, "delay {d:.1}s: on", .{@as(f32, @floatFromInt(delay_ms)) / 1000});
    return r catch "delay: on";
}

/// The size label of a rectangle: "812x430".
pub fn sizeLabel(buf: []u8, r: Rect) []const u8 {
    return std.fmt.bufPrint(buf, "{d}x{d}", .{ r.width(), r.height() }) catch "";
}

/// The part `r` of the frozen screen as a new canvas, made opaque (an X
/// root grab leaves the alpha byte undefined). Caller owns it.
pub fn crop(gpa: std.mem.Allocator, frozen: *const Canvas, r: Rect) !Canvas {
    const cv = try frozen.copyOut(gpa, r.intersect(frozen.bounds()));
    for (cv.pixels) |*p| p.* |= 0xff000000;
    return cv;
}

fn mev(comptime tag: []const u8, x: f32, y: f32) input.Event {
    return @unionInit(input.Event, tag, .{ .x = x, .y = y });
}

const test_windows = [_]Rect{ Rect.fromSize(100, 100, 200, 150), Rect.fromSize(0, 0, 400, 300) };

test "a drag confirms on release, normalized and clipped" {
    var p = Picker.init(400, 300, &.{}, 0);
    _ = p.handle(mev("mouse_down", 150.5, 90));
    try std.testing.expectEqual(Phase.dragging, p.phase);
    _ = p.handle(mev("mouse_move", 152, 91));
    try std.testing.expect(!p.moved); // under the threshold
    _ = p.handle(mev("mouse_move", 50, 400));
    try std.testing.expectEqual(Rect{ .x0 = 50, .y0 = 90, .x1 = 150, .y1 = 300 }, p.highlight().?);
    _ = p.handle(mev("mouse_up", 50, 400));
    try std.testing.expectEqual(Phase.confirmed, p.phase);
    try std.testing.expectEqual(Rect{ .x0 = 50, .y0 = 90, .x1 = 150, .y1 = 300 }, p.result.?);
    try std.testing.expect(p.finished());
    // Finished: later events change nothing.
    _ = p.handle(.{ .key = .{ .key = .{ .named = .escape } } });
    try std.testing.expectEqual(Phase.confirmed, p.phase);
}

test "hover follows the topmost window; a click selects it" {
    var p = Picker.init(400, 300, &test_windows, 0);
    _ = p.handle(mev("mouse_move", 150, 150));
    try std.testing.expectEqual(Phase.hover, p.phase);
    try std.testing.expectEqual(test_windows[0], p.hover.?);
    _ = p.handle(mev("mouse_move", 20, 20));
    try std.testing.expectEqual(test_windows[1], p.hover.?);
    _ = p.handle(mev("mouse_move", 150, 150));
    _ = p.handle(mev("mouse_down", 150, 150));
    try std.testing.expectEqual(test_windows[0], p.highlight().?); // still the window
    _ = p.handle(mev("mouse_up", 151, 151));
    try std.testing.expectEqual(Phase.confirmed, p.phase);
    try std.testing.expectEqual(test_windows[0], p.result.?);
}

test "a click over no window selects nothing" {
    var p = Picker.init(400, 300, &.{}, 0);
    _ = p.handle(mev("mouse_move", 10, 10));
    try std.testing.expectEqual(Phase.idle, p.phase);
    _ = p.handle(mev("mouse_down", 10, 10));
    _ = p.handle(mev("mouse_up", 10, 10));
    try std.testing.expectEqual(Phase.idle, p.phase);
    try std.testing.expectEqual(@as(?Rect, null), p.result);
}

test "a window is clipped to the screen" {
    const wins = [_]Rect{Rect.fromSize(-20, 250, 100, 100)};
    var p = Picker.init(400, 300, &wins, 0);
    _ = p.handle(mev("mouse_down", 10, 260));
    _ = p.handle(mev("mouse_up", 10, 260));
    try std.testing.expectEqual(Rect{ .x0 = 0, .y0 = 250, .x1 = 80, .y1 = 300 }, p.result.?);
}

test "esc and right click cancel" {
    var p = Picker.init(400, 300, &.{}, 0);
    _ = p.handle(.{ .key = .{ .key = .{ .named = .escape } } });
    try std.testing.expectEqual(Phase.cancelled, p.phase);
    var q = Picker.init(400, 300, &.{}, 0);
    _ = q.handle(.{ .mouse_down = .{ .x = 1, .y = 1, .button = .right } });
    try std.testing.expectEqual(Phase.cancelled, q.phase);
    try std.testing.expectEqual(@as(?Rect, null), q.result);
}

test "tab toggles the delay between 0 and 1 s, or the --delay value" {
    const tab = input.Event{ .key = .{ .key = .{ .named = .tab } } };
    var p = Picker.init(400, 300, &.{}, 0);
    try std.testing.expect(!p.delayOn());
    _ = p.handle(tab);
    try std.testing.expectEqual(@as(u32, 1000), p.delay_ms);
    _ = p.handle(tab);
    try std.testing.expectEqual(@as(u32, 0), p.delay_ms);
    var q = Picker.init(400, 300, &.{}, 2500);
    try std.testing.expect(q.delayOn());
    _ = q.handle(tab);
    try std.testing.expectEqual(@as(u32, 0), q.delay_ms);
    _ = q.handle(tab);
    try std.testing.expectEqual(@as(u32, 2500), q.delay_ms);
}

test "labels" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("delay 1s: on", delayLabel(&buf, 1000));
    try std.testing.expectEqualStrings("delay 2.5s: on", delayLabel(&buf, 2500));
    try std.testing.expectEqualStrings("delay: off", delayLabel(&buf, 0));
    try std.testing.expectEqualStrings("812x430", sizeLabel(&buf, Rect.fromSize(5, 5, 812, 430)));
}

test "crop is opaque and has the size of the rectangle" {
    const gpa = std.testing.allocator;
    var cv = try Canvas.init(gpa, 20, 10);
    defer cv.deinit(gpa);
    @memset(cv.pixels, 0x00123456);
    var c = try crop(gpa, &cv, Rect.fromSize(5, 2, 7, 4));
    defer c.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 7), c.width);
    try std.testing.expectEqual(@as(u32, 4), c.height);
    try std.testing.expectEqual(@as(u32, 0xff123456), c.at(3, 3));
}
