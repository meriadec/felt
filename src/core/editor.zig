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
const extent = @import("extent.zig");
const draw = @import("draw.zig");
const route = @import("route.zig");
const Document = @import("document.zig").Document;
const View = @import("view.zig").View;
const Font = @import("font.zig").Font;
const Dock = @import("dock.zig").Dock;
const TopBar = @import("topbar.zig").TopBar;
const Hover = @import("chrome.zig").Hover;
const Settings = @import("settings.zig").Settings;

const Vec2 = geom.Vec2;
const Tool = keymap.Tool;
const Annotation = ann.Annotation;
const Part = ann.Part;

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

/// An annotation part under the pointer (move tool).
pub const Grab = struct { index: usize, part: Part };

/// A move in progress: the document holds the live geometry, `before`
/// the geometry to restore on cancel and to record for undo.
const Moving = struct {
    grab: Grab,
    before: Annotation,
    /// Image px under the pointer at the press.
    start: Vec2,
};

pub const Mode = union(enum) {
    idle,
    drag: Drag,
    typing: Typing,
    moving: Moving,
};

/// Screen distance (px at 1080p) within which the pointer grabs a shape.
const grab_tolerance = 5;
/// Screen radius (px at 1080p) of an arrow end or callout tip handle.
const handle_radius = 9;

pub const Editor = struct {
    gpa: std.mem.Allocator,
    /// Measures text for the canvas extent; the editor never draws.
    font: *Font,
    doc: *Document,
    image_w: u32,
    image_h: u32,
    view: View,
    /// Canvas of the document (image px, see extent.zig), for `canvas_rev`.
    canvas: geom.Rect,
    canvas_rev: u64,
    /// Kept rectangle the view was fitted for: a crop, its undo or redo refits.
    kept_key: geom.Rect,
    /// The view fits the canvas (no zoom or pan since): a resize refits.
    fitted: bool = true,
    /// Middle-button pan in progress: last pointer position.
    panning: ?Vec2 = null,
    tool: Tool = .arrow,
    /// Tool to go back to after a crop.
    tool_before_crop: Tool = .arrow,
    color_idx: u8 = 0,
    size_idx: u8 = style.default_size,
    /// Style of new arrows and callout pointers (one setting for both). It
    /// stays for the session, across tool switches.
    arrow_style: ann.ArrowStyle = .straight,
    /// User settings (settings.zig): not document state, not undo steps.
    settings: Settings = .{},
    /// The shortcut overlay (`?`/F1).
    help_visible: bool = false,
    /// The icon dock and the top bar (Space hides both to see the image).
    dock_visible: bool = true,
    /// Last pointer position on screen (hover), null before the first move.
    pointer: ?Vec2 = null,
    /// Move tool: the annotation part under the pointer.
    hover: ?Grab = null,
    mode: Mode = .idle,
    draft: std.ArrayList(u8) = .empty,
    quit_armed: bool = false,
    saved_revision: u64 = 0,
    toast_buf: [256]u8 = undefined,
    toast_len: usize = 0,
    hint_buf: [96]u8 = undefined,

    /// Fit the canvas of `doc` over an image_w x image_h image to the screen.
    pub fn init(gpa: std.mem.Allocator, font: *Font, doc: *Document, image_w: u32, image_h: u32, screen_w: u32, screen_h: u32) Editor {
        const dctx = draw.Ctx{ .gpa = gpa, .font = font };
        const canvas = extent.canvas(dctx, doc, image_w, image_h);
        return .{
            .gpa = gpa,
            .font = font,
            .doc = doc,
            .image_w = image_w,
            .image_h = image_h,
            .view = View.fit(canvas, screen_w, screen_h),
            .canvas = canvas,
            .canvas_rev = doc.revision,
            .kept_key = doc.kept(image_w, image_h),
            .saved_revision = doc.revision,
        };
    }

    pub fn ctx(self: *const Editor) draw.Ctx {
        return .{ .gpa = self.gpa, .font = self.font };
    }

    pub fn deinit(self: *Editor) void {
        self.draft.deinit(self.gpa);
    }

    pub fn currentColor(self: *const Editor) color.Color {
        return color.palette[self.color_idx].color;
    }

    /// Screen px to image px, with the UI scale. Sizes follow the scale that
    /// fits the kept rectangle, not the zoom: a shape drawn zoomed out has
    /// the same image size as one drawn at the fit.
    fn toImg(self: *const Editor, screen_px_1080: f32) f32 {
        const ref = View.fit(self.kept_key, self.view.screen_w, self.view.screen_h).xf.scale;
        return screen_px_1080 * style.uiScale(self.view.screen_h) / ref;
    }

    fn strokeImg(self: *const Editor) f32 {
        return self.toImg(style.sizes[self.size_idx].stroke);
    }

    fn fontImg(self: *const Editor) f32 {
        return self.toImg(style.sizes[self.size_idx].font);
    }

    /// Ctrl+Z or the undo button does something.
    pub fn canUndo(self: *const Editor) bool {
        return self.mode != .idle or self.doc.history.items.len > 0;
    }

    pub fn canRedo(self: *const Editor) bool {
        return self.doc.undone.items.len > 0;
    }

    /// The dock or top bar item under the pointer (none during a drag).
    pub fn chromeHover(self: *const Editor) Hover {
        const p = self.pointer orelse return .{};
        if (!self.dock_visible or self.help_visible or self.mode == .drag or self.mode == .moving or self.panning != null) return .{};
        const w = self.view.screen_w;
        const h = self.view.screen_h;
        return .{ .dock = Dock.of(w, h, self.tool).hit(p), .bar = TopBar.of(w, h).hit(p) };
    }

    /// The annotation part a press at screen point `p` would move: the
    /// topmost shape within the grab tolerance, with its visible part (its
    /// clip) under the pointer. An arrow end or a callout tip wins over the body.
    pub fn grabAt(self: *const Editor, p: Vec2) ?Grab {
        if (self.onChrome(p)) return null;
        const ui = style.uiScale(self.view.screen_h);
        const tol = grab_tolerance * ui;
        const hr = handle_radius * ui;
        const xf = self.view.xf;
        const ip = self.view.toImage(p);
        const items = self.doc.items.items;
        var i = items.len;
        while (i > 0) {
            i -= 1;
            const a = items[i];
            const clip = extent.itemClip(self.ctx(), self.doc, self.image_w, self.image_h, i).toBounds();
            if (ip.x < clip.min.x or ip.y < clip.min.y or ip.x >= clip.max.x or ip.y >= clip.max.y) continue;
            switch (a) {
                .arrow => |ar| {
                    const t = xf.apply(ar.tail);
                    const h = xf.apply(ar.head);
                    // Ends only on an arrow long enough to keep a body to grab.
                    if (t.dist(h) > 4 * hr) {
                        if (p.dist(h) <= hr) return .{ .index = i, .part = .head };
                        if (p.dist(t) <= hr) return .{ .index = i, .part = .tail };
                    }
                },
                .callout => |c| if (c.target) |t| {
                    if (p.dist(xf.apply(t)) <= hr) return .{ .index = i, .part = .tip };
                },
                else => {},
            }
            if (self.bendHandle(a)) |b| if (p.dist(b) <= hr) return .{ .index = i, .part = .bend };
            if (draw.hitDist(self.ctx(), a, xf, p) <= tol) return .{ .index = i, .part = .whole };
        }
        return null;
    }

    /// The move tool's target to outline: the part under the pointer. None
    /// while it moves: the shape itself shows where it goes, and a frame
    /// then pays for one raster less (docs/perf.md).
    pub fn outlined(self: *const Editor) ?Grab {
        if (self.tool != .move or self.mode != .idle or self.help_visible) return null;
        const g = self.hover orelse return null;
        return if (g.index < self.doc.items.items.len) g else null;
    }

    fn updateHover(self: *Editor) bool {
        const before = self.hover;
        self.hover = if (self.tool == .move and self.mode == .idle and self.pointer != null) self.grabAt(self.pointer.?) else null;
        return !std.meta.eql(before, self.hover);
    }

    /// The bend handle of `a` on screen: the middle of the middle segment
    /// of its stairs path, when that segment is long enough to grab apart
    /// from the rest. Dragging it pins the elbow (`bentTo`).
    pub fn bendHandle(self: *const Editor, a: Annotation) ?Vec2 {
        const ar = draw.stairsArrow(a) orelse return null;
        const p = draw.stairsPlan(ar, self.view.xf) orelse return null;
        if (p.rt.rise < 3 * handle_radius * style.uiScale(self.view.screen_h)) return null;
        return p.rt.c1.add(p.rt.c2).scale(0.5);
    }

    /// `a` with the middle segment of its stairs path through image point
    /// `ip` (along the first axis, inside the room for full corners), its
    /// elbow pinned. Within a handle radius of the midpoint it snaps back
    /// to the default and auto-routes again.
    fn bentTo(self: *const Editor, a: Annotation, ip: Vec2) Annotation {
        const ar = draw.stairsArrow(a) orelse return a;
        const p = draw.stairsPlan(ar, .identity) orelse return a;
        const span = p.rt.span();
        const raw = ip.sub(p.rt.t).dot(p.rt.u) / span;
        const snap = handle_radius * style.uiScale(self.view.screen_h) / self.view.xf.scale;
        if (@abs(raw - 0.5) * span <= snap) return a.withElbow(.{});
        const r = draw.elbowRange(ar, p.flip) orelse [2]f32{ 0.5, 0.5 };
        return a.withElbow(.{ .at = std.math.clamp(raw, r[0], r[1]), .flip = p.flip, .pinned = true });
    }

    /// `a` (not in the document) with its stairs path routed around the
    /// annotations of the document (route.zig).
    fn routed(self: *const Editor, a: Annotation) Annotation {
        return route.best(self.ctx(), self.doc.items.items, null, a);
    }

    /// Move the grabbed part to follow the pointer at image point `ip`; a
    /// moved stairs path re-routes around the others, a dragged bend pins.
    /// A position that would hide the annotation (past the reach, or out of
    /// a later crop) is skipped: the annotation stays at the last good one.
    fn moveTo(self: *Editor, ip: Vec2) void {
        const m = self.mode.moving;
        const a = if (m.grab.part == .bend)
            self.bentTo(m.before, ip)
        else
            route.best(self.ctx(), self.doc.items.items, m.grab.index, m.before.moved(m.grab.part, ip.sub(m.start)));
        if (!extent.showsAs(self.ctx(), self.doc, self.image_w, self.image_h, m.grab.index, a)) return;
        if (std.meta.eql(a, self.doc.items.items[m.grab.index])) return;
        self.doc.setLive(m.grab.index, a);
    }

    /// Record the move in progress as one undo step, with the re-routes of
    /// the stairs paths around it.
    fn finishMove(self: *Editor) !void {
        const m = self.mode.moving;
        self.mode = .idle;
        const i = m.grab.index;
        if (std.meta.eql(m.before, self.doc.items.items[i])) return;
        var changed: [route.max_settle]route.Rerouted = undefined;
        const n = self.settle(i, m.before, &changed);
        const step = try self.doc.commitMove(self.gpa, i, m.before);
        try self.commitRerouted(changed[0..n], i, step);
        if (m.grab.part == .bend) {
            if (draw.stairsArrow(self.doc.items.items[i])) |ar| {
                if (ar.elbow.pinned) self.setToast("Bend pinned. Drag it back to the middle: auto again.", .{}) else self.setToast("Bend: auto", .{});
            }
        }
    }

    /// Re-route the auto stairs paths around annotation `i`, just added or
    /// changed (`before`: its geometry before a move). See route.settle.
    fn settle(self: *Editor, i: usize, before: ?Annotation, out: *[route.max_settle]route.Rerouted) usize {
        const items = self.doc.items.items;
        var region = draw.bodyBounds(self.ctx(), items[i], .identity).toBounds();
        if (before) |b| region = region.unite(draw.bodyBounds(self.ctx(), b, .identity).toBounds());
        return route.settle(self.ctx(), items, region, out);
    }

    /// Record re-routes as chained moves of the last step (`step`: the
    /// change recorded one); without a step the first re-route opens one.
    /// `skip`: an index the step already holds.
    fn commitRerouted(self: *Editor, changed: []const route.Rerouted, skip: ?usize, step: bool) !void {
        var open = step;
        for (changed) |c| {
            if (skip != null and skip.? == c.index) continue;
            if (open) {
                try self.doc.commitChained(self.gpa, c.index, c.before);
            } else open = try self.doc.commitMove(self.gpa, c.index, c.before);
        }
    }

    /// Add `a` as one undo step, with the re-routes of the stairs paths
    /// around it (its own included).
    fn addSettled(self: *Editor, a: Annotation) !void {
        try self.doc.add(self.gpa, a);
        try self.settleAdded();
    }

    /// Re-route the stairs paths around the annotation just added, as part
    /// of its step.
    fn settleAdded(self: *Editor) !void {
        var changed: [route.max_settle]route.Rerouted = undefined;
        const n = self.settle(self.doc.items.items.len - 1, null, &changed);
        try self.commitRerouted(changed[0..n], null, true);
    }

    /// The point is on the dock or the top bar: a click there never draws.
    pub fn onChrome(self: *const Editor, p: Vec2) bool {
        if (!self.dock_visible) return false;
        const w = self.view.screen_w;
        const h = self.view.screen_h;
        return Dock.of(w, h, self.tool).contains(p) or TopBar.of(w, h).contains(p);
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

    /// A fitted view refits; a zoomed or panned one keeps its transform.
    pub fn resize(self: *Editor, w: u32, h: u32) void {
        if (self.fitted) {
            self.view = View.fit(self.canvas, w, h);
        } else {
            self.view.screen_w = w;
            self.view.screen_h = h;
        }
    }

    fn fit(self: *Editor) void {
        self.view = View.fit(self.canvas, self.view.screen_w, self.view.screen_h);
        self.fitted = true;
    }

    /// Zoom `steps` levels about the screen point `p`.
    fn zoom(self: *Editor, steps: i32, p: Vec2) void {
        const s = @import("view.zig").zoomStep(self.view.xf.scale, steps);
        if (s != self.view.xf.scale) {
            self.view = self.view.zoomAt(s, p);
            self.fitted = false;
        }
        self.setToast("Zoom {d}%. 0: fit, middle drag: pan.", .{@as(u32, @intFromFloat(@round(self.view.xf.scale * 100)))});
    }

    fn pan(self: *Editor, dx: i32, dy: i32) void {
        self.view = self.view.panBy(dx, dy);
        self.fitted = false;
    }

    /// Follow document changes: recompute the canvas, and refit the view
    /// when the kept rectangle changed (crop, its undo or redo). A canvas
    /// that grows or shrinks with annotations keeps the view: no jumps.
    fn syncView(self: *Editor) bool {
        if (self.doc.revision == self.canvas_rev) return false;
        self.canvas_rev = self.doc.revision;
        self.canvas = extent.canvas(self.ctx(), self.doc, self.image_w, self.image_h);
        const kept = self.doc.kept(self.image_w, self.image_h);
        if (std.meta.eql(kept, self.kept_key)) return false;
        self.kept_key = kept;
        self.fit();
        return true;
    }

    /// Image rectangle a crop drag selects: whole pixels, inside the canvas
    /// (white areas included).
    fn cropRectOf(self: *const Editor, a: Vec2, b: Vec2) geom.Rect {
        const lo = a.min(b);
        const hi = a.max(b);
        const r = geom.Rect{
            .x0 = @intFromFloat(@round(lo.x)),
            .y0 = @intFromFloat(@round(lo.y)),
            .x1 = @intFromFloat(@round(hi.x)),
            .y1 = @intFromFloat(@round(hi.y)),
        };
        return r.intersect(self.canvas);
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
            .idle, .moving => null,
            .drag => |d| self.shapeFromDrag(d),
            .typing => |t| switch (t.kind) {
                .text => .{ .text = .{ .pos = t.pos, .text = self.draft.items, .size = self.fontImg(), .color = c } },
                .callout => self.routed(.{ .callout = .{ .target = t.target, .anchor = t.pos, .text = self.draft.items, .size = self.fontImg(), .color = c, .width = self.strokeImg(), .style = self.arrow_style } }),
            },
        };
    }

    fn shapeFromDrag(self: *const Editor, d: Drag) ?Annotation {
        const c = self.currentColor();
        return switch (d.tool) {
            .arrow => self.routed(.{ .arrow = .{ .tail = d.start, .head = d.cur, .width = self.strokeImg(), .color = c, .style = self.arrow_style } }),
            .rect => .{ .rect = .{ .a = d.start, .b = d.cur, .width = self.strokeImg(), .color = c } },
            .pixelate => .{ .pixelate = .{ .a = d.start, .b = d.cur, .block = self.toImg(style.pixelate_block) } },
            .callout => self.routed(.{ .callout = .{ .target = d.start, .anchor = d.cur, .text = "", .size = self.fontImg(), .color = c, .width = self.strokeImg(), .style = self.arrow_style } }),
            .text, .number, .move, .crop => null,
        };
    }

    pub fn handle(self: *Editor, ev: input.Event) !Effect {
        var eff = try self.handleEvent(ev);
        if (self.syncView()) eff.redraw = true;
        if (self.updateHover()) eff.redraw = true;
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
            .mouse_up => |m| {
                if (m.button == .middle) {
                    self.panning = null;
                    return .{};
                }
                return self.onUp(m.x, m.y, m.button);
            },
            .mouse_move => |m| {
                const hover_before = self.chromeHover().key();
                self.pointer = .{ .x = m.x, .y = m.y };
                if (self.panning) |last| {
                    const dx: i32 = @intFromFloat(@round(m.x - last.x));
                    const dy: i32 = @intFromFloat(@round(m.y - last.y));
                    self.panning = .{ .x = last.x + @as(f32, @floatFromInt(dx)), .y = last.y + @as(f32, @floatFromInt(dy)) };
                    if (dx == 0 and dy == 0) return .{};
                    self.pan(dx, dy);
                    return .{ .redraw = true };
                }
                if (self.mode == .drag) {
                    const p = Vec2.init(m.x, m.y);
                    self.mode.drag.cur_screen = p;
                    self.mode.drag.cur = self.view.toImage(p);
                    return .{ .redraw = true };
                }
                if (self.mode == .moving) {
                    self.moveTo(self.view.toImage(.{ .x = m.x, .y = m.y }));
                    return .{ .redraw = true };
                }
                return .{ .redraw = self.chromeHover().key() != hover_before };
            },
            .wheel => |wh| {
                if (wh.mods.ctrl) self.zoom(wh.delta, .{ .x = wh.x, .y = wh.y }) else self.changeSize(wh.delta);
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
        const p = Vec2.init(x, y);
        self.pointer = p;
        if (self.mode != .drag and self.mode != .moving and self.onChrome(p)) {
            if (button == .left) {
                if (Dock.of(self.view.screen_w, self.view.screen_h, self.tool).hit(p)) |h| switch (h) {
                    .tool => |t| try self.setTool(t),
                    .arrow_style => |st| self.setArrowStyle(st),
                    .color => |i| self.color_idx = i,
                    .size => self.size_idx = @intCast((@as(usize, self.size_idx) + 1) % style.sizes.len),
                    .help => self.help_visible = true,
                };
                if (TopBar.of(self.view.screen_w, self.view.screen_h).hit(p)) |b| switch (b) {
                    .undo => try self.undo(),
                    .redo => try self.redo(),
                };
            }
            return .{ .redraw = true };
        }
        if (button == .right) {
            self.cancel();
            return .{ .redraw = true };
        }
        if (button == .middle) {
            if (self.mode != .drag and self.mode != .moving) self.panning = .{ .x = x, .y = y };
            return .{};
        }
        if (button != .left) return .{};
        if (self.mode == .typing) try self.commitTyping();
        if (self.mode == .drag) self.mode = .idle; // lost release: start over
        if (self.mode == .moving) try self.finishMove(); // lost release: keep the move
        const sp = Vec2.init(x, y);
        const ip = self.view.toImage(sp);
        if (self.tool == .move) {
            if (self.grabAt(sp)) |g| self.mode = .{ .moving = .{ .grab = g, .before = self.doc.items.items[g.index], .start = ip } };
            return .{ .redraw = true };
        }
        if (!extent.reachable(self.kept_key, ip)) {
            self.tooFar();
            return .{ .redraw = true };
        }
        switch (self.tool) {
            .number => {
                try self.addSettled(.{ .number = .{ .center = ip, .value = self.doc.nextNumber(), .size = self.fontImg(), .color = self.currentColor() } });
            },
            .text => self.startTyping(.{ .kind = .text, .pos = ip.sub(.{ .x = 0, .y = self.fontImg() * 0.5 }) }),
            else => self.mode = .{ .drag = .{ .tool = self.tool, .start = ip, .cur = ip, .start_screen = sp, .cur_screen = sp } },
        }
        return .{ .redraw = true };
    }

    fn onUp(self: *Editor, x: f32, y: f32, button: input.Button) !Effect {
        if (button == .left and self.mode == .moving) {
            self.moveTo(self.view.toImage(.{ .x = x, .y = y }));
            try self.finishMove();
            return .{ .redraw = true };
        }
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
        if (self.shapeFromDrag(fin)) |a| {
            if (extent.fits(self.ctx(), self.kept_key, a)) try self.addSettled(a) else self.tooFar();
        }
        return .{ .redraw = true };
    }

    fn tooFar(self: *Editor) void {
        self.setToast("Too far from the image. The canvas grows only so far.", .{});
    }

    fn startTyping(self: *Editor, t: Typing) void {
        self.draft.clearRetainingCapacity();
        self.mode = .{ .typing = t };
    }

    /// Drop any shape or text in progress; put a moving annotation back.
    pub fn cancel(self: *Editor) void {
        if (self.mode == .moving) self.doc.setLive(self.mode.moving.grab.index, self.mode.moving.before);
        self.draft.clearRetainingCapacity();
        self.mode = .idle;
    }

    /// Turn the text in progress into an annotation (nothing if blank).
    pub fn commitTyping(self: *Editor) !void {
        if (self.mode != .typing) return;
        defer self.cancel();
        if (std.mem.trim(u8, self.draft.items, " \t\n").len == 0) return;
        var a = self.preview().?;
        {
            const owned = try self.gpa.dupe(u8, self.draft.items);
            errdefer self.gpa.free(owned); // the document owns it once added
            switch (a) {
                .text => |*t| t.text = owned,
                .callout => |*c| c.text = owned,
                else => unreachable,
            }
            try self.doc.add(self.gpa, a);
        }
        try self.settleAdded();
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

    /// Drop the shape or text in progress, else undo the last step.
    fn undo(self: *Editor) !void {
        if (self.mode != .idle) self.cancel() else _ = try self.doc.undo(self.gpa);
    }

    fn redo(self: *Editor) !void {
        self.cancel();
        _ = try self.doc.redo(self.gpa);
    }

    /// Set the style of new arrows and callout pointers (a shape in
    /// progress follows) and say it, in the words of the active tool.
    fn setArrowStyle(self: *Editor, s: ann.ArrowStyle) void {
        self.arrow_style = s;
        self.setToast("{s}: {s}", .{ if (self.tool == .callout) "Pointer" else "Arrow", @tagName(s) });
    }

    fn run(self: *Editor, action: keymap.Action, was_armed: bool) !Effect {
        switch (action) {
            // The active tool's key again: its `again` action, if any.
            .tool => |t| if (t != self.tool) {
                try self.setTool(t);
            } else if (keymap.toolInfo(t).again) |ag| {
                return self.run(ag.action, was_armed);
            } else try self.setTool(t),
            .arrow_style => self.setArrowStyle(if (self.arrow_style == .straight) .stairs else .straight),
            .next_tool => try self.setTool(keymap.cycleTool(self.tool, 1)),
            .prev_tool => try self.setTool(keymap.cycleTool(self.tool, -1)),
            .color => |i| self.color_idx = i,
            .size_up => self.changeSize(1),
            .size_down => self.changeSize(-1),
            .undo => try self.undo(),
            .redo => try self.redo(),
            .save, .copy => {
                try self.commitTyping();
                return .{ .redraw = true, .command = if (action == .save) .save else .copy };
            },
            // Esc and q: cancel the shape in progress, else close the help,
            // else quit (a second press when there are unsaved changes).
            .quit => {
                if (self.mode == .drag or self.mode == .moving) {
                    self.cancel();
                } else if (self.help_visible) {
                    self.help_visible = false;
                } else {
                    if (!self.dirty() or was_armed) return .{ .command = .quit };
                    self.quit_armed = true;
                    self.setToast("Unsaved changes. Esc or q again to quit, Ctrl+S to save, Ctrl+C to copy.", .{});
                }
            },
            .toggle_help => self.help_visible = !self.help_visible,
            .toggle_dock => self.dock_visible = !self.dock_visible,
            .zoom_in, .zoom_out => self.zoom(if (action == .zoom_in) 1 else -1, .{
                .x = @floatFromInt(self.view.screen_w / 2),
                .y = @floatFromInt(self.view.screen_h / 2),
            }),
            .zoom_fit => {
                self.fit();
                self.setToast("Fit: zoom {d}%", .{@as(u32, @intFromFloat(@round(self.view.xf.scale * 100)))});
            },
            .pan => |d| {
                const step_x: i32 = @intCast(self.view.screen_w / 8);
                const step_y: i32 = @intCast(self.view.screen_h / 8);
                self.pan(d[0] * step_x, d[1] * step_y);
            },
        }
        return .{ .redraw = true };
    }
};

// ---- tests -------------------------------------------------------------

const T = struct {
    doc: Document = .{},
    font: Font = undefined,
    ed: Editor = undefined,

    fn init(self: *T) void {
        self.initSize(200, 100);
    }
    /// A w x h image on a w x h screen (1:1).
    fn initSize(self: *T, w: u32, h: u32) void {
        self.font = Font.init(std.testing.allocator, @import("root.zig").font_ttf) catch unreachable;
        self.ed = Editor.init(std.testing.allocator, &self.font, &self.doc, w, h, w, h);
        // The panels would cover most of a 200x100 screen; tests that click
        // them show them.
        self.ed.dock_visible = false;
    }
    fn deinit(self: *T) void {
        self.ed.deinit();
        self.doc.deinit(std.testing.allocator);
        self.font.deinit();
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

test "q acts like Esc: cancels a drag, closes the help, asks once, quits; a letter while typing" {
    var t = T{};
    t.init();
    defer t.deinit();
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 10, .y = 10 } });
    _ = try t.ed.handle(.{ .mouse_move = .{ .x = 50, .y = 40 } });
    try std.testing.expectEqual(@as(?Command, null), (try t.key("q")).command);
    try std.testing.expect(t.ed.mode == .idle);
    _ = try t.key("?");
    try std.testing.expectEqual(@as(?Command, null), (try t.key("q")).command);
    try std.testing.expect(!t.ed.help_visible);
    _ = try t.key("t");
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 5, .y = 50 } });
    _ = try t.key("q");
    _ = try t.key("esc");
    try std.testing.expectEqualStrings("q", t.doc.items.items[0].text.text);
    try std.testing.expectEqual(@as(?Command, null), (try t.key("q")).command);
    try std.testing.expect(std.mem.indexOf(u8, t.ed.toast().?, "q again") != null);
    try std.testing.expectEqual(Command.quit, (try t.key("q")).command.?);
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
    try std.testing.expectEqual(geom.Rect{ .x0 = 20, .y0 = 10, .x1 = 120, .y1 = 60 }, t.doc.crop().?.rect);
    try std.testing.expectEqual(geom.Rect{ .x0 = 20, .y0 = 10, .x1 = 120, .y1 = 60 }, t.ed.canvas);
    try std.testing.expectEqual(Tool.rect, t.ed.tool);
    // Screen (50, 25) is the image point (20, 10) after the refit (centered 1:1).
    try std.testing.expectEqual(Vec2.init(20, 10), t.ed.view.toImage(.{ .x = 50, .y = 25 }));
    _ = try t.key("ctrl+z");
    try std.testing.expectEqual(@as(i32, 200), t.ed.canvas.width());
    _ = try t.key("ctrl+y");
    try std.testing.expectEqual(@as(i32, 100), t.ed.canvas.width());
}

test "dock clicks pick tools and colors and never draw; help closes on click and Esc" {
    var t = T{};
    t.init();
    defer t.deinit();
    t.ed.resize(1920, 1080);
    t.ed.dock_visible = true;
    const d = Dock.of(1920, 1080, t.ed.tool);
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

test "top bar: undo and redo by click, never draws, hover follows the pointer" {
    var t = T{};
    t.init();
    defer t.deinit();
    t.ed.resize(1920, 1080);
    t.ed.dock_visible = true;
    const b = TopBar.of(1920, 1080);
    const undo_c = b.slots[0].min.add(b.slots[0].max).scale(0.5);
    const redo_c = b.slots[1].min.add(b.slots[1].max).scale(0.5);
    try std.testing.expect(!t.ed.canUndo() and !t.ed.canRedo());
    try t.drag(300, 300, 400, 400);
    try std.testing.expect(t.ed.canUndo());
    // A click on a disabled button does nothing, and never draws.
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = redo_c.x, .y = redo_c.y } });
    _ = try t.ed.handle(.{ .mouse_up = .{ .x = redo_c.x, .y = redo_c.y } });
    try std.testing.expectEqual(@as(usize, 1), t.doc.items.items.len);
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = undo_c.x, .y = undo_c.y } });
    _ = try t.ed.handle(.{ .mouse_up = .{ .x = undo_c.x, .y = undo_c.y } });
    try std.testing.expectEqual(@as(usize, 0), t.doc.items.items.len);
    try std.testing.expect(!t.ed.canUndo() and t.ed.canRedo());
    const eff = try t.ed.handle(.{ .mouse_move = .{ .x = redo_c.x, .y = redo_c.y } });
    try std.testing.expect(eff.redraw);
    try std.testing.expectEqual(@import("topbar.zig").Button.redo, t.ed.chromeHover().bar.?);
    try std.testing.expect(!(try t.ed.handle(.{ .mouse_move = .{ .x = redo_c.x + 1, .y = redo_c.y } })).redraw);
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = redo_c.x, .y = redo_c.y } });
    try std.testing.expectEqual(@as(usize, 1), t.doc.items.items.len);
}

test "zoom out keeps sizes and the point under the pointer; 0 refits; middle drag pans" {
    var t = T{};
    t.init();
    defer t.deinit();
    const stroke = t.ed.strokeImg();
    const p = Vec2.init(150, 40);
    const before = t.ed.view.toImage(p);
    _ = try t.ed.handle(.{ .wheel = .{ .delta = -1, .x = p.x, .y = p.y, .mods = .{ .ctrl = true } } });
    try std.testing.expectEqual(@as(f32, 2.0 / 3.0), t.ed.view.xf.scale);
    const after = t.ed.view.toImage(p);
    try std.testing.expectApproxEqAbs(before.x, after.x, 1);
    try std.testing.expectApproxEqAbs(before.y, after.y, 1);
    try std.testing.expectEqual(stroke, t.ed.strokeImg());
    try std.testing.expect(t.ed.toast() != null);
    // A drag far outside the image grows the canvas; the view stays.
    const xf = t.ed.view.xf;
    try t.drag(100, 50, 199, 99);
    try std.testing.expect(t.ed.canvas.x1 > 200);
    try std.testing.expectEqual(xf, t.ed.view.xf);
    // Middle drag pans by whole pixels and draws nothing.
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 50, .y = 50, .button = .middle } });
    _ = try t.ed.handle(.{ .mouse_move = .{ .x = 60, .y = 45 } });
    _ = try t.ed.handle(.{ .mouse_up = .{ .x = 60, .y = 45, .button = .middle } });
    try std.testing.expectEqual(xf.offset.add(.{ .x = 10, .y = -5 }), t.ed.view.xf.offset);
    try std.testing.expectEqual(@as(usize, 1), t.doc.items.items.len);
    _ = try t.key("0");
    try std.testing.expect(t.ed.fitted);
    try std.testing.expect(t.ed.view.xf.scale < 1);
}

test "a click too far from the image adds nothing and says why" {
    var t = T{};
    t.init();
    defer t.deinit();
    _ = try t.key("n");
    t.ed.view = t.ed.view.panBy(5000, 0);
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 10, .y = 10 } });
    try std.testing.expectEqual(@as(usize, 0), t.doc.items.items.len);
    try std.testing.expect(std.mem.startsWith(u8, t.ed.toast().?, "Too far"));
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

test "move: topmost wins, Esc puts it back, a drag is one exact undo step" {
    var t = T{};
    t.init();
    defer t.deinit();
    _ = try t.key("r");
    try t.drag(20, 20, 80, 60);
    try t.drag(40, 40, 120, 90); // on top, its outline crosses the first one
    _ = try t.key("m");
    try std.testing.expectEqual(Grab{ .index = 1, .part = .whole }, t.ed.grabAt(.{ .x = 40, .y = 60 }).?);
    try std.testing.expectEqual(Grab{ .index = 0, .part = .whole }, t.ed.grabAt(.{ .x = 20, .y = 30 }).?);
    try std.testing.expectEqual(@as(?Grab, null), t.ed.grabAt(.{ .x = 60, .y = 30 })); // inside the first: no stroke
    // Hover follows the pointer.
    _ = try t.ed.handle(.{ .mouse_move = .{ .x = 20, .y = 30 } });
    try std.testing.expectEqual(@as(usize, 0), t.ed.outlined().?.index);
    // Esc in the middle of a drag puts it back, with no undo step.
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 20, .y = 30 } });
    _ = try t.ed.handle(.{ .mouse_move = .{ .x = 25, .y = 35 } });
    try std.testing.expectEqual(Vec2.init(25, 25), t.doc.items.items[0].rect.a);
    _ = try t.key("esc");
    try std.testing.expectEqual(Vec2.init(20, 20), t.doc.items.items[0].rect.a);
    _ = try t.ed.handle(.{ .mouse_up = .{ .x = 25, .y = 35 } });
    try std.testing.expectEqual(@as(usize, 2), t.doc.history.items.len);
    try t.drag(20, 30, 30, 40);
    try std.testing.expectEqual(Vec2.init(30, 30), t.doc.items.items[0].rect.a);
    try std.testing.expectEqual(@as(usize, 3), t.doc.history.items.len);
    _ = try t.key("ctrl+z");
    try std.testing.expectEqual(Vec2.init(20, 20), t.doc.items.items[0].rect.a);
    try std.testing.expectEqual(Vec2.init(80, 60), t.doc.items.items[0].rect.b);
    _ = try t.key("ctrl+y");
    try std.testing.expectEqual(Vec2.init(30, 30), t.doc.items.items[0].rect.a);
}

test "move: a callout box moves alone, its tip alone; an arrow end alone" {
    var t = T{};
    t.init();
    defer t.deinit();
    _ = try t.key("c");
    try t.drag(20, 20, 100, 60);
    _ = try t.key("H");
    _ = try t.key("enter");
    _ = try t.key("m");
    try t.drag(21, 21, 31, 11); // the tip
    var c = t.doc.items.items[0].callout;
    try std.testing.expectEqual(Vec2.init(30, 10), c.target.?);
    try std.testing.expectEqual(Vec2.init(100, 60), c.anchor);
    try t.drag(110, 60, 120, 70); // the box
    c = t.doc.items.items[0].callout;
    try std.testing.expectEqual(Vec2.init(30, 10), c.target.?);
    try std.testing.expectEqual(Vec2.init(110, 70), c.anchor);
    _ = try t.key("a");
    try t.drag(10, 90, 190, 90);
    _ = try t.key("m");
    try t.drag(189, 90, 179, 80); // the head
    const a = t.doc.items.items[1].arrow;
    try std.testing.expectEqual(Vec2.init(10, 90), a.tail);
    try std.testing.expectEqual(Vec2.init(180, 80), a.head);
}

test "move: an annotation made before a crop stays under it" {
    var t = T{};
    t.init();
    defer t.deinit();
    _ = try t.key("n");
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 50, .y = 50 } });
    _ = try t.key("x");
    try t.drag(20, 20, 120, 80); // keeps image (20, 20)..(120, 80)
    _ = try t.key("m");
    // The view refits to the crop: image (50, 50) is on screen at...
    const p = t.ed.view.toScreen(.{ .x = 50, .y = 50 });
    const far = t.ed.view.toScreen(.{ .x = 300, .y = 50 });
    try t.drag(p.x, p.y, far.x, far.y);
    // It may not leave the crop for good: it stops where it still shows.
    const n = t.doc.items.items[0].number;
    try std.testing.expect(n.center.x < 120 + n.size);
    // The canvas does not grow for it.
    try std.testing.expectEqual(geom.Rect{ .x0 = 20, .y0 = 20, .x1 = 120, .y1 = 80 }, t.ed.canvas);
}

test "a again switches the arrow style of new arrows, for the session; an arrow in progress follows" {
    var t = T{};
    t.init();
    defer t.deinit();
    _ = try t.key("a"); // the arrow tool is active: a second press
    try std.testing.expectEqual(ann.ArrowStyle.stairs, t.ed.arrow_style);
    try std.testing.expectEqualStrings("Arrow: stairs", t.ed.toast().?);
    try std.testing.expectEqual(Tool.arrow, t.ed.tool);
    try t.drag(10, 10, 50, 40);
    try std.testing.expectEqual(ann.ArrowStyle.stairs, t.doc.items.items[0].arrow.style);
    // Another tool and back: the style stays.
    _ = try t.key("r");
    _ = try t.key("a");
    try std.testing.expectEqual(ann.ArrowStyle.stairs, t.ed.arrow_style);
    // In the middle of a drag: the preview follows, the drag goes on.
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 10, .y = 60 } });
    _ = try t.ed.handle(.{ .mouse_move = .{ .x = 90, .y = 90 } });
    _ = try t.key("a");
    try std.testing.expectEqual(ann.ArrowStyle.straight, t.ed.preview().?.arrow.style);
    _ = try t.ed.handle(.{ .mouse_up = .{ .x = 90, .y = 90 } });
    try std.testing.expectEqual(@as(usize, 2), t.doc.items.items.len);
    try std.testing.expectEqual(ann.ArrowStyle.straight, t.doc.items.items[1].arrow.style);
    try std.testing.expectEqual(ann.ArrowStyle.stairs, t.doc.items.items[0].arrow.style);
    // Undo and redo keep each arrow's own style.
    _ = try t.key("ctrl+z");
    _ = try t.key("ctrl+z");
    _ = try t.key("ctrl+y");
    try std.testing.expectEqual(ann.ArrowStyle.stairs, t.doc.items.items[0].arrow.style);
}

test "the arrow style switch above the dock: a click picks a style; with another tool it is not there" {
    var t = T{};
    t.init();
    defer t.deinit();
    t.ed.resize(1920, 1080);
    t.ed.dock_visible = true;
    const d = Dock.of(1920, 1080, .arrow);
    const c = d.styles[1].min.add(d.styles[1].max).scale(0.5);
    _ = try t.ed.handle(.{ .mouse_move = .{ .x = c.x, .y = c.y } });
    try std.testing.expectEqual(@import("dock.zig").Hit{ .arrow_style = .stairs }, t.ed.chromeHover().dock.?);
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = c.x, .y = c.y } });
    _ = try t.ed.handle(.{ .mouse_up = .{ .x = c.x, .y = c.y } });
    try std.testing.expectEqual(ann.ArrowStyle.stairs, t.ed.arrow_style);
    try std.testing.expectEqualStrings("Arrow: stairs", t.ed.toast().?);
    try std.testing.expectEqual(@as(usize, 0), t.doc.items.items.len);
    // Another tool: no switch, a drag there draws.
    _ = try t.key("r");
    try t.drag(c.x - 30, c.y - 30, c.x + 30, c.y + 30);
    try std.testing.expectEqual(@as(usize, 1), t.doc.items.items.len);
    try std.testing.expectEqual(ann.ArrowStyle.stairs, t.ed.arrow_style);
}

test "move: a stairs arrow is grabbed on its path, not on the straight line; an end re-routes it" {
    var t = T{};
    t.init();
    defer t.deinit();
    _ = try t.key("a"); // stairs
    try t.drag(10, 10, 190, 90); // right along y 10 to x 100, down to y 90, right to x 190
    _ = try t.key("m");
    try std.testing.expectEqual(Grab{ .index = 0, .part = .whole }, t.ed.grabAt(.{ .x = 50, .y = 10 }).?);
    try std.testing.expectEqual(Grab{ .index = 0, .part = .whole }, t.ed.grabAt(.{ .x = 100, .y = 30 }).?);
    try std.testing.expectEqual(Grab{ .index = 0, .part = .bend }, t.ed.grabAt(.{ .x = 100, .y = 50 }).?); // the middle: the bend handle
    try std.testing.expectEqual(@as(?Grab, null), t.ed.grabAt(.{ .x = 55, .y = 30 })); // the straight line
    try std.testing.expectEqual(Grab{ .index = 0, .part = .head }, t.ed.grabAt(.{ .x = 188, .y = 89 }).?);
    // The head alone: the path re-routes, the style stays.
    try t.drag(188, 89, 178, 59);
    var a = t.doc.items.items[0].arrow;
    try std.testing.expectEqual(Vec2.init(10, 10), a.tail);
    try std.testing.expectEqual(Vec2.init(180, 60), a.head);
    try std.testing.expectEqual(ann.ArrowStyle.stairs, a.style);
    try std.testing.expect(draw.hitDist(t.ed.ctx(), t.doc.items.items[0], t.ed.view.xf, .{ .x = 95, .y = 35 }) < 0); // new middle x 95
    // The body: both ends move.
    try t.drag(50, 10, 55, 15);
    a = t.doc.items.items[0].arrow;
    try std.testing.expectEqual(Vec2.init(15, 15), a.tail);
    try std.testing.expectEqual(Vec2.init(185, 65), a.head);
    _ = try t.key("ctrl+z");
    _ = try t.key("ctrl+z");
    try std.testing.expectEqual(Vec2.init(190, 90), t.doc.items.items[0].arrow.head);
    try std.testing.expectEqual(ann.ArrowStyle.stairs, t.doc.items.items[0].arrow.style);
}

test "c again switches the pointer style of new callouts: one setting with the arrows; while typing c is a letter" {
    var t = T{};
    t.init();
    defer t.deinit();
    _ = try t.key("c");
    try std.testing.expectEqual(ann.ArrowStyle.straight, t.ed.arrow_style);
    _ = try t.key("c"); // the callout tool is active: a second press
    try std.testing.expectEqual(ann.ArrowStyle.stairs, t.ed.arrow_style);
    try std.testing.expectEqualStrings("Pointer: stairs", t.ed.toast().?);
    try std.testing.expectEqual(Tool.callout, t.ed.tool);
    try t.drag(10, 10, 120, 60);
    try std.testing.expectEqual(ann.ArrowStyle.stairs, t.ed.preview().?.callout.style);
    _ = try t.key("c"); // typing: a letter, not the switch
    _ = try t.key("enter");
    const c = t.doc.items.items[0].callout;
    try std.testing.expectEqualStrings("c", c.text);
    try std.testing.expectEqual(ann.ArrowStyle.stairs, c.style);
    try std.testing.expectEqual(t.ed.strokeImg(), c.width);
    // The arrow tool shares the setting.
    _ = try t.key("a");
    try std.testing.expectEqual(ann.ArrowStyle.stairs, t.ed.arrow_style);
    _ = try t.key("a");
    try std.testing.expectEqualStrings("Arrow: straight", t.ed.toast().?);
    _ = try t.key("c");
    try std.testing.expectEqual(ann.ArrowStyle.straight, t.ed.arrow_style);
    // Undo and redo keep each callout's own style.
    _ = try t.key("ctrl+z");
    _ = try t.key("ctrl+y");
    try std.testing.expectEqual(ann.ArrowStyle.stairs, t.doc.items.items[0].callout.style);
}

test "the style switch shows above the dock with the callout tool; a click picks the pointer style" {
    var t = T{};
    t.init();
    defer t.deinit();
    t.ed.resize(1920, 1080);
    t.ed.dock_visible = true;
    _ = try t.key("c");
    const d = Dock.of(1920, 1080, .callout);
    const p = d.styles[1].min.add(d.styles[1].max).scale(0.5);
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = p.x, .y = p.y } });
    _ = try t.ed.handle(.{ .mouse_up = .{ .x = p.x, .y = p.y } });
    try std.testing.expectEqual(ann.ArrowStyle.stairs, t.ed.arrow_style);
    try std.testing.expectEqualStrings("Pointer: stairs", t.ed.toast().?);
    try std.testing.expect(t.ed.mode == .idle);
    try std.testing.expectEqual(@as(usize, 0), t.doc.items.items.len);
}

test "move: a stairs callout is grabbed on its elbow; its box moves alone and the pointer re-routes" {
    var t = T{};
    t.init();
    defer t.deinit();
    _ = try t.key("c");
    _ = try t.key("c"); // stairs
    try t.drag(10, 10, 150, 70); // box right of x 150; pointer: left to x 80, up to y 10, left to x 10
    _ = try t.key("H");
    _ = try t.key("enter");
    _ = try t.key("m");
    try std.testing.expectEqual(Grab{ .index = 0, .part = .whole }, t.ed.grabAt(.{ .x = 80, .y = 25 }).?); // middle segment
    try std.testing.expectEqual(Grab{ .index = 0, .part = .bend }, t.ed.grabAt(.{ .x = 80, .y = 40 }).?); // its middle
    try std.testing.expectEqual(Grab{ .index = 0, .part = .whole }, t.ed.grabAt(.{ .x = 120, .y = 70 }).?); // first segment
    try std.testing.expectEqual(@as(?Grab, null), t.ed.grabAt(.{ .x = 115, .y = 52 })); // the straight line
    try std.testing.expectEqual(Grab{ .index = 0, .part = .tip }, t.ed.grabAt(.{ .x = 11, .y = 11 }).?);
    // The box by its middle segment: the box moves, the tip stays, the elbow re-routes.
    try t.drag(80, 25, 90, 35);
    const c = t.doc.items.items[0].callout;
    try std.testing.expectEqual(Vec2.init(10, 10), c.target.?);
    try std.testing.expectEqual(Vec2.init(160, 80), c.anchor);
    try std.testing.expect(draw.hitDist(t.ed.ctx(), t.doc.items.items[0], t.ed.view.xf, .{ .x = 85, .y = 45 }) < 0); // new middle x 85
    // The tip alone.
    try t.drag(10, 10, 30, 90);
    try std.testing.expectEqual(Vec2.init(30, 90), t.doc.items.items[0].callout.target.?);
    try std.testing.expectEqual(Vec2.init(160, 80), t.doc.items.items[0].callout.anchor);
    _ = try t.key("ctrl+z");
    _ = try t.key("ctrl+z");
    try std.testing.expectEqual(Vec2.init(150, 70), t.doc.items.items[0].callout.anchor);
    try std.testing.expectEqual(Vec2.init(10, 10), t.doc.items.items[0].callout.target.?);
}

test "stairs arrows drawn side by side nest, in both orders; undo takes the new one only" {
    for ([_]bool{ false, true }) |swap| {
        var t = T{};
        t.initSize(700, 450);
        defer t.deinit();
        _ = try t.key("a"); // stairs
        // Vertical first, tails at the top, heads lower left (the user's case).
        const left = [4]f32{ 495, 60, 260, 360 };
        const right = [4]f32{ 557, 60, 435, 360 };
        const first = if (swap) right else left;
        const second = if (swap) left else right;
        try t.drag(first[0], first[1], first[2], first[3]);
        try std.testing.expectEqual(ann.Elbow{}, t.doc.items.items[0].arrow.elbow);
        try t.drag(second[0], second[1], second[2], second[3]);
        const e = t.doc.items.items[1].arrow.elbow;
        // The one whose head is farther left turns higher.
        try std.testing.expect(if (swap) e.at < 0.5 else e.at > 0.5);
        try std.testing.expect(!e.pinned);
        try std.testing.expectEqual(ann.Elbow{}, t.doc.items.items[0].arrow.elbow);
        _ = try t.key("ctrl+z");
        try std.testing.expectEqual(@as(usize, 1), t.doc.items.items.len);
    }
}

test "a commit re-routes the stairs paths around it in the same undo step; undo and redo are exact" {
    var t = T{};
    t.init();
    defer t.deinit();
    _ = try t.key("a"); // stairs
    try t.drag(10, 10, 190, 90); // the middle segment at x 100
    _ = try t.key("a"); // straight
    try t.drag(90, 50, 120, 50); // across that middle segment
    const moved = t.doc.items.items[0].arrow;
    try std.testing.expect(moved.elbow.at < (90.0 - 10.0) / 180.0 or moved.elbow.at > (120.0 - 10.0) / 180.0);
    try std.testing.expectEqual(@as(usize, 3), t.doc.history.items.len); // add, add, the chained re-route
    _ = try t.key("ctrl+z");
    try std.testing.expectEqual(@as(usize, 1), t.doc.items.items.len);
    try std.testing.expectEqual(ann.Elbow{}, t.doc.items.items[0].arrow.elbow);
    _ = try t.key("ctrl+y");
    try std.testing.expectEqual(@as(usize, 2), t.doc.items.items.len);
    try std.testing.expectEqual(moved, t.doc.items.items[0].arrow);
    // A move of the straight arrow away: the stairs path settles back, one step.
    _ = try t.key("m");
    try t.drag(105, 50, 35, 50);
    try std.testing.expectEqual(ann.Elbow{}, t.doc.items.items[0].arrow.elbow);
    _ = try t.key("ctrl+z");
    try std.testing.expectEqual(moved, t.doc.items.items[0].arrow);
    try std.testing.expectEqual(@as(f32, 120), t.doc.items.items[1].arrow.head.x);
}

test "move: a drag of the bend pins the elbow; a new neighbour leaves it; back to the middle frees it" {
    var t = T{};
    t.init();
    defer t.deinit();
    _ = try t.key("a"); // stairs
    try t.drag(10, 10, 190, 90); // the middle segment at x 100, its handle at (100, 50)
    _ = try t.key("m");
    _ = try t.ed.handle(.{ .mouse_move = .{ .x = 100, .y = 50 } });
    try std.testing.expectEqual(Grab{ .index = 0, .part = .bend }, t.ed.outlined().?);
    try t.drag(100, 50, 60, 70);
    var a = t.doc.items.items[0].arrow;
    try std.testing.expect(a.elbow.pinned);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0 / 180.0), a.elbow.at, 1e-4);
    try std.testing.expectEqual(Vec2.init(10, 10), a.tail); // the ends stay
    try std.testing.expectEqual(Vec2.init(190, 90), a.head);
    try std.testing.expect(std.mem.startsWith(u8, t.ed.toast().?, "Bend pinned"));
    try std.testing.expect(draw.hitDist(t.ed.ctx(), t.doc.items.items[0], t.ed.view.xf, .{ .x = 60, .y = 50 }) < 0);
    // A straight arrow across the pinned middle segment: it stays.
    _ = try t.key("a");
    _ = try t.key("a"); // straight
    try t.drag(50, 30, 75, 30);
    try std.testing.expectEqual(a, t.doc.items.items[0].arrow);
    // Undo the pin: the elbow is auto again.
    _ = try t.key("ctrl+z");
    _ = try t.key("ctrl+z");
    try std.testing.expectEqual(ann.Elbow{}, t.doc.items.items[0].arrow.elbow);
    _ = try t.key("ctrl+y");
    _ = try t.key("ctrl+y");
    // The bend back to the middle: auto, and it routes off the straight arrow.
    _ = try t.key("m");
    try t.drag(60, 50, 101, 50);
    a = t.doc.items.items[0].arrow;
    try std.testing.expect(!a.elbow.pinned);
    try std.testing.expect(a.elbow.at > (75.0 - 10.0) / 180.0);
    try std.testing.expectEqualStrings("Bend: auto", t.ed.toast().?);
}
