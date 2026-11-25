//! Editor: the input state machine. Turns input events into document changes,
//! tool/color/size state, an in-progress preview, and commands (save, copy,
//! quit) for the app to run. It never draws and never does IO.
const std = @import("std");
const builtin = @import("builtin");
const geom = @import("geom.zig");
const input = @import("input.zig");
const keymap = @import("keymap.zig");
const style = @import("style.zig");
const color = @import("color.zig");
const ann = @import("annotation.zig");
const extent = @import("extent.zig");
const draw = @import("draw.zig");
const dropzone = @import("dropzone.zig");
const magnet = @import("magnet.zig");
const route = @import("route.zig");
const Document = @import("document.zig").Document;
const View = @import("view.zig").View;
const Font = @import("font.zig").Font;
const dock = @import("dock.zig");
const Dock = dock.Dock;
const TopBar = @import("topbar.zig").TopBar;
const PadBar = @import("padbar.zig").PadBar;
const Hover = @import("chrome.zig").Hover;
const Ghost = @import("chrome.zig").Ghost;
const Browser = @import("browser.zig").Browser;
const browsergeo = @import("browsergeo.zig");
const settings = @import("settings.zig");
const Settings = settings.Settings;

const Vec2 = geom.Vec2;
const Tool = keymap.Tool;
const Annotation = ann.Annotation;
const Part = ann.Part;

/// The tool and the arrow style at startup: a callout with a stairs
/// pointer. The style is shared, so new arrows start as stairs too.
pub const default_tool: Tool = .callout;
pub const default_arrow_style: ann.ArrowStyle = .stairs;

pub const Command = enum {
    save,
    copy,
    quit,
    /// The settings changed: the app may persist them (the editor does no IO).
    save_settings,
    /// An image was dropped from the file browser: the app loads it
    /// (`Editor.takeAdd` has the path and the place), adds it and calls `imageAdded`.
    add_image,
};

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
    /// Editing the text of an existing annotation (a double click with the
    /// move tool): its index, and it as it was. The document holds it with
    /// no text meanwhile, and `preview` draws it with the draft.
    edit: ?Edit = null,
};

const Edit = struct { index: usize, before: Annotation };

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

/// An image drag (move tool, press on an image with no annotation under it,
/// 2+ images). It starts once the pointer leaves `click_slop`; before that a
/// release is a plain click. The image stays in place meanwhile: a ghost
/// outline follows the pointer and the drop slots show (`montage_drop`).
const ImageDrag = struct {
    id: u32,
    start_screen: Vec2,
    /// The grab point in scene px, from the top-left corner of the image.
    grab: Vec2,
    active: bool = false,
    /// The view when the drag became active: a cancel restores it.
    orig_xf: geom.Xform = undefined,
    orig_fitted: bool = true,
};

/// An image dragged out of the browser list. It starts once the pointer
/// leaves `click_slop`; before that a release is a plain click (nothing).
const BrowserDrag = struct {
    /// The browser row.
    row: usize,
    start: Vec2,
    pointer: Vec2,
    active: bool = false,
    /// Size of the image file (px), read when the drag becomes active.
    w: i32 = 0,
    h: i32 = 0,
    /// The view when the drag became active: a cancel restores it.
    orig_xf: geom.Xform = undefined,
    orig_fitted: bool = true,
};

pub const Mode = union(enum) {
    idle,
    drag: Drag,
    typing: Typing,
    moving: Moving,
    image_drag: ImageDrag,
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
    /// Hand mode (while Space is held): a left drag pans the canvas, like the middle button.
    hand: bool = false,
    tool: Tool = default_tool,
    /// Tool to go back to after a crop.
    tool_before_crop: Tool = default_tool,
    color_idx: u8 = 0,
    size_idx: u8 = style.default_size,
    /// Style of new arrows and callout pointers (one setting for both). It
    /// stays for the session, across tool switches.
    arrow_style: ann.ArrowStyle = default_arrow_style,
    /// Style of new texts (plain or boxed). Stays for the session.
    text_style: ann.TextStyle = .plain,
    /// User settings (settings.zig): not document state, not undo steps.
    settings: Settings = .{},
    /// The shortcut overlay (`?`/F1).
    help_visible: bool = false,
    /// The icon dock and the top bar (Space hides both to see the image).
    dock_visible: bool = true,
    /// Tests only: a press on the chrome (dock, top bar, padding widget) is
    /// meant. Off, such a press panics in a test build: a chrome that grew
    /// over a raw click would otherwise fail with a confusing assert.
    chrome_press_ok: bool = false,
    /// Montage drag in progress: the dragged image size and the pointer.
    /// While set, the compositor shows the free magnet slots and the nearest
    /// one (dropzone.zig). Set by the drag UI (or the `dropzone` script command).
    montage_drop: ?dropzone.Drop = null,
    /// The file browser (folder button, panel, thumbnails): an overlay on the left.
    browser: Browser,
    /// An image dragged out of the browser list, if any.
    bdrag: ?BrowserDrag = null,
    /// A drop waits for the app (`Command.add_image`): the file and the
    /// scene position of the new image.
    add_path: std.ArrayList(u8) = .empty,
    add_pos: [2]i32 = .{ 0, 0 },
    add_pending: bool = false,
    /// The view before the drag of the pending drop (back to it if the file fails).
    add_orig_xf: geom.Xform = .{},
    add_orig_fitted: bool = true,
    /// Last pointer position on screen (hover), null before the first move.
    pointer: ?Vec2 = null,
    /// Move tool: the annotation part under the pointer.
    hover: ?Grab = null,
    /// Move/select tool: the annotation kept selected (index in the document):
    /// outlined while idle, deleted by Delete or Backspace. Cleared by a press
    /// on empty space, Esc, another tool, undo and redo.
    selected: ?usize = null,
    mode: Mode = .idle,
    draft: std.ArrayList(u8) = .empty,
    /// The text caret and the other end of the selection in `draft` (byte
    /// offsets on a character boundary; equal: no selection).
    caret: usize = 0,
    sel_anchor: usize = 0,
    quit_armed: bool = false,
    saved_revision: u64 = 0,
    /// Canvas background of the last save (or of the start).
    saved_bg: settings.CanvasBg = .light,
    /// A press on the padding slider is held: moves set the step, the
    /// release asks the App to save the settings.
    slider_drag: bool = false,
    /// Canvas padding of the last save (or of the start).
    saved_padding: u16 = 0,
    toast_buf: [256]u8 = undefined,
    toast_len: usize = 0,
    hint_buf: [96]u8 = undefined,

    /// Fit the canvas of `doc` (its images placed already) to the screen.
    pub fn init(gpa: std.mem.Allocator, font: *Font, doc: *Document, screen_w: u32, screen_h: u32) Editor {
        const dctx = draw.Ctx{ .gpa = gpa, .font = font };
        const canvas = extent.canvas(dctx, doc);
        var br = Browser.init(gpa);
        br.screen = .{ screen_w, screen_h };
        return .{
            .gpa = gpa,
            .font = font,
            .doc = doc,
            .browser = br,
            .view = View.fit(canvas, screen_w, screen_h),
            .canvas = canvas,
            .canvas_rev = doc.revision,
            .kept_key = doc.kept(),
            .saved_revision = doc.revision,
        };
    }

    pub fn ctx(self: *const Editor) draw.Ctx {
        return .{ .gpa = self.gpa, .font = self.font, .pad = self.settings.padding };
    }

    pub fn deinit(self: *Editor) void {
        self.cancel(); // an edit in progress puts its annotation back
        self.draft.deinit(self.gpa);
        self.add_path.deinit(self.gpa);
        self.browser.deinit();
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
    /// Show the drop slots for a dragged image of `w` x `h` px with the
    /// pointer at the screen point `pointer`; call again on every move.
    pub fn setMontageDrop(self: *Editor, w: i32, h: i32, pointer: Vec2) void {
        self.montage_drop = .{ .w = w, .h = h, .pointer = pointer };
    }

    pub fn clearMontageDrop(self: *Editor) void {
        self.montage_drop = null;
    }

    pub fn canUndo(self: *const Editor) bool {
        return self.mode != .idle or self.doc.history.items.len > 0;
    }

    pub fn canRedo(self: *const Editor) bool {
        return self.doc.undone.items.len > 0;
    }

    /// The dock or top bar item under the pointer (none during a drag).
    pub fn chromeHover(self: *const Editor) Hover {
        const p = self.pointer orelse return .{};
        if (!self.dock_visible or self.help_visible or self.mode == .drag or self.mode == .moving or self.mode == .image_drag or self.panning != null) return .{};
        const w = self.view.screen_w;
        const h = self.view.screen_h;
        const g = browsergeo.Geo.of(w, h);
        const folder = browsergeo.inside(g.folder, p);
        if (self.browser.open and browsergeo.inside(g.panel, p)) return .{}; // the panel is on top
        return .{ .dock = Dock.of(w, h, self.tool).hit(p), .bar = TopBar.of(w, h).hit(p), .pad = PadBar.of(w, h).contains(p), .folder = folder };
    }

    /// The browser panel shows (open, panels not hidden).
    pub fn browserVisible(self: *const Editor) bool {
        return self.dock_visible and self.browser.open;
    }

    /// The ghost thumbnail of an image dragged out of the browser.
    pub fn browserGhost(self: *const Editor) ?Ghost {
        const d = self.bdrag orelse return null;
        if (!d.active) return null;
        return .{ .row = d.row, .at = d.pointer };
    }

    /// The pointer is on the browser panel.
    fn onBrowserPanel(self: *const Editor, p: Vec2) bool {
        return self.browserVisible() and browsergeo.inside(self.browser.geo().panel, p);
    }

    /// The app finished the drop (`Command.add_image`): the view jumps to the
    /// fit of the whole new scene (the same as `0`).
    pub fn imageAdded(self: *Editor) void {
        _ = self.syncView();
        self.fit();
    }

    /// The drop failed (the file did not load): the view goes back.
    pub fn imageAddFailed(self: *Editor) void {
        self.restoreView(self.add_orig_xf, self.add_orig_fitted);
        self.setToast("Cannot open this image.", .{});
    }

    /// Put the view back to the transform `xf` it had before a drag.
    fn restoreView(self: *Editor, xf: geom.Xform, fitted: bool) void {
        self.view.xf = xf;
        self.fitted = fitted;
        _ = self.updateHover();
    }

    /// The path and place of the pending drop (see `Command.add_image`); valid
    /// until the next drop. Null if none.
    pub fn takeAdd(self: *Editor) ?struct { path: []const u8, x: i32, y: i32 } {
        if (!self.add_pending) return null;
        self.add_pending = false;
        return .{ .path = self.add_path.items, .x = self.add_pos[0], .y = self.add_pos[1] };
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
            const clip = extent.itemClip(self.ctx(), self.doc, i).toBounds();
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

    /// The move tool's target to outline: the part under the pointer, else
    /// the selected annotation (`selected`). None
    /// while it moves: the shape itself shows where it goes, and a frame
    /// then pays for one raster less (docs/perf.md).
    pub fn outlined(self: *const Editor) ?Grab {
        if (self.tool != .move or self.mode != .idle or self.help_visible or self.hand) return null;
        const n = self.doc.items.items.len;
        if (self.hover) |g| if (g.index < n) return g;
        if (self.selected) |i| if (i < n) return .{ .index = i, .part = .whole };
        return null;
    }

    /// The pointer shape the backend shows.
    pub const Cursor = enum { crosshair, move, grab, grabbing };

    pub fn cursor(self: *const Editor) Cursor {
        if (self.hand) return if (self.panning != null) .grabbing else .grab;
        if (self.panning != null or (self.mode == .image_drag and self.mode.image_drag.active) or self.browserGhost() != null) return .grabbing; // a middle drag, an image drag
        return if (self.tool == .move) .move else .crosshair;
    }

    fn updateHover(self: *Editor) bool {
        const before = self.hover;
        self.hover = if (self.tool == .move and !self.hand and self.mode == .idle and self.pointer != null) self.grabAt(self.pointer.?) else null;
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
        if (!extent.showsAs(self.ctx(), self.doc, m.grab.index, a)) return;
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

    /// The point is on the dock, the top bar or the padding widget: a click there never draws.
    pub fn onChrome(self: *const Editor, p: Vec2) bool {
        if (!self.dock_visible) return false;
        const w = self.view.screen_w;
        const h = self.view.screen_h;
        return Dock.of(w, h, self.tool).contains(p) or TopBar.of(w, h).contains(p) or PadBar.of(w, h).contains(p) or browsergeo.inside(browsergeo.Geo.of(w, h).folder, p);
    }

    /// Unsaved changes: the document changed, the padding changed, or the
    /// canvas background changed while the canvas holds some outside the
    /// image (the export would differ; neither is an undo step).
    pub fn dirty(self: *const Editor) bool {
        if (self.doc.revision != self.saved_revision) return true;
        if (self.settings.padding != self.saved_padding) return true;
        if (self.settings.canvas_bg == self.saved_bg) return false;
        const pic = self.doc.base();
        return !pic.contains(self.canvas);
    }

    pub fn markSaved(self: *Editor) void {
        self.saved_revision = self.doc.revision;
        self.saved_bg = self.settings.canvas_bg;
        self.saved_padding = self.settings.padding;
    }

    /// Start with `s` (config file, command line): nothing to save yet.
    pub fn startWith(self: *Editor, s: Settings) void {
        self.settings = s;
        self.saved_bg = s.canvas_bg;
        self.saved_padding = s.padding;
        self.canvas = extent.canvas(self.ctx(), self.doc);
        self.fit();
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
        self.browser.resize(w, h);
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
    pub fn syncView(self: *Editor) bool {
        if (self.doc.revision == self.canvas_rev) return false;
        self.canvas_rev = self.doc.revision;
        self.canvas = extent.canvas(self.ctx(), self.doc);
        const kept = self.doc.kept();
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
            .idle, .moving, .image_drag => null,
            .drag => |d| self.shapeFromDrag(d),
            .typing => |t| if (t.edit) |e| self.editedPreview(e) else switch (t.kind) {
                .text => .{ .text = .{ .pos = t.pos, .text = self.draft.items, .size = self.fontImg(), .color = c, .style = self.text_style } },
                .callout => self.routed(.{ .callout = .{ .target = t.target, .anchor = t.pos, .text = self.draft.items, .size = self.fontImg(), .color = c, .width = self.strokeImg(), .style = self.arrow_style } }),
            },
        };
    }

    /// The annotation under edit, with the draft as its text.
    fn editedPreview(self: *const Editor, e: Edit) Annotation {
        var a = e.before;
        switch (a) {
            .text => |*t| t.text = self.draft.items,
            .callout => |*c| c.text = self.draft.items,
            else => unreachable,
        }
        return route.best(self.ctx(), self.doc.items.items, e.index, a);
    }

    /// Enter text mode on the text or callout under `g`, keeping its look.
    fn startEdit(self: *Editor, g: Grab) !bool {
        const a = self.doc.items.items[g.index];
        const old = switch (a) {
            .text => |t| t.text,
            .callout => |c| c.text,
            else => return false,
        };
        self.clearDraft();
        try self.draft.appendSlice(self.gpa, old);
        self.caret = old.len;
        self.sel_anchor = old.len;
        self.doc.setLive(g.index, blankText(a));
        self.selected = g.index;
        self.mode = .{ .typing = switch (a) {
            .text => |t| .{ .kind = .text, .pos = t.pos, .edit = .{ .index = g.index, .before = a } },
            else => .{ .kind = .callout, .pos = a.callout.anchor, .target = a.callout.target, .edit = .{ .index = g.index, .before = a } },
        } };
        return true;
    }

    fn blankText(a: Annotation) Annotation {
        var b = a;
        switch (b) {
            .text => |*t| t.text = "",
            .callout => |*c| c.text = "",
            else => {},
        }
        return b;
    }

    /// Finish an edit: the draft becomes the text, as one undo step with the
    /// re-routes of the stairs paths around it. A blank or unchanged draft
    /// keeps the old text.
    fn commitEdit(self: *Editor, e: Edit) !void {
        const old = switch (e.before) {
            .text => |t| t.text,
            .callout => |c| c.text,
            else => unreachable,
        };
        const draft = self.draft.items;
        if (std.mem.trim(u8, draft, " \t\n").len == 0 or std.mem.eql(u8, draft, old)) return self.cancel();
        _ = try self.doc.setText(self.gpa, e.index, e.before, draft);
        var changed: [route.max_settle]route.Rerouted = undefined;
        const n = self.settle(e.index, e.before, &changed);
        self.mode = .idle;
        self.clearDraft();
        const step = try self.doc.commitMove(self.gpa, e.index, e.before);
        try self.commitRerouted(changed[0..n], e.index, step);
    }

    fn shapeFromDrag(self: *const Editor, d: Drag) ?Annotation {
        const c = self.currentColor();
        return switch (d.tool) {
            .arrow => self.routed(.{ .arrow = .{ .tail = d.start, .head = d.cur, .width = self.strokeImg(), .color = c, .style = self.arrow_style } }),
            .rect => .{ .rect = .{ .a = d.start, .b = d.cur, .width = self.strokeImg(), .color = c } },
            .pixelate => .{ .pixelate = .{ .a = d.start, .b = d.cur, .block = self.toImg(style.pixelate_block) } },
            .callout => self.routed(.{ .callout = .{ .target = d.cur, .anchor = d.start, .text = "", .size = self.fontImg(), .color = c, .width = self.strokeImg(), .style = self.arrow_style } }),
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
                var eff = if (ev == .key) try self.onKey(ev.key, was_armed) else try self.onDown(ev.mouse_down.x, ev.mouse_down.y, ev.mouse_down.button, ev.mouse_down.clicks);
                eff.redraw = eff.redraw or had_toast or was_armed;
                return eff;
            },
            .key_up => |k| {
                // Releasing Space ends the hand (and a drag with it).
                if (k.key == .char and k.key.char == ' ' and self.hand) {
                    self.hand = false;
                    self.panning = null;
                    return .{ .redraw = true };
                }
                return .{};
            },
            .mouse_up => |m| {
                if (m.button == .middle or (m.button == .left and self.hand)) {
                    self.panning = null;
                    return .{ .redraw = self.hand };
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
                if (self.slider_drag) {
                    self.sliderTo(m.x);
                    return .{ .redraw = true };
                }
                if (self.bdrag != null) {
                    try self.browserDragTo(Vec2.init(m.x, m.y));
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
                if (self.mode == .image_drag) {
                    try self.dragImageTo(Vec2.init(m.x, m.y));
                    return .{ .redraw = true };
                }
                var redraw = self.chromeHover().key() != hover_before;
                if (self.browserVisible()) redraw = self.hoverBrowser(Vec2.init(m.x, m.y)) or redraw;
                return .{ .redraw = redraw };
            },
            .wheel => |wh| {
                if (self.onBrowserPanel(.{ .x = wh.x, .y = wh.y }) and !wh.mods.ctrl) {
                    // The list scrolls (wheel up: delta > 0: toward the first row).
                    const step = self.browser.geo().row_h * 1.5;
                    return .{ .redraw = self.browser.scrollBy(-@as(f32, @floatFromInt(wh.delta)) * step) };
                }
                if (self.pointerOnSlider(wh.x, wh.y)) {
                    const changed = self.setPadding(settings.stepPadding(self.settings.padding, wh.delta));
                    return .{ .redraw = true, .command = if (changed) .save_settings else null };
                }
                if (wh.mods.ctrl) self.zoom(wh.delta, .{ .x = wh.x, .y = wh.y }) else self.changeSize(wh.delta);
                return .{ .redraw = true };
            },
            .resize => |r| {
                self.resize(r.w, r.h);
                return .{ .redraw = true };
            },
        }
    }

    /// The slider's step nearest to screen x.
    fn sliderTo(self: *Editor, x: f32) void {
        const bar = PadBar.of(self.view.screen_w, self.view.screen_h);
        _ = self.setPadding(settings.padding_steps[bar.stepAt(x)]);
    }

    fn pointerOnSlider(self: *const Editor, x: f32, y: f32) bool {
        if (!self.dock_visible or self.help_visible or self.mode == .drag or self.mode == .moving or self.mode == .image_drag) return false;
        return PadBar.of(self.view.screen_w, self.view.screen_h).contains(.{ .x = x, .y = y });
    }

    fn changeSize(self: *Editor, delta: i32) void {
        const n: i32 = @intCast(style.sizes.len);
        self.size_idx = @intCast(std.math.clamp(@as(i32, self.size_idx) + delta, 0, n - 1));
    }

    fn onDown(self: *Editor, x: f32, y: f32, button: input.Button, clicks: u8) !Effect {
        if (self.help_visible) { // any click closes the help
            self.help_visible = false;
            return .{ .redraw = true };
        }
        const p = Vec2.init(x, y);
        self.pointer = p;
        if (self.bdrag != null) self.cancelBrowserDrag(); // lost release: start over
        if (self.dock_visible and self.mode != .drag and self.mode != .moving and self.mode != .image_drag) {
            if (self.browser.hitAt(p)) |hit| return self.onBrowserDown(hit, p, button);
        }
        if (self.mode != .drag and self.mode != .moving and self.mode != .image_drag and self.onChrome(p)) {
            if (builtin.is_test and !self.chrome_press_ok) std.debug.panic("a test pressed at {d} {d} on the chrome (dock, top bar or padding widget): hide it (dock_visible = false), press elsewhere, or T.showChrome()", .{ x, y });
            if (button == .left) {
                if (Dock.of(self.view.screen_w, self.view.screen_h, self.tool).hit(p)) |h| switch (h) {
                    .tool => |t| try self.setTool(t),
                    .arrow_style => |st| self.setArrowStyle(st),
                    .text_style => |st| self.setTextStyle(st),
                    .color => |i| self.color_idx = i,
                    .size => self.size_idx = @intCast((@as(usize, self.size_idx) + 1) % style.sizes.len),
                    .help => self.help_visible = true,
                };
                if (TopBar.of(self.view.screen_w, self.view.screen_h).hit(p)) |b| switch (b) {
                    .undo => try self.undo(),
                    .redo => try self.redo(),
                    .canvas_bg => {
                        self.setCanvasBg(self.settings.canvas_bg.other());
                        return .{ .redraw = true, .command = .save_settings };
                    },
                };
                if (PadBar.of(self.view.screen_w, self.view.screen_h).contains(p)) {
                    self.slider_drag = true;
                    self.sliderTo(x);
                }
            }
            return .{ .redraw = true };
        }
        if (button == .right) {
            self.cancel();
            return .{ .redraw = true };
        }
        if (button == .middle) {
            if (self.mode != .drag and self.mode != .moving and self.mode != .image_drag) self.panning = .{ .x = x, .y = y };
            return .{};
        }
        if (button != .left) return .{};
        if (self.hand) { // the hand: pan, whatever the tool
            self.panning = .{ .x = x, .y = y };
            return .{ .redraw = true };
        }
        if (self.mode == .typing) try self.commitTyping();
        if (self.mode == .drag) self.mode = .idle; // lost release: start over
        if (self.mode == .moving) try self.finishMove(); // lost release: keep the move
        if (self.mode == .image_drag) self.cancel(); // lost release: start over
        const sp = Vec2.init(x, y);
        const ip = self.view.toImage(sp);
        if (self.tool == .move) {
            const grab = self.grabAt(sp);
            if (clicks >= 2 and button == .left) if (grab) |g| if (g.part == .whole and try self.startEdit(g)) return .{ .redraw = true };
            self.selected = if (grab) |g| g.index else null;
            if (grab) |g| {
                self.mode = .{ .moving = .{ .grab = g, .before = self.doc.items.items[g.index], .start = ip } };
            } else if (self.doc.scene.count() >= 2) if (self.doc.scene.imageAt(ip)) |i| {
                const im = self.doc.scene.images.items[i];
                self.mode = .{ .image_drag = .{ .id = im.id, .start_screen = sp, .grab = ip.sub(Vec2.init(@floatFromInt(im.x), @floatFromInt(im.y))) } };
            };
            return .{ .redraw = true };
        }
        if (!extent.reachable(extent.keptPad(self.ctx(), self.doc), ip)) {
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
        if (button == .left and self.bdrag != null) return self.finishBrowserDrag(Vec2.init(x, y));
        if (button == .left and self.slider_drag) {
            self.slider_drag = false;
            self.sliderTo(x);
            return .{ .redraw = true, .command = .save_settings };
        }
        if (button == .left and self.mode == .moving) {
            self.moveTo(self.view.toImage(.{ .x = x, .y = y }));
            try self.finishMove();
            return .{ .redraw = true };
        }
        if (button == .left and self.mode == .image_drag) {
            try self.finishImageDrag(Vec2.init(x, y));
            return .{ .redraw = true };
        }
        if (button != .left or self.mode != .drag) return .{};
        const d = self.mode.drag;
        const sp = Vec2.init(x, y);
        const ip = self.view.toImage(sp);
        self.mode = .idle;
        const is_click = sp.dist(d.start_screen) < click_slop;
        if (d.tool == .callout) {
            self.startTyping(.{ .kind = .callout, .pos = d.start, .target = if (is_click) null else ip });
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
            if (extent.fits(self.ctx(), extent.keptPad(self.ctx(), self.doc), a)) try self.addSettled(a) else self.tooFar();
        }
        return .{ .redraw = true };
    }

    /// Margin (fraction of the extent) kept around scene and slots when a
    /// drag zooms out to show them.
    const drag_margin = 0.08;

    /// The pointer moved with an image grabbed. Past the click slop the drag
    /// becomes active: the view makes room for the slots, then the overlay
    /// follows the pointer on every move.
    fn dragImageTo(self: *Editor, p: Vec2) !void {
        const d = &self.mode.image_drag;
        if (!d.active) {
            if (p.dist(d.start_screen) < click_slop) return;
            d.active = true;
            d.orig_xf = self.view.xf;
            d.orig_fitted = self.fitted;
            const o = self.doc.scene.images.items[self.doc.scene.indexOf(d.id).?];
            try self.makeRoomForSlots(d.id, o.w, o.h);
        }
        const im = self.doc.scene.images.items[self.doc.scene.indexOf(d.id).?];
        self.montage_drop = .{ .w = im.w, .h = im.h, .pointer = p, .exclude = d.id, .grab = d.grab };
    }

    /// Zoom out (one step, to the fit of the scene and all slots plus a
    /// margin) when a slot would fall outside the screen; else do nothing.
    /// The drop refits the whole scene, the cancel restores the view.
    fn makeRoomForSlots(self: *Editor, id: ?u32, w: i32, h: i32) !void {
        const list = try dropzone.slotList(self.gpa, self.doc, id, w, h);
        defer self.gpa.free(list);
        var all = self.doc.scene.bounds();
        var inside = true;
        const scr = self.view.screen();
        for (list) |s| {
            all = all.unite(s.rect);
            const r = self.view.rect(s.rect);
            inside = inside and std.meta.eql(r.intersect(scr), r);
        }
        if (inside) return;
        const mx: i32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(all.width())) * drag_margin));
        const my: i32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(all.height())) * drag_margin));
        const grown = geom.Rect{ .x0 = all.x0 - mx, .y0 = all.y0 - my, .x1 = all.x1 + mx, .y1 = all.y1 + my };
        self.view = View.fit(grown, self.view.screen_w, self.view.screen_h);
        self.fitted = false;
    }

    /// Release: drop at the nearest free slot, one undo step that carries
    /// the annotations. No slot, or never past the click slop: nothing.
    fn finishImageDrag(self: *Editor, p: Vec2) !void {
        const d = self.mode.image_drag;
        self.mode = .idle;
        self.montage_drop = null;
        if (!d.active) return;
        const im = self.doc.scene.images.items[self.doc.scene.indexOf(d.id).?];
        const list = try dropzone.slotList(self.gpa, self.doc, d.id, im.w, im.h);
        defer self.gpa.free(list);
        if (magnet.nearest(list, self.view.toImage(p))) |best| {
            _ = try self.doc.moveImage(self.gpa, d.id, best.rect.x0, best.rect.y0);
            _ = self.syncView();
            self.fit(); // the whole scene, like `0`
        } else self.restoreView(d.orig_xf, d.orig_fitted);
    }

    // ---- file browser input ------------------------------------------------

    /// Set the hover of the panel rows from the pointer. True if it changed.
    fn hoverBrowser(self: *Editor, p: Vec2) bool {
        const h: ?browsergeo.Hit = if (self.browser.hitAt(p)) |x| switch (x) {
            .up, .row => x,
            else => null,
        } else null;
        return self.browser.setHover(h);
    }

    /// A left press on the folder button or the panel (anything else is eaten).
    fn onBrowserDown(self: *Editor, hit: browsergeo.Hit, p: Vec2, button: input.Button) !Effect {
        if (button == .right) {
            self.cancel();
            return .{ .redraw = true };
        }
        if (button != .left) return .{ .redraw = true };
        switch (hit) {
            .folder => try self.browser.toggle(),
            .up => try self.browser.goUp(),
            .panel => {},
            .row => |i| {
                const is_image = if (self.browser.entryOf(i)) |e| !e.is_dir else false;
                if (is_image) {
                    self.bdrag = .{ .row = i, .start = p, .pointer = p };
                } else _ = try self.browser.activate(i); // a folder or `..`
            },
        }
        _ = self.browser.setHover(null);
        _ = self.hoverBrowser(p);
        return .{ .redraw = true };
    }

    /// The pointer moved with a row grabbed. Past the click slop the drag
    /// becomes active: the file header gives the size, the view makes room
    /// for the slots. Over the canvas the slots show, over the panel not.
    fn browserDragTo(self: *Editor, p: Vec2) !void {
        const d = &self.bdrag.?;
        d.pointer = p;
        if (!d.active) {
            if (p.dist(d.start) < click_slop) return;
            const size = self.browser.imageSize(d.row) orelse {
                self.bdrag = null;
                self.setToast("Cannot read this image.", .{});
                return;
            };
            d.active = true;
            d.w = @intCast(size[0]);
            d.h = @intCast(size[1]);
            d.orig_xf = self.view.xf;
            d.orig_fitted = self.fitted;
            _ = self.browser.setHover(null);
            try self.makeRoomForSlots(null, d.w, d.h);
        }
        self.montage_drop = if (self.onBrowserPanel(p)) null else .{ .w = d.w, .h = d.h, .pointer = p };
    }

    /// Release: over the canvas the image goes to the nearest free slot (the
    /// app adds it: `Command.add_image`); over the panel it is cancelled.
    fn finishBrowserDrag(self: *Editor, p: Vec2) !Effect {
        const d = self.bdrag.?;
        self.bdrag = null;
        self.montage_drop = null;
        if (!d.active) return .{ .redraw = true };
        if (self.onBrowserPanel(p)) {
            self.restoreView(d.orig_xf, d.orig_fitted);
            return .{ .redraw = true };
        }
        const list = try dropzone.slotList(self.gpa, self.doc, null, d.w, d.h);
        defer self.gpa.free(list);
        const best = magnet.nearest(list, self.view.toImage(p)) orelse {
            self.restoreView(d.orig_xf, d.orig_fitted);
            return .{ .redraw = true };
        };
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const e = self.browser.entryOf(d.row) orelse return .{ .redraw = true };
        const path = self.browser.pathOf(&buf, e.name) orelse return .{ .redraw = true };
        self.add_path.clearRetainingCapacity();
        try self.add_path.appendSlice(self.gpa, path);
        self.add_pos = .{ best.rect.x0, best.rect.y0 };
        self.add_pending = true;
        self.add_orig_xf = d.orig_xf;
        self.add_orig_fitted = d.orig_fitted;
        return .{ .redraw = true, .command = .add_image };
    }

    /// Drop the browser drag (Esc, right click, a lost release): the slots
    /// go and the view is restored.
    fn cancelBrowserDrag(self: *Editor) void {
        const d = self.bdrag orelse return;
        self.bdrag = null;
        self.montage_drop = null;
        if (d.active) self.restoreView(d.orig_xf, d.orig_fitted);
    }

    fn tooFar(self: *Editor) void {
        self.setToast("Too far from the image. The canvas grows only so far.", .{});
    }

    fn clearDraft(self: *Editor) void {
        self.draft.clearRetainingCapacity();
        self.caret = 0;
        self.sel_anchor = 0;
    }

    /// The caret and selection of the text in progress, for the renderer.
    pub fn textCaret(self: *const Editor) ?draw.Caret {
        if (self.mode != .typing) return null;
        return .{ .pos = self.caret, .anchor = self.sel_anchor };
    }

    /// Replace the selection (or nothing at the caret) by `bytes`.
    fn insertDraft(self: *Editor, bytes: []const u8) !void {
        const lo = @min(self.caret, self.sel_anchor);
        const hi = @max(self.caret, self.sel_anchor);
        try self.draft.replaceRange(self.gpa, lo, hi - lo, bytes);
        self.caret = lo + bytes.len;
        self.sel_anchor = self.caret;
    }

    /// Byte offset of the character boundary before / after `at`.
    fn prevBoundary(self: *const Editor, at: usize) usize {
        var i = at;
        while (i > 0) {
            i -= 1;
            if (self.draft.items[i] & 0xc0 != 0x80) break;
        }
        return i;
    }

    fn nextBoundary(self: *const Editor, at: usize) usize {
        var i = at;
        const n = self.draft.items.len;
        if (i < n) i += 1;
        while (i < n and self.draft.items[i] & 0xc0 == 0x80) i += 1;
        return i;
    }

    fn isWordByte(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
    }

    /// Start of the word before `at` (skips what is not a word first).
    fn prevWord(self: *const Editor, at: usize) usize {
        const s = self.draft.items;
        var i = at;
        while (i > 0 and !isWordByte(s[i - 1])) i -= 1;
        while (i > 0 and isWordByte(s[i - 1])) i -= 1;
        return i;
    }

    /// End of the word after `at` (skips what is not a word first).
    fn nextWord(self: *const Editor, at: usize) usize {
        const s = self.draft.items;
        var i = at;
        while (i < s.len and !isWordByte(s[i])) i += 1;
        while (i < s.len and isWordByte(s[i])) i += 1;
        return i;
    }

    /// Move the caret to `to`; with `extend` the selection grows, else it ends.
    fn moveCaret(self: *Editor, to: usize, extend: bool) void {
        self.caret = to;
        if (!extend) self.sel_anchor = to;
    }

    fn startTyping(self: *Editor, t: Typing) void {
        self.clearDraft();
        self.mode = .{ .typing = t };
    }

    /// Drop any shape or text in progress; put a moving annotation back.
    pub fn cancel(self: *Editor) void {
        if (self.bdrag != null) self.cancelBrowserDrag();
        if (self.mode == .moving) self.doc.setLive(self.mode.moving.grab.index, self.mode.moving.before);
        if (self.mode == .image_drag) {
            self.montage_drop = null;
            const d = self.mode.image_drag;
            if (d.active) self.restoreView(d.orig_xf, d.orig_fitted);
        }
        if (self.mode == .typing) if (self.mode.typing.edit) |e| self.doc.setLive(e.index, e.before);
        self.clearDraft();
        self.mode = .idle;
    }

    /// Turn the text in progress into an annotation (nothing if blank).
    pub fn commitTyping(self: *Editor) !void {
        if (self.mode != .typing) return;
        if (self.mode.typing.edit) |e| return self.commitEdit(e);
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
        if (self.mode == .typing and k.mods.ctrl and !k.mods.alt and k.key == .char and std.ascii.toLower(@intCast(@min(k.key.char, 127))) == 'a') {
            self.sel_anchor = 0; // Ctrl+A: select everything
            self.caret = self.draft.items.len;
            return .{ .redraw = true };
        }
        if (self.mode == .typing and k.mods.ctrl and !k.mods.alt and k.key == .named and (k.key.named == .left or k.key.named == .right)) {
            // Ctrl+Left / Ctrl+Right: one word; with Shift the selection grows by a word.
            self.moveCaret(if (k.key.named == .left) self.prevWord(self.caret) else self.nextWord(self.caret), k.mods.shift);
            return .{ .redraw = true };
        }
        if (self.mode == .typing and !k.mods.ctrl and !k.mods.alt) {
            switch (k.key) {
                .char => |cp| {
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch return .{};
                    try self.insertDraft(buf[0..n]); // over the selection
                    return .{ .redraw = true };
                },
                .named => |n| switch (n) {
                    .tab => {}, // not text: falls through to the key map (finish, next tool)
                    .enter => {
                        if (k.mods.shift) try self.insertDraft("\n") else try self.commitTyping();
                        return .{ .redraw = true };
                    },
                    .escape => {
                        try self.commitTyping();
                        return .{ .redraw = true };
                    },
                    .backspace, .delete => {
                        if (self.caret == self.sel_anchor) {
                            // Nothing selected: select the character before (Backspace) or after (Delete).
                            self.sel_anchor = if (n == .backspace) self.prevBoundary(self.caret) else self.nextBoundary(self.caret);
                        }
                        try self.insertDraft("");
                        return .{ .redraw = true };
                    },
                    .left, .right => {
                        const sel = self.caret != self.sel_anchor;
                        const lo = @min(self.caret, self.sel_anchor);
                        const hi = @max(self.caret, self.sel_anchor);
                        // Without Shift a selection ends at its near edge; else one character.
                        const to = if (sel and !k.mods.shift) (if (n == .left) lo else hi) else if (n == .left) self.prevBoundary(self.caret) else self.nextBoundary(self.caret);
                        self.moveCaret(to, k.mods.shift);
                        return .{ .redraw = true };
                    },
                    .home, .end => {
                        const s = self.draft.items;
                        const to = if (n == .home)
                            (if (std.mem.lastIndexOfScalar(u8, s[0..self.caret], '\n')) |i| i + 1 else 0)
                        else
                            (std.mem.indexOfScalarPos(u8, s, self.caret, '\n') orelse s.len);
                        self.moveCaret(to, k.mods.shift);
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
        self.selected = null;
        self.hand = false;
        if (t == .crop and self.tool != .crop) self.tool_before_crop = self.tool;
        self.tool = t;
    }

    /// Drop the shape or text in progress, else undo the last step.
    fn undo(self: *Editor) !void {
        if (self.mode != .idle) self.cancel() else {
            self.selected = null; // its index may mean another annotation after the step
            _ = try self.doc.undo(self.gpa);
        }
    }

    fn redo(self: *Editor) !void {
        self.cancel();
        self.selected = null;
        _ = try self.doc.redo(self.gpa);
    }

    /// Delete the selected annotation (move/select tool) as one undo step,
    /// with the re-routes of the stairs paths that it left (they go in the
    /// same step). Nothing selected: nothing.
    fn deleteSelected(self: *Editor) !void {
        const i = self.selected orelse return;
        if (self.tool != .move or self.mode != .idle) return;
        self.selected = null;
        self.hover = null;
        if (i >= self.doc.items.items.len) return;
        const region = draw.bodyBounds(self.ctx(), self.doc.items.items[i], .identity).toBounds();
        try self.doc.remove(self.gpa, i);
        var changed: [route.max_settle]route.Rerouted = undefined;
        const n = route.settle(self.ctx(), self.doc.items.items, region, &changed);
        try self.commitRerouted(changed[0..n], null, true);
    }

    /// Set the style of new arrows and callout pointers (a shape in
    /// progress follows) and say it, in the words of the active tool.
    fn setArrowStyle(self: *Editor, s: ann.ArrowStyle) void {
        self.arrow_style = s;
        self.setToast("{s}: {s}", .{ if (self.tool == .callout) "Pointer" else "Arrow", @tagName(s) });
    }

    /// Set the style of new texts (a text in progress follows) and say it.
    fn setTextStyle(self: *Editor, s: ann.TextStyle) void {
        self.text_style = s;
        self.setToast("Text: {s}", .{@tagName(s)});
    }

    /// Set the canvas background and say it. A setting, not an undo step:
    /// it changes no annotation and no export size, only the color around
    /// the image, so undo keeps walking the drawing.
    fn setCanvasBg(self: *Editor, bg: settings.CanvasBg) void {
        self.settings.canvas_bg = bg;
        self.setToast("Canvas: {s}", .{@tagName(bg)});
    }

    /// Set the canvas padding (a step of settings.padding_steps) and say it.
    /// A setting, not an undo step, like the canvas background: it changes
    /// no annotation, only the margin of the canvas and the export. The
    /// canvas changes, so the view refits.
    fn setPadding(self: *Editor, px: u16) bool {
        if (px == self.settings.padding) return false;
        self.settings.padding = px;
        self.canvas = extent.canvas(self.ctx(), self.doc);
        self.fit();
        self.setToast("Padding: {d} px", .{px});
        return true;
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
            .delete_selected => try self.deleteSelected(),
            .text_style => self.setTextStyle(if (self.text_style == .plain) .boxed else .plain),
            .canvas_bg => {
                self.setCanvasBg(self.settings.canvas_bg.other());
                return .{ .redraw = true, .command = .save_settings };
            },
            .padding_up, .padding_down => {
                const changed = self.setPadding(settings.stepPadding(self.settings.padding, if (action == .padding_up) 1 else -1));
                return .{ .redraw = true, .command = if (changed) .save_settings else null };
            },
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
                if (self.mode == .drag or self.mode == .moving or self.mode == .image_drag or self.bdrag != null) {
                    self.cancel();
                } else if (self.help_visible) {
                    self.help_visible = false;
                } else if (self.browser.open) {
                    self.browser.close();
                } else if (self.hand) {
                    self.hand = false;
                } else if (self.selected != null) {
                    self.selected = null;
                } else {
                    if (!self.dirty() or was_armed) return .{ .command = .quit };
                    self.quit_armed = true;
                    self.setToast("Unsaved changes. Esc or q again to quit, Ctrl+S to save, Ctrl+C to copy.", .{});
                }
            },
            .toggle_help => self.help_visible = !self.help_visible,
            .toggle_browser => try self.browser.toggle(),
            .toggle_dock => self.dock_visible = !self.dock_visible,
            .toggle_hand => if (!self.hand) { // held: a repeat changes nothing
                self.cancel();
                self.hand = true;
                self.selected = null;
            },
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
        self.doc.seed(std.testing.allocator, w, h, null) catch unreachable;
        self.ed = Editor.init(std.testing.allocator, &self.font, &self.doc, w, h);
        // The panels would cover most of a 200x100 screen; tests that click
        // them show them.
        self.ed.dock_visible = false;
        // Tests draw straight arrows unless they pick another tool or style
        // (set here, not the startup defaults).
        self.ed.tool = .arrow;
        self.ed.arrow_style = .straight;
    }
    /// Show the dock, the top bar and the padding widget, and allow presses on them.
    fn showChrome(self: *T) void {
        self.ed.dock_visible = true;
        self.ed.chrome_press_ok = true;
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
    /// An arrow drawn the way the user does: from its tail to its head.
    fn arrow(self: *T, tx: f32, ty: f32, hx: f32, hy: f32) !void {
        try self.drag(tx, ty, hx, hy);
    }
};

test "arrow drag adds one arrow; a click adds nothing" {
    var t = T{};
    t.init();
    defer t.deinit();
    try t.arrow(10, 10, 50, 40);
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
    t.showChrome();
    const d = Dock.of(1920, 1080, t.ed.tool);
    const tb = d.tools[dock.toolIndex(.rect)];
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = (tb.min.x + tb.max.x) / 2, .y = (tb.min.y + tb.max.y) / 2 } });
    _ = try t.ed.handle(.{ .mouse_up = .{ .x = (tb.min.x + tb.max.x) / 2, .y = (tb.min.y + tb.max.y) / 2 } });
    try std.testing.expectEqual(Tool.rect, t.ed.tool);
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
    _ = try t.key("h");
    try t.drag(d.panel.min.x + 2, d.panel.min.y + 2, d.panel.max.x - 2, d.panel.max.y - 2);
    try std.testing.expectEqual(@as(usize, 1), t.doc.items.items.len);
}

test "top bar: undo and redo by click, never draws, hover follows the pointer" {
    var t = T{};
    t.init();
    defer t.deinit();
    t.ed.resize(1920, 1080);
    t.showChrome();
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

test "startup: the callout tool with a stairs pointer; a drag with no key draws one" {
    var t = T{};
    t.init();
    defer t.deinit();
    // A fresh editor: T.init sets the tool and style of the other tests.
    var ed = Editor.init(std.testing.allocator, &t.font, &t.doc, 200, 100);
    defer ed.deinit();
    try std.testing.expectEqual(Tool.callout, ed.tool);
    try std.testing.expectEqual(ann.ArrowStyle.stairs, ed.arrow_style);
    ed.dock_visible = false; // the top bar would cover a 200 px wide screen
    _ = try ed.handle(.{ .mouse_down = .{ .x = 10, .y = 10 } });
    _ = try ed.handle(.{ .mouse_move = .{ .x = 120, .y = 70 } });
    _ = try ed.handle(.{ .mouse_up = .{ .x = 120, .y = 70 } });
    _ = try ed.handle(.{ .key = try input.parseChord("x") });
    _ = try ed.handle(.{ .key = try input.parseChord("enter") });
    const c = t.doc.items.items[0].callout;
    try std.testing.expectEqualStrings("x", c.text);
    try std.testing.expectEqual(ann.ArrowStyle.stairs, c.style);
}

test "callout drag then type" {
    var t = T{};
    t.init();
    defer t.deinit();
    _ = try t.key("c");
    try t.drag(80, 60, 10, 10);
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
    try t.drag(100, 60, 20, 20);
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
    try t.arrow(10, 90, 190, 90);
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
    t.showChrome();
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
    try t.arrow(10, 10, 190, 90); // right along y 10 to x 100, down to y 90, right to x 190
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
    t.showChrome();
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
    try t.drag(150, 70, 10, 10); // box right of x 150; pointer: left to x 80, up to y 10, left to x 10
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
        try t.arrow(first[0], first[1], first[2], first[3]);
        try std.testing.expectEqual(ann.Elbow{}, t.doc.items.items[0].arrow.elbow);
        try t.arrow(second[0], second[1], second[2], second[3]);
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
    try t.arrow(10, 10, 190, 90); // the middle segment at x 100
    _ = try t.key("a"); // straight
    try t.arrow(90, 50, 120, 50); // across that middle segment
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
    try t.arrow(10, 10, 190, 90); // the middle segment at x 100, its handle at (100, 50)
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
    try t.arrow(50, 30, 75, 30);
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

test "padding: keys step it, the canvas and the view follow, it is no undo step, it is unsaved" {
    var t = T{};
    t.init();
    defer t.deinit();
    try std.testing.expectEqual(@as(i32, 200), t.ed.canvas.width());
    const eff = try t.key(".");
    try std.testing.expectEqual(Command.save_settings, eff.command.?);
    try std.testing.expectEqual(@as(u16, 64), t.ed.settings.padding);
    try std.testing.expectEqual(@as(i32, 200 + 128), t.ed.canvas.width());
    try std.testing.expectEqual(@as(i32, 100 + 128), t.ed.canvas.height());
    try std.testing.expect(t.ed.view.xf.scale < 1); // refit
    try std.testing.expect(t.ed.dirty());
    try std.testing.expect(!t.ed.canUndo());
    _ = try t.key(",");
    try std.testing.expectEqual(@as(u16, 0), t.ed.settings.padding);
    try std.testing.expect(!t.ed.dirty());
    try std.testing.expectEqual(@as(?Command, null), (try t.key(",")).command); // at the first step
    for (0..9) |_| _ = try t.key(".");
    try std.testing.expectEqual(@as(u16, 192), t.ed.settings.padding);
    t.ed.markSaved();
    try std.testing.expect(!t.ed.dirty());
}

test "padding: a shape in the padding is added, shows, and keeps the canvas; undo works" {
    var t = T{};
    t.init();
    defer t.deinit();
    t.ed.startWith(.{ .padding = 128 });
    try std.testing.expectEqual(@as(i32, 200 + 256), t.ed.canvas.width());
    const s = t.ed.view.xf.scale;
    const o = t.ed.view.xf.offset;
    // An arrow from the image into the left padding (image x -100).
    try t.drag(o.x + 100 * s, o.y + 50 * s, o.x - 100 * s, o.y + 50 * s);
    try std.testing.expectEqual(@as(usize, 1), t.doc.items.items.len);
    try std.testing.expectEqual(@as(i32, 200 + 256), t.ed.canvas.width());
    _ = try t.key("ctrl+z");
    try std.testing.expectEqual(@as(usize, 0), t.doc.items.items.len);
}

test "padding slider: click and drag snap to notches, wheel steps, release saves" {
    var t = T{};
    t.init();
    defer t.deinit();
    t.ed.resize(1920, 1080);
    t.showChrome();
    const b = PadBar.of(1920, 1080);
    const y = b.trackY();
    var eff = try t.ed.handle(.{ .mouse_down = .{ .x = b.notchX(2) + 3, .y = y } });
    try std.testing.expectEqual(@as(?Command, null), eff.command);
    try std.testing.expectEqual(@as(u16, 96), t.ed.settings.padding);
    _ = try t.ed.handle(.{ .mouse_move = .{ .x = b.notchX(4), .y = y + 200 } }); // a drag follows x only
    try std.testing.expectEqual(@as(u16, 192), t.ed.settings.padding);
    eff = try t.ed.handle(.{ .mouse_up = .{ .x = b.notchX(1), .y = y } });
    try std.testing.expectEqual(Command.save_settings, eff.command.?);
    try std.testing.expectEqual(@as(u16, 64), t.ed.settings.padding);
    try std.testing.expectEqual(@as(usize, 0), t.doc.items.items.len); // never draws
    const m = b.slot.min.add(b.slot.max).scale(0.5);
    eff = try t.ed.handle(.{ .wheel = .{ .delta = 1, .x = m.x, .y = m.y } });
    try std.testing.expectEqual(@as(u16, 96), t.ed.settings.padding);
    try std.testing.expectEqual(Command.save_settings, eff.command.?);
    _ = try t.ed.handle(.{ .wheel = .{ .delta = -3, .x = m.x, .y = m.y } });
    try std.testing.expectEqual(@as(u16, 0), t.ed.settings.padding);
    try std.testing.expectEqual(style.default_size, t.ed.size_idx); // the wheel did not change the size
}

test "text style: plain at start, `t` again and the switch change it for new texts" {
    var t = T{};
    t.init();
    defer t.deinit();
    _ = try t.key("t");
    try std.testing.expectEqual(ann.TextStyle.plain, t.ed.text_style);
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 20, .y = 20 } });
    _ = try t.key("a");
    try std.testing.expectEqual(ann.TextStyle.plain, t.ed.preview().?.text.style);
    _ = try t.key("enter");
    try std.testing.expectEqual(ann.TextStyle.plain, t.doc.items.items[0].text.style);
    _ = try t.key("t"); // the text tool is active: a second press
    try std.testing.expectEqual(ann.TextStyle.boxed, t.ed.text_style);
    try std.testing.expectEqualStrings("Text: boxed", t.ed.toast().?);
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 20, .y = 60 } });
    _ = try t.key("b");
    _ = try t.key("enter");
    try std.testing.expectEqual(ann.TextStyle.boxed, t.doc.items.items[1].text.style);
    try std.testing.expectEqual(ann.TextStyle.plain, t.doc.items.items[0].text.style);
}

test "text mode: caret, Shift+arrows select, typing overwrites the selection, Ctrl+A selects all" {
    var t = T{};
    t.init();
    defer t.deinit();
    t.ed.tool = .text;
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 20, .y = 20 } });
    _ = try t.ed.handle(.{ .mouse_up = .{ .x = 20, .y = 20 } });
    for ("hello") |ch| _ = try t.ed.handle(.{ .key = .{ .key = .{ .char = ch } } });
    try std.testing.expectEqualStrings("hello", t.ed.draft.items);
    // Shift+Left twice selects "lo"; typing replaces it.
    _ = try t.key("shift+left");
    _ = try t.key("shift+left");
    try std.testing.expectEqual(@as(usize, 3), t.ed.caret);
    try std.testing.expectEqual(@as(usize, 5), t.ed.sel_anchor);
    _ = try t.ed.handle(.{ .key = .{ .key = .{ .char = 'p' } } });
    try std.testing.expectEqualStrings("help", t.ed.draft.items);
    // Left moves the caret; typing inserts there; Backspace and Delete cut around it.
    _ = try t.key("left");
    _ = try t.ed.handle(.{ .key = .{ .key = .{ .char = 'X' } } });
    try std.testing.expectEqualStrings("helXp", t.ed.draft.items);
    _ = try t.key("backspace");
    _ = try t.key("delete");
    try std.testing.expectEqualStrings("hel", t.ed.draft.items);
    // Left with a selection ends it at its left edge; Home and End; Shift+Home selects to the start.
    _ = try t.key("shift+left");
    _ = try t.key("left");
    try std.testing.expectEqual(@as(usize, 2), t.ed.caret);
    try std.testing.expectEqual(@as(usize, 2), t.ed.sel_anchor);
    _ = try t.key("end");
    _ = try t.key("shift+home");
    try std.testing.expectEqual(@as(usize, 0), t.ed.caret);
    try std.testing.expectEqual(@as(usize, 3), t.ed.sel_anchor);
    // Ctrl+Left / Ctrl+Shift+Left go by words.
    _ = try t.key("ctrl+a");
    for (" big old") |ch| _ = try t.ed.handle(.{ .key = .{ .key = .{ .char = ch } } });
    try std.testing.expectEqualStrings(" big old", t.ed.draft.items);
    _ = try t.key("ctrl+left");
    try std.testing.expectEqual(@as(usize, 5), t.ed.caret);
    _ = try t.key("ctrl+shift+left");
    try std.testing.expectEqual(@as(usize, 1), t.ed.caret);
    try std.testing.expectEqual(@as(usize, 5), t.ed.sel_anchor);
    _ = try t.key("ctrl+shift+right");
    _ = try t.key("ctrl+shift+right");
    try std.testing.expectEqual(@as(usize, 8), t.ed.caret);
    try std.testing.expectEqual(@as(usize, 5), t.ed.sel_anchor);
    // Ctrl+A then a key overwrites everything; the text is committed whole.
    _ = try t.key("ctrl+a");
    _ = try t.ed.handle(.{ .key = .{ .key = .{ .char = 'o' } } });
    _ = try t.ed.handle(.{ .key = .{ .key = .{ .char = 'k' } } });
    _ = try t.key("enter");
    try std.testing.expectEqualStrings("ok", t.doc.items.items[0].text.text);
}

test "hand mode: on while Space is held, a left drag pans, no drawing; release, Esc and a tool key leave it; cursors" {
    var t = T{};
    t.init();
    defer t.deinit();
    const up = input.Event{ .key_up = .{ .key = .{ .char = ' ' } } };
    try std.testing.expectEqual(Editor.Cursor.crosshair, t.ed.cursor());
    _ = try t.key("m");
    try std.testing.expectEqual(Editor.Cursor.move, t.ed.cursor());
    _ = try t.key("space");
    _ = try t.key("space"); // a repeat keeps it on
    try std.testing.expect(t.ed.hand);
    try std.testing.expectEqual(Editor.Cursor.grab, t.ed.cursor());
    const off = t.ed.view.xf.offset;
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 100, .y = 50 } });
    try std.testing.expectEqual(Editor.Cursor.grabbing, t.ed.cursor());
    _ = try t.ed.handle(.{ .mouse_move = .{ .x = 130, .y = 60 } });
    _ = try t.ed.handle(.{ .mouse_up = .{ .x = 130, .y = 60 } });
    try std.testing.expectEqual(Editor.Cursor.grab, t.ed.cursor());
    try std.testing.expectEqual(off.x + 30, t.ed.view.xf.offset.x);
    try std.testing.expectEqual(@as(usize, 0), t.doc.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), t.doc.history.items.len);
    // Released: back to the tool, even in the middle of a drag.
    _ = try t.ed.handle(up);
    try std.testing.expect(!t.ed.hand);
    try std.testing.expectEqual(Editor.Cursor.move, t.ed.cursor());
    _ = try t.key("space");
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 100, .y = 50 } });
    _ = try t.ed.handle(up);
    try std.testing.expect(t.ed.panning == null);
    _ = try t.key("space");
    _ = try t.key("esc"); // leaves the hand, does not quit
    try std.testing.expect(!t.ed.hand);
    _ = try t.key("space");
    _ = try t.key("a");
    try std.testing.expect(!t.ed.hand);
}

test "move/select: a double click edits the text in place; one undo step; blank or unchanged keeps it" {
    var t = T{};
    t.init();
    defer t.deinit();
    t.ed.tool = .text;
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 20, .y = 20 } });
    _ = try t.ed.handle(.{ .mouse_up = .{ .x = 20, .y = 20 } });
    for ("ab") |ch| _ = try t.ed.handle(.{ .key = .{ .key = .{ .char = ch } } });
    _ = try t.key("enter");
    _ = try t.key("m");
    const dbl = input.Event{ .mouse_down = .{ .x = 22, .y = 25, .clicks = 2 } };
    const h = t.doc.history.items.len;
    // A single click only selects.
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 22, .y = 25 } });
    _ = try t.ed.handle(.{ .mouse_up = .{ .x = 22, .y = 25 } });
    try std.testing.expect(t.ed.mode == .idle);
    // A double click enters text mode on the same element, with its text.
    _ = try t.ed.handle(dbl);
    _ = try t.ed.handle(.{ .mouse_up = .{ .x = 22, .y = 25 } });
    try std.testing.expect(t.ed.mode == .typing);
    try std.testing.expectEqualStrings("ab", t.ed.draft.items);
    try std.testing.expectEqual(@as(usize, 1), t.doc.items.items.len);
    // Esc with the text unchanged keeps it and records nothing.
    _ = try t.key("esc");
    try std.testing.expectEqualStrings("ab", t.doc.items.items[0].text.text);
    try std.testing.expectEqual(h, t.doc.history.items.len);
    // New text: one step; undo and redo swap the texts.
    _ = try t.ed.handle(dbl);
    _ = try t.ed.handle(.{ .mouse_up = .{ .x = 22, .y = 25 } });
    _ = try t.key("backspace");
    _ = try t.ed.handle(.{ .key = .{ .key = .{ .char = 'z' } } });
    _ = try t.key("enter");
    try std.testing.expectEqualStrings("az", t.doc.items.items[0].text.text);
    try std.testing.expectEqual(h + 1, t.doc.history.items.len);
    _ = try t.key("ctrl+z");
    try std.testing.expectEqualStrings("ab", t.doc.items.items[0].text.text);
    _ = try t.key("ctrl+shift+z");
    try std.testing.expectEqualStrings("az", t.doc.items.items[0].text.text);
    // Blank keeps the old text; quitting mid-edit leaves nothing behind (leak check).
    _ = try t.ed.handle(dbl);
    _ = try t.ed.handle(.{ .mouse_up = .{ .x = 22, .y = 25 } });
    _ = try t.key("backspace");
    _ = try t.key("backspace");
    _ = try t.key("enter");
    try std.testing.expectEqualStrings("az", t.doc.items.items[0].text.text);
    _ = try t.ed.handle(dbl);
    _ = try t.ed.handle(.{ .mouse_up = .{ .x = 22, .y = 25 } });
    try std.testing.expect(t.ed.mode == .typing);
}

test "move/select: a press selects, Delete deletes as one undo step, undo restores, Esc and other tools clear" {
    var t = T{};
    t.init();
    defer t.deinit();
    try t.arrow(10, 10, 60, 40);
    try t.arrow(10, 70, 90, 70);
    _ = try t.key("m");
    try std.testing.expectEqual(@as(?usize, null), t.ed.selected);
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 35, .y = 25 } });
    _ = try t.ed.handle(.{ .mouse_up = .{ .x = 35, .y = 25 } });
    try std.testing.expectEqual(@as(?usize, 0), t.ed.selected);
    // The pointer leaves: the outline stays.
    _ = try t.ed.handle(.{ .mouse_move = .{ .x = 150, .y = 90 } });
    try std.testing.expectEqual(@as(?Grab, .{ .index = 0, .part = .whole }), t.ed.outlined());
    // Esc clears the selection first; it does not quit.
    const eff = try t.key("esc");
    try std.testing.expectEqual(@as(?usize, null), t.ed.selected);
    try std.testing.expectEqual(@as(?Command, null), eff.command);
    try std.testing.expectEqual(@as(?Grab, null), t.ed.outlined());
    // Delete with nothing selected does nothing.
    _ = try t.key("delete");
    try std.testing.expectEqual(@as(usize, 2), t.doc.items.items.len);
    // Select the second, Backspace deletes it.
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 50, .y = 70 } });
    _ = try t.ed.handle(.{ .mouse_up = .{ .x = 50, .y = 70 } });
    try std.testing.expectEqual(@as(?usize, 1), t.ed.selected);
    const h = t.doc.history.items.len;
    _ = try t.key("backspace");
    try std.testing.expectEqual(@as(usize, 1), t.doc.items.items.len);
    try std.testing.expectEqual(h + 1, t.doc.history.items.len);
    try std.testing.expectEqual(@as(?usize, null), t.ed.selected);
    _ = try t.key("ctrl+z");
    try std.testing.expectEqual(@as(usize, 2), t.doc.items.items.len);
    try std.testing.expectEqual(@as(f32, 90), t.doc.items.items[1].arrow.head.x);
    _ = try t.key("ctrl+shift+z");
    try std.testing.expectEqual(@as(usize, 1), t.doc.items.items.len);
    // A click on empty space and a tool switch clear the selection.
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 35, .y = 25 } });
    _ = try t.ed.handle(.{ .mouse_up = .{ .x = 35, .y = 25 } });
    try std.testing.expectEqual(@as(?usize, 0), t.ed.selected);
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 150, .y = 90 } });
    _ = try t.ed.handle(.{ .mouse_up = .{ .x = 150, .y = 90 } });
    try std.testing.expectEqual(@as(?usize, null), t.ed.selected);
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 35, .y = 25 } });
    _ = try t.ed.handle(.{ .mouse_up = .{ .x = 35, .y = 25 } });
    _ = try t.key("a");
    try std.testing.expectEqual(@as(?usize, null), t.ed.selected);
    _ = try t.key("delete");
    try std.testing.expectEqual(@as(usize, 1), t.doc.items.items.len);
}

/// Two 400x200 images (a at 0,0, b at 464,0) on a 400x200 screen, move tool.
fn montageT(t: *T) !void {
    t.initSize(400, 200);
    _ = try t.doc.addImage(std.testing.allocator, 400, 200, 464, 0, null, false);
    _ = t.ed.syncView();
    t.ed.tool = .move;
}

fn mouse(t: *T, x: f32, y: f32, what: enum { down, move, up }) !void {
    switch (what) {
        .down => _ = try t.ed.handle(.{ .mouse_down = .{ .x = x, .y = y } }),
        .move => _ = try t.ed.handle(.{ .mouse_move = .{ .x = x, .y = y } }),
        .up => _ = try t.ed.handle(.{ .mouse_up = .{ .x = x, .y = y } }),
    }
}

test "image drag: drops at the nearest free slot as one undo step, with its annotations" {
    var t = T{};
    try montageT(&t);
    defer t.deinit();
    const b = t.doc.scene.images.items[1];
    try t.doc.add(std.testing.allocator, .{ .rect = .{ .a = Vec2.init(500, 20), .b = Vec2.init(600, 80), .color = t.ed.currentColor(), .width = 4 } });
    const h = t.doc.history.items.len;
    const v = t.ed.view;
    const press = v.toScreen(Vec2.init(700, 150));
    try mouse(&t, press.x, press.y, .down);
    try std.testing.expect(t.ed.mode == .image_drag);
    try std.testing.expect(t.ed.montage_drop == null); // not before the slop
    try std.testing.expectEqual(Editor.Cursor.move, t.ed.cursor());
    // Under image a (scene 200,264): the bottom slot of a.
    const to = v.toScreen(Vec2.init(200, 330));
    try mouse(&t, to.x, to.y, .move);
    try std.testing.expectEqual(Editor.Cursor.grabbing, t.ed.cursor());
    try std.testing.expect(t.ed.montage_drop != null);
    try std.testing.expectEqual(b.id, t.ed.montage_drop.?.exclude.?);
    try std.testing.expectEqual(h, t.doc.history.items.len); // nothing recorded while dragging
    try std.testing.expect(t.ed.view.xf.scale < v.xf.scale); // zoomed out: the slots were off screen
    try mouse(&t, to.x, to.y, .up);
    try std.testing.expect(t.ed.mode == .idle);
    try std.testing.expect(t.ed.montage_drop == null);
    const nb = t.doc.scene.images.items[1];
    try std.testing.expectEqual(@as(i32, 0), nb.x);
    try std.testing.expectEqual(@as(i32, 264), nb.y);
    try std.testing.expectEqual(h + 1, t.doc.history.items.len);
    try std.testing.expectEqual(@as(f32, 36), t.doc.items.items[0].rect.a.x); // moved by -464
    try std.testing.expectEqual(@as(f32, 284), t.doc.items.items[0].rect.a.y); // and by 264
    _ = try t.key("ctrl+z");
    try std.testing.expectEqual(@as(i32, 464), t.doc.scene.images.items[1].x);
    try std.testing.expectEqual(@as(f32, 500), t.doc.items.items[0].rect.a.x);
}

test "image drag: the slots hang on the other images; a drag into nothing, a click, Esc and right click change nothing" {
    var t = T{};
    try montageT(&t);
    defer t.deinit();
    const h = t.doc.history.items.len;
    const v = t.ed.view;
    const press = v.toScreen(Vec2.init(700, 150));
    // A click.
    try mouse(&t, press.x, press.y, .down);
    try mouse(&t, press.x + 1, press.y, .move);
    try mouse(&t, press.x + 1, press.y, .up);
    try std.testing.expect(t.ed.montage_drop == null);
    try std.testing.expectEqual(h, t.doc.history.items.len);
    // Esc.
    try mouse(&t, press.x, press.y, .down);
    try mouse(&t, press.x - 40, press.y + 20, .move);
    try std.testing.expect(t.ed.montage_drop != null);
    _ = try t.key("esc");
    try std.testing.expect(t.ed.mode == .idle);
    try std.testing.expect(t.ed.montage_drop == null);
    // Right click.
    try mouse(&t, press.x, press.y, .down);
    try mouse(&t, press.x - 40, press.y + 20, .move);
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 10, .y = 10, .button = .right } });
    try std.testing.expect(t.ed.mode == .idle and t.ed.montage_drop == null);
    // Back at its own slot: the release is a no-op, not a step.
    try mouse(&t, press.x, press.y, .down);
    try mouse(&t, press.x - 40, press.y, .move);
    try mouse(&t, press.x - 40, press.y, .up);
    try std.testing.expectEqual(h, t.doc.history.items.len);
    try std.testing.expectEqual(@as(i32, 464), t.doc.scene.images.items[1].x);
}

test "image drag: an annotation under the press keeps priority; one image has no drag" {
    var t = T{};
    try montageT(&t);
    defer t.deinit();
    try t.doc.add(std.testing.allocator, .{ .rect = .{ .a = Vec2.init(500, 20), .b = Vec2.init(600, 80), .color = t.ed.currentColor(), .width = 4 } });
    const on = t.ed.view.toScreen(Vec2.init(500, 50));
    try mouse(&t, on.x, on.y, .down);
    try std.testing.expect(t.ed.mode == .moving);
    try mouse(&t, on.x, on.y, .up);
    _ = try t.doc.removeImage(std.testing.allocator, t.doc.scene.images.items[1].id);
    try mouse(&t, 100, 100, .down);
    try std.testing.expect(t.ed.mode == .idle);
}

test "image drag: the drop refits the whole scene at once" {
    var t = T{};
    try montageT(&t);
    defer t.deinit();
    const v = t.ed.view;
    const press = v.toScreen(Vec2.init(700, 150));
    try mouse(&t, press.x, press.y, .down);
    const to = v.toScreen(Vec2.init(200, 330));
    try mouse(&t, to.x, to.y, .move);
    try std.testing.expect(t.ed.view.xf.scale < v.xf.scale); // zoomed out for the slots
    try mouse(&t, to.x, to.y, .up);
    try std.testing.expectEqual(@as(i32, 264), t.doc.scene.images.items[1].y);
    try std.testing.expect(t.ed.fitted);
    try std.testing.expect(std.meta.eql(View.fit(t.ed.canvas, v.screen_w, v.screen_h).xf, t.ed.view.xf));
}

test "image drag: Esc restores exactly the original view at once" {
    var t = T{};
    try montageT(&t);
    defer t.deinit();
    const v = t.ed.view;
    const press = v.toScreen(Vec2.init(700, 150));
    try mouse(&t, press.x, press.y, .down);
    try mouse(&t, press.x - 40, press.y + 20, .move);
    try std.testing.expect(t.ed.view.xf.scale < v.xf.scale);
    _ = try t.key("esc");
    try std.testing.expect(std.meta.eql(v.xf, t.ed.view.xf));
    try std.testing.expect(t.ed.fitted);
}

test "fit: the whole multi-image scene and the padding fit the screen" {
    var t = T{};
    try montageT(&t);
    defer t.deinit();
    t.ed.view.xf = .{ .scale = 3, .offset = .{ .x = -900, .y = 40 } };
    t.ed.fitted = false;
    _ = try t.key("0");
    try std.testing.expect(t.ed.fitted);
    const all = t.doc.scene.bounds();
    try std.testing.expect(t.ed.canvas.width() >= all.width() and t.ed.canvas.height() >= all.height());
    const r = t.ed.view.rect(t.ed.canvas);
    const scr = t.ed.view.screen();
    try std.testing.expect(std.meta.eql(r.intersect(scr), r)); // all of it shows
    for (t.doc.scene.images.items) |im| {
        const ir = t.ed.view.rect(.{ .x0 = im.x, .y0 = im.y, .x1 = im.x + im.w, .y1 = im.y + im.h });
        try std.testing.expect(std.meta.eql(ir.intersect(scr), ir));
    }
    // Centred: the margins left and right differ by at most a pixel.
    try std.testing.expect(@abs(r.x0 - (@as(i32, @intCast(scr.x1)) - r.x1)) <= 1);
}

// ---- file browser tests ---------------------------------------------------

/// A folder with `n` small PNGs (mtimes 1000, 1100, ...): newest is the last.
fn browserFixture(tmp: *std.testing.TmpDir, n: usize) ![]u8 {
    const Canvas = @import("canvas.zig").Canvas;
    const image_io = @import("image_io.zig");
    const gpa = std.testing.allocator;
    const dir = try tmp.dir.realpathAlloc(gpa, ".");
    errdefer gpa.free(dir);
    var cv = try Canvas.init(gpa, 60, 40);
    defer cv.deinit(gpa);
    @memset(cv.pixels, 0xff224466);
    for (0..n) |i| {
        var nb: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&nb, "img{d:0>2}.png", .{i});
        const p = try std.fs.path.join(gpa, &.{ dir, name });
        defer gpa.free(p);
        try image_io.savePng(gpa, &cv, p);
        var f = try tmp.dir.openFile(name, .{ .mode = .read_write });
        defer f.close();
        const t: i128 = (1000 + @as(i128, @intCast(i)) * 100) * std.time.ns_per_s;
        try f.updateTimes(t, t);
    }
    return dir;
}

fn centerOf(b: geom.Bounds) Vec2 {
    return b.min.add(b.max).scale(0.5);
}

fn browserMouse(t: *T, kind: enum { down, move, up }, p: Vec2) !Effect {
    return switch (kind) {
        .down => t.ed.handle(.{ .mouse_down = .{ .x = p.x, .y = p.y } }),
        .move => t.ed.handle(.{ .mouse_move = .{ .x = p.x, .y = p.y } }),
        .up => t.ed.handle(.{ .mouse_up = .{ .x = p.x, .y = p.y } }),
    };
}

test "browser: o opens it, Esc closes it before anything else, then quits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try browserFixture(&tmp, 2);
    defer std.testing.allocator.free(dir);
    var t = T{};
    t.initSize(800, 600);
    defer t.deinit();
    t.ed.dock_visible = true;
    try t.ed.browser.setHome(dir);
    _ = try t.key("o");
    try std.testing.expect(t.ed.browserVisible());
    try std.testing.expectEqual(@as(?Command, null), (try t.key("esc")).command);
    try std.testing.expect(!t.ed.browser.open);
    try std.testing.expectEqual(Command.quit, (try t.key("esc")).command.?);
    // The folder button toggles it too; `h` hides the panel with the others.
    t.ed.chrome_press_ok = true;
    const btn = centerOf(browsergeo.Geo.of(800, 600).folder);
    _ = try browserMouse(&t, .down, btn);
    try std.testing.expect(t.ed.browserVisible());
    _ = try t.key("h");
    try std.testing.expect(!t.ed.browserVisible());
}

test "browser: the wheel over the panel scrolls the list, not the size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try browserFixture(&tmp, 12);
    defer std.testing.allocator.free(dir);
    var t = T{};
    t.initSize(800, 400);
    defer t.deinit();
    t.ed.dock_visible = true;
    try t.ed.browser.setHome(dir);
    _ = try t.key("o");
    const g = t.ed.browser.geo();
    const p = centerOf(g.list);
    const size0 = t.ed.size_idx;
    _ = try t.ed.handle(.{ .wheel = .{ .delta = -1, .x = p.x, .y = p.y } });
    try std.testing.expect(t.ed.browser.scroll > 0);
    try std.testing.expectEqual(size0, t.ed.size_idx);
    _ = try t.ed.handle(.{ .wheel = .{ .delta = 1000, .x = p.x, .y = p.y } });
    try std.testing.expectEqual(@as(f32, 0), t.ed.browser.scroll);
    _ = try t.ed.handle(.{ .wheel = .{ .delta = -1000, .x = p.x, .y = p.y } });
    try std.testing.expectEqual(g.maxScroll(t.ed.browser.rowCount()), t.ed.browser.scroll);
    // Off the panel the wheel still changes the size.
    _ = try t.ed.handle(.{ .wheel = .{ .delta = 1, .x = 700, .y = 200 } });
    try std.testing.expect(t.ed.size_idx != size0);
}

test "browser drag: slop, slots over the canvas, cancel, drop over the panel, drop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try browserFixture(&tmp, 3);
    defer std.testing.allocator.free(dir);
    var t = T{};
    t.initSize(800, 600);
    defer t.deinit();
    t.ed.dock_visible = true;
    try t.ed.browser.setHome(dir);
    _ = try t.key("o");
    const g = t.ed.browser.geo();
    const row = g.row(1, 0); // `..` is row 0; the newest image, img02, row 1
    try std.testing.expectEqualStrings("img02.png", t.ed.browser.entryOf(1).?.name);
    const p0 = centerOf(row);
    const view0 = t.ed.view;

    // Under the slop: a click on an image does nothing.
    _ = try browserMouse(&t, .down, p0);
    try std.testing.expect(t.ed.bdrag != null);
    _ = try browserMouse(&t, .move, p0.add(.{ .x = 2, .y = 0 }));
    try std.testing.expect(t.ed.browserGhost() == null);
    const up = try browserMouse(&t, .up, p0.add(.{ .x = 2, .y = 0 }));
    try std.testing.expectEqual(@as(?Command, null), up.command);
    try std.testing.expect(t.ed.bdrag == null);

    // Past the slop: active, a ghost; over the canvas the slots show, over the panel not.
    _ = try browserMouse(&t, .down, p0);
    _ = try browserMouse(&t, .move, .{ .x = 600, .y = 300 });
    try std.testing.expect(t.ed.browserGhost() != null);
    try std.testing.expectEqual(@as(i32, 60), t.ed.montage_drop.?.w);
    try std.testing.expectEqual(@as(i32, 40), t.ed.montage_drop.?.h);
    try std.testing.expect(t.ed.montage_drop.?.exclude == null);
    _ = try browserMouse(&t, .move, p0.add(.{ .x = 10, .y = 10 }));
    try std.testing.expect(t.ed.montage_drop == null);
    try std.testing.expect(t.ed.browserGhost() != null);

    // Esc cancels: nothing pending, no history, the view goes back.
    _ = try t.key("esc");
    try std.testing.expect(t.ed.bdrag == null and t.ed.montage_drop == null);
    try std.testing.expectEqual(view0.xf, t.ed.view.xf);
    try std.testing.expect(t.ed.browser.open); // Esc cancelled the drag only
    try std.testing.expectEqual(@as(usize, 0), t.doc.history.items.len);

    // Released over the panel: cancelled too.
    _ = try browserMouse(&t, .down, p0);
    _ = try browserMouse(&t, .move, .{ .x = 600, .y = 300 });
    const over = try browserMouse(&t, .up, p0.add(.{ .x = 10, .y = 10 }));
    try std.testing.expectEqual(@as(?Command, null), over.command);
    try std.testing.expect(t.ed.takeAdd() == null);

    // Right click cancels.
    _ = try browserMouse(&t, .down, p0);
    _ = try browserMouse(&t, .move, .{ .x = 600, .y = 300 });
    _ = try t.ed.handle(.{ .mouse_down = .{ .x = 600, .y = 300, .button = .right } });
    try std.testing.expect(t.ed.bdrag == null);

    // Released over the canvas: the app is asked to add the file at the nearest slot.
    _ = try browserMouse(&t, .down, p0);
    _ = try browserMouse(&t, .move, .{ .x = 700, .y = 300 });
    const drop = try browserMouse(&t, .up, .{ .x = 700, .y = 300 });
    try std.testing.expectEqual(Command.add_image, drop.command.?);
    const add = t.ed.takeAdd().?;
    try std.testing.expect(std.mem.endsWith(u8, add.path, "/img02.png"));
    try std.testing.expectEqual(@as(i32, 800 + magnet.gap), add.x); // right of the 800 px wide image
    try std.testing.expect(t.ed.takeAdd() == null);
    t.ed.imageAdded();
    try std.testing.expect(t.ed.fitted);
}
