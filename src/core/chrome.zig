//! UI chrome drawn over the image, in the Nord theme: the icon dock (tools,
//! colors, size, help button, the pointer style switch; geometry in dock.zig), the top bar (undo,
//! redo, canvas background; geometry in topbar.zig), the padding widget at the
//! bottom right (a slider; geometry in padbar.zig), the help overlay with
//! every shortcut (from keymap.zig, behind `?`/F1), and the toast pill at the
//! top. Everything scales with style.uiScale. Crisp flat look:
//! panels with the screen background color and a grid-colored 1 px border, square
//! corners, no glow, blur, shadow or gradient. Layout is
//! computed into a list of draw ops, so `rects` (for damage) and `draw` share
//! one code path.
const std = @import("std");
const geom = @import("geom.zig");
const sdf = @import("sdf.zig");
const raster = @import("raster.zig");
const text = @import("text.zig");
const color = @import("color.zig");
const keymap = @import("keymap.zig");
const style = @import("style.zig");
const icons = @import("icons.zig");
const dock = @import("dock.zig");
const topbar = @import("topbar.zig");
const padbar = @import("padbar.zig");
const settings = @import("settings.zig");
const browser_mod = @import("browser.zig");
const browser_draw = @import("browser_draw.zig");
const browsergeo = @import("browsergeo.zig");
const Dock = dock.Dock;
const TopBar = topbar.TopBar;
const PadBar = padbar.PadBar;
const Canvas = @import("canvas.zig").Canvas;
const Ctx = @import("draw.zig").Ctx;
const Editor = @import("editor.zig").Editor;
const ArrowStyle = @import("annotation.zig").ArrowStyle;
const TextStyle = @import("annotation.zig").TextStyle;

const Vec2 = geom.Vec2;
const Bounds = geom.Bounds;
const Rect = geom.Rect;
const Color = color.Color;
const nord = color.nord;

pub const State = struct {
    tool: keymap.Tool,
    color_idx: u8,
    size_idx: u8,
    arrow_style: ArrowStyle = .straight,
    text_style: TextStyle = .plain,
    help_visible: bool,
    /// The dock and the top bar (`h` hides both).
    dock_visible: bool = true,
    toast: ?[]const u8,
    can_undo: bool = false,
    can_redo: bool = false,
    /// Canvas padding (image px), for the padding widget.
    padding: u16 = 0,
    hover: Hover = .{},
    /// The file browser panel, when it shows (open and the panels not hidden).
    browser: ?*const browser_mod.Browser = null,
    /// The ghost of an image dragged out of the browser list.
    ghost: ?Ghost = null,

    pub fn of(ed: *const Editor) State {
        return .{
            .tool = ed.tool,
            .color_idx = ed.color_idx,
            .size_idx = ed.size_idx,
            .arrow_style = ed.arrow_style,
            .text_style = ed.text_style,
            .help_visible = ed.help_visible,
            .dock_visible = ed.dock_visible,
            .toast = ed.toast(),
            .can_undo = ed.canUndo(),
            .can_redo = ed.canRedo(),
            .padding = ed.settings.padding,
            .hover = ed.chromeHover(),
            .browser = if (ed.dock_visible and ed.browser.open) &ed.browser else null,
            .ghost = ed.browserGhost(),
        };
    }

    /// A value that changes when what panel `p` shows changes (its place
    /// aside: the compositor compares rects too). A frame repaints only
    /// the panels whose value or rect changed: a toast that changes each
    /// frame (crop size) does not repaint the dock.
    pub fn panelSig(s: State, p: Panel) u64 {
        var h = std.hash.Wyhash.init(@intFromEnum(p));
        switch (p) {
            .dock => {
                h.update(&.{ @intFromEnum(s.tool), s.color_idx, s.size_idx, @intFromBool(s.help_visible) });
                h.update(std.mem.asBytes(&(s.hover.dockKey() | @as(u32, @intFromBool(s.hover.down)) << 16)));
            },
            .style_switch => {
                h.update(&.{ @intFromEnum(s.tool), @intFromEnum(s.arrow_style), @intFromEnum(s.text_style) });
                h.update(std.mem.asBytes(&(s.hover.dockKey() | @as(u32, @intFromBool(s.hover.down)) << 16)));
            },
            .top_bar => {
                h.update(&.{ @intFromBool(s.can_undo), @intFromBool(s.can_redo) });
                h.update(std.mem.asBytes(&(s.hover.barKey() | @as(u32, @intFromBool(s.hover.down)) << 16)));
            },
            .pad_bar => {
                h.update(std.mem.asBytes(&s.padding));
                h.update(&.{ @intFromBool(s.hover.pad), @intFromBool(s.hover.down) });
            },
            .folder_btn => h.update(&.{ @intFromBool(s.dock_visible), @intFromBool(s.browser != null), @intFromBool(s.hover.folder), @intFromBool(s.hover.down) }),
            .browser => h.update(std.mem.asBytes(&@as(u64, if (s.browser) |b| b.sig() else 0))),
            .ghost => if (s.ghost) |g| h.update(std.mem.asBytes(&g.row)),
            .help => {}, // a fixed text, laid out from the screen size (its rect)
            .toast => h.update(s.toast orelse ""),
        }
        return h.final();
    }
};

/// The floating panels of the chrome, each damaged on its own.
pub const Panel = enum { dock, style_switch, top_bar, pad_bar, folder_btn, browser, ghost, help, toast };

/// An image dragged out of the browser list: its row and the pointer.
pub const Ghost = struct { row: usize, at: Vec2 };

/// The chrome item under the pointer.
pub const Hover = struct {
    dock: ?dock.Hit = null,
    bar: ?topbar.Button = null,
    /// The pointer is on the padding widget.
    pad: bool = false,
    /// The pointer is on the folder button (top left).
    folder: bool = false,
    /// The left button is down on the hovered item (pressed look).
    down: bool = false,

    /// A small value that changes when the hovered item changes.
    pub fn key(h: Hover) u32 {
        return h.dockKey() | h.barKey() << 16 | @as(u32, @intFromBool(h.pad)) << 24 | @as(u32, @intFromBool(h.folder)) << 25 | @as(u32, @intFromBool(h.down)) << 26;
    }

    fn dockKey(h: Hover) u32 {
        return if (h.dock) |x| switch (x) {
            .tool => |t| 1 + @as(u32, @intFromEnum(t)),
            .color => |i| 64 + @as(u32, i),
            .size => 128,
            .help => 129,
            .arrow_style => |st| 130 + @as(u32, @intFromEnum(st)),
            .text_style => |st| 132 + @as(u32, @intFromEnum(st)),
        } else 0;
    }

    fn barKey(h: Hover) u32 {
        return if (h.bar) |x| 1 + @as(u32, @intFromEnum(x)) else 0;
    }
};

/// Panels: the screen background color (compositor.background) a little
/// transparent, with an opaque 3 px border, brighter than the grid lines.
const panel_bg = Color.rgb(0x15181E).withAlpha(232);
const panel_border = Color.rgb(0x2C323E);
/// Buttons: a faint wash on hover with a hairline, a stronger one while pressed.
const hover_bg = nord.n6.withAlpha(24);
const hover_line = nord.n4.withAlpha(56);
const press_bg = nord.n6.withAlpha(50);
const press_line = nord.n4.withAlpha(96);
const accent_press = nord.n7;
const accent = nord.n8;

const Op = union(enum) {
    rrect: struct { b: Bounds, radius: f32, color: Color },
    /// Outline of a rounded rect.
    ring: struct { b: Bounds, radius: f32, w: f32, color: Color },
    disc: struct { c: Vec2, r: f32, color: Color },
    disc_ring: struct { c: Vec2, r: f32, w: f32, color: Color },
    /// Text with its top-left at `pos`.
    text: struct { pos: Vec2, s: []const u8, px: u16, color: Color },
    /// Text centered on `c` by its ink (badges, single glyphs).
    glyph: struct { c: Vec2, s: []const u8, px: u16, color: Color },
    icon: struct { tool: keymap.Tool, c: Vec2, size: f32, color: Color },
    arrow_style: struct { style: ArrowStyle, c: Vec2, size: f32, color: Color },
    text_style: struct { style: TextStyle, c: Vec2, size: f32, color: Color },
    undo: struct { redo: bool, c: Vec2, size: f32, color: Color },
    canvas_bg: struct { c: Vec2, size: f32, color: Color },
    folder: struct { c: Vec2, size: f32, color: Color },
    /// The browser panel contents (browser_draw.zig).
    browser: *const browser_mod.Browser,
    ghost: struct { b: *const browser_mod.Browser, g: Ghost },
};

const max_ops = 256;

/// Dock, pointer style switch, top bar, padding widget, folder button, browser, ghost, help overlay, toast.
pub const max_panels = 8;

pub const Layout = struct {
    ops: [max_ops]Op = undefined,
    n: usize = 0,
    panels: [max_panels]Rect = undefined,
    kinds: [max_panels]Panel = undefined,
    n_panels: usize = 0,

    /// The background of a button: the accent when `active`, else a wash on
    /// hover (stronger while pressed) with a hairline around it.
    fn button(l: *Layout, st: State, b: Bounds, radius: f32, s: f32, active: bool, hovered: bool) void {
        const down = hovered and st.hover.down;
        if (active) {
            l.push(.{ .rrect = .{ .b = b, .radius = radius, .color = if (down) accent_press else accent } });
        } else if (hovered) {
            l.push(.{ .rrect = .{ .b = b, .radius = radius, .color = if (down) press_bg else hover_bg } });
            _ = s;
            l.push(.{ .ring = .{ .b = b.expand(-0.5), .radius = @max(0, radius - 0.5), .w = 1, .color = if (down) press_line else hover_line } });
        }
    }

    fn push(l: *Layout, op: Op) void {
        if (l.n < max_ops) {
            l.ops[l.n] = op;
            l.n += 1;
        }
    }

    /// A damage region with no fill of its own (the ghost of a drag).
    fn region(l: *Layout, kind: Panel, b: Bounds) void {
        l.panels[l.n_panels] = b.toRect();
        l.kinds[l.n_panels] = kind;
        l.n_panels += 1;
    }

    /// A floating panel: flat nord1 fill and a 1 px nord2 border.
    fn panel(l: *Layout, kind: Panel, b_in: Bounds, radius: f32) void {
        // Whole pixels, so the border is crisp.
        const b = Bounds{ .min = .{ .x = @round(b_in.min.x), .y = @round(b_in.min.y) }, .max = .{ .x = @round(b_in.max.x), .y = @round(b_in.max.y) } };
        l.push(.{ .rrect = .{ .b = b, .radius = radius, .color = panel_bg } });
        // Centered half a pixel inside the edge: one crisp pixel wide.
        l.push(.{ .ring = .{ .b = b.expand(-1.5), .radius = 0, .w = 3, .color = panel_border } });
        l.panels[l.n_panels] = b.expand(2).toRect();
        l.kinds[l.n_panels] = kind;
        l.n_panels += 1;
    }
};

fn px(v: f32) u16 {
    return text.pxOf(v);
}

fn center(b: Bounds) Vec2 {
    return b.min.add(b.max).scale(0.5);
}

fn textW(ctx: Ctx, s: []const u8, size: u16) f32 {
    return text.measure(ctx.uiFont(), s, size).width;
}

// ---- dock --------------------------------------------------------------

fn layoutDock(l: *Layout, st: State, d: *const Dock) void {
    const s = d.s;
    l.panel(.dock, d.panel, 0);

    for (d.tools, keymap.tools) |b, info| {
        const active = info.tool == st.tool;
        const c = center(b);
        const hovered = if (st.hover.dock) |hd| hd == .tool and hd.tool == info.tool else false;
        l.button(st, b, 0, s, active, hovered);
        l.push(.{ .icon = .{ .tool = info.tool, .c = c, .size = 20 * s, .color = if (active) nord.n0 else nord.n4 } });
        // The hotkey: a faint letter in the corner, no badge.
        const kc = b.max.sub(.{ .x = 7 * s, .y = 7 * s });
        l.push(.{ .glyph = .{ .c = kc, .s = keymap.toolKey(info.tool), .px = px(10 * s), .color = (if (active) nord.n0 else nord.n4).withAlpha(if (active) 170 else 120) } });
    }

    for (d.swatches, color.palette, 0..) |c, p, i| {
        const hovered = if (st.hover.dock) |hd| hd == .color and hd.color == i else false;
        if (i == st.color_idx or hovered) {
            l.push(.{ .disc_ring = .{ .c = c, .r = d.swatch_r + 3 * s, .w = 1.8 * s, .color = if (i == st.color_idx) nord.n6 else nord.n3 } });
        } else {
            l.push(.{ .disc_ring = .{ .c = c, .r = d.swatch_r + 0.5 * s, .w = s, .color = nord.n3 } });
        }
        l.push(.{ .disc = .{ .c = c, .r = d.swatch_r, .color = p.color } });
    }

    // Size: a dot as big as the current level, inside a ring as big as the biggest.
    const sc = center(d.size);
    const max_r = 11 * s;
    const lvl: f32 = @floatFromInt(st.size_idx);
    const n_lvl: f32 = @floatFromInt(style.sizes.len - 1);
    l.push(.{ .disc_ring = .{ .c = sc, .r = max_r, .w = s, .color = nord.n3 } });
    l.push(.{ .disc = .{ .c = sc, .r = (2.5 + lvl / n_lvl * 7.5) * s, .color = color.palette[st.color_idx].color } });

    const hc = center(d.help);
    const hr = (d.help.max.y - d.help.min.y) / 2;
    const help_hover = if (st.hover.dock) |hd| hd == .help else false;
    l.push(.{ .disc = .{ .c = hc, .r = hr * 0.72, .color = if (st.help_visible) accent else if (help_hover) nord.n3 else nord.n2 } });
    l.push(.{ .glyph = .{ .c = hc, .s = "?", .px = px(14 * s), .color = if (st.help_visible) nord.n0 else nord.n5 } });

    // Arrow style switch: the active style filled like the active tool.
    if (d.switch_panel) |sp| {
        l.panel(.style_switch, sp, 0);
        for (d.styles, 0..) |b, i| {
            const text_tool = st.tool == .text;
            const active = if (text_tool) dock.text_styles[i] == st.text_style else dock.arrow_styles[i] == st.arrow_style;
            const hovered = if (st.hover.dock) |hd| switch (hd) {
                .arrow_style => |h| !text_tool and h == dock.arrow_styles[i],
                .text_style => |h| text_tool and h == dock.text_styles[i],
                else => false,
            } else false;
            l.button(st, b, 0, s, active, hovered);
            const col = if (active) nord.n0 else nord.n4;
            if (text_tool) {
                l.push(.{ .text_style = .{ .style = dock.text_styles[i], .c = center(b), .size = 18 * s, .color = col } });
            } else {
                l.push(.{ .arrow_style = .{ .style = dock.arrow_styles[i], .c = center(b), .size = 18 * s, .color = col } });
            }
        }
    }
}

// ---- top bar -----------------------------------------------------------

fn layoutTopBar(l: *Layout, st: State, b: *const TopBar) void {
    const s = b.s;
    l.panel(.top_bar, b.panel, 0);
    for (b.slots, topbar.buttons) |r, btn| {
        const enabled = switch (btn) {
            .undo => st.can_undo,
            .redo => st.can_redo,
            .canvas_bg => true,
        };
        const hovered = st.hover.bar == btn;
        const hb = Bounds{ .min = r.min.add(.{ .x = s, .y = s }), .max = r.max.sub(.{ .x = s, .y = s }) };
        l.button(st, hb, 0, s, false, enabled and hovered);
        const ink = if (!enabled) nord.n3 else if (hovered) nord.n6 else nord.n4;
        switch (btn) {
            .undo, .redo => l.push(.{ .undo = .{ .redo = btn == .redo, .c = center(r), .size = 22 * s, .color = ink } }),
            .canvas_bg => l.push(.{ .canvas_bg = .{ .c = center(r), .size = 20 * s, .color = ink } }),
        }
    }
}

/// The padding slider: a flat track filled up to the
/// knob, one notch per step, the knob on the current step.
fn layoutPadBar(l: *Layout, st: State, b: *const PadBar) void {
    const s = b.s;
    const hovered = st.hover.pad;
    l.panel(.pad_bar, b.panel, 0);
    const r = b.slot;
    const hb = Bounds{ .min = r.min.add(.{ .x = s, .y = s }), .max = r.max.sub(.{ .x = s, .y = s }) };
    l.button(st, hb, 0, s, false, hovered);
    const i = settings.paddingIndex(st.padding);
    const ty = b.trackY();
    const x0 = b.notchX(0);
    const x1 = b.notchX(settings.padding_steps.len - 1);
    const kx = b.notchX(i);
    const th = 1.5 * s;
    l.push(.{ .rrect = .{ .b = .{ .min = .{ .x = x0, .y = ty - th }, .max = .{ .x = x1, .y = ty + th } }, .radius = th, .color = nord.n3 } });
    if (i > 0) l.push(.{ .rrect = .{ .b = .{ .min = .{ .x = x0, .y = ty - th }, .max = .{ .x = kx, .y = ty + th } }, .radius = th, .color = accent } });
    for (0..settings.padding_steps.len) |k| {
        if (k == i) continue;
        l.push(.{ .disc = .{ .c = .{ .x = b.notchX(k), .y = ty }, .r = 2.5 * s, .color = if (k < i) accent else nord.n3 } });
    }
    l.push(.{ .disc = .{ .c = .{ .x = kx, .y = ty }, .r = 6.5 * s, .color = if (hovered) nord.n6 else nord.n5 } });
}

// ---- file browser --------------------------------------------------------

/// The folder button (top left, a small panel) and, when open, the browser
/// panel with the ghost of a dragged image.
fn layoutBrowser(l: *Layout, st: State, g: *const browsergeo.Geo) void {
    const s = g.s;
    l.panel(.folder_btn, g.folder, 0);
    const open = st.browser != null;
    const r = Bounds{ .min = g.folder.min.add(.{ .x = 2 * s, .y = 2 * s }), .max = g.folder.max.sub(.{ .x = 2 * s, .y = 2 * s }) };
    l.button(st, r, 0, s, open, st.hover.folder);
    const ink = if (open) nord.n0 else if (st.hover.folder) nord.n6 else nord.n4;
    l.push(.{ .folder = .{ .c = center(r), .size = 22 * s, .color = ink } });
    if (st.browser) |b| {
        l.panel(.browser, g.panel, 0);
        l.push(.{ .browser = b });
        if (st.ghost) |gh| {
            l.region(.ghost, browser_draw.ghostRect(g.*, b, gh.row, gh.at).toBounds().expand(3));
            l.push(.{ .ghost = .{ .b = b, .g = gh } });
        }
    }
}

// ---- help overlay ------------------------------------------------------

/// One row of the overlay: key caps (or a plain input text) and a label.
const Row = struct {
    caps: [4][]const u8 = undefined,
    n_caps: u8 = 0,
    /// Plain text instead of caps (mouse inputs).
    input: ?[]const u8 = null,
    label: []const u8,
    tool: ?keymap.Tool = null,
};

const Column = struct { title: []const u8, rows: []const Row };

const color_caps = std.fmt.comptimePrint("1-{d}", .{color.palette.len});

fn toolRows(out: []Row) []Row {
    for (keymap.tools, 0..) |t, i| out[i] = .{ .caps = .{ keymap.toolKey(t.tool), "", "", "" }, .n_caps = 1, .label = t.name, .tool = t.tool };
    return out[0..keymap.tools.len];
}

/// A second press of a tool key (`t t`), then key bindings: tools left
/// out, colors as one row, neighbours with the same action kind and label
/// merged (redo, zoom in, the four pan arrows).
fn keyRows(out: []Row) []Row {
    var n: usize = 0;
    // The active tool's key again (e.g. `t t`: text style).
    for (keymap.tools) |t| if (t.again) |ag| {
        const k = keymap.toolKey(t.tool);
        out[n] = .{ .caps = .{ k, k, "", "" }, .n_caps = 2, .label = ag.label };
        n += 1;
    };
    var prev: ?keymap.Action = null;
    for (keymap.bindings, keymap.caps) |b, cap| {
        switch (b.action) {
            .tool => continue,
            .color => |i| {
                if (i == 0) {
                    out[n] = .{ .caps = .{ color_caps, "", "", "" }, .n_caps = 1, .label = "color" };
                    n += 1;
                }
                continue;
            },
            else => {},
        }
        if (prev != null and std.meta.activeTag(prev.?) == std.meta.activeTag(b.action) and std.mem.eql(u8, out[n - 1].label, b.label) and out[n - 1].n_caps < 4) {
            out[n - 1].caps[out[n - 1].n_caps] = cap;
            out[n - 1].n_caps += 1;
        } else {
            out[n] = .{ .caps = .{ cap, "", "", "" }, .n_caps = 1, .label = b.label };
            n += 1;
        }
        prev = b.action;
    }
    return out[0..n];
}

fn mouseRows(out: []Row) []Row {
    for (keymap.extra, 0..) |e, i| out[i] = .{ .input = e.input, .label = e.short };
    return out[0..keymap.extra.len];
}

const OverlayMetrics = struct {
    s: f32,
    px: u16,
    head_px: u16,
    row_h: f32,
    cap_pad: f32,
    cap_gap: f32,
    icon: f32,
    col_gap: f32,
    pad: f32,

    fn of(s: f32) OverlayMetrics {
        return .{ .s = s, .px = px(14 * s), .head_px = px(12 * s), .row_h = 27 * s, .cap_pad = 7 * s, .cap_gap = 5 * s, .icon = 16 * s, .col_gap = 34 * s, .pad = 24 * s };
    }

    fn capW(m: OverlayMetrics, ctx: Ctx, cap: []const u8) f32 {
        return @max(textW(ctx, cap, m.px) + 2 * m.cap_pad, 20 * m.s);
    }

    /// Width of the key part of a row (icon, caps or input text).
    fn keyW(m: OverlayMetrics, ctx: Ctx, r: Row) f32 {
        if (r.input) |t| return textW(ctx, t, m.px);
        var w: f32 = if (r.tool != null) m.icon + 8 * m.s else 0;
        for (r.caps[0..r.n_caps]) |c| w += m.capW(ctx, c) + m.cap_gap;
        return w - m.cap_gap;
    }

    fn columnW(m: OverlayMetrics, ctx: Ctx, col: Column) [2]f32 {
        var kw: f32 = 0;
        var lw: f32 = 0;
        for (col.rows) |r| {
            kw = @max(kw, m.keyW(ctx, r));
            lw = @max(lw, textW(ctx, r.label, m.px));
        }
        return .{ kw, @max(lw, textW(ctx, col.title, m.head_px) - kw - 10 * m.s) };
    }
};

fn layoutOverlay(ctx: Ctx, l: *Layout, d: *const Dock, w: u32, h: u32) void {
    var buf: [3][32]Row = undefined;
    const cols = [_]Column{
        .{ .title = "TOOLS", .rows = toolRows(&buf[0]) },
        .{ .title = "KEYS", .rows = keyRows(&buf[1]) },
        .{ .title = "MOUSE", .rows = mouseRows(&buf[2]) },
    };
    const W: f32 = @floatFromInt(w);
    const avail_h = d.panel.min.y - 24 * d.s;

    // Measure at the UI scale, then shrink to fit the screen above the dock.
    var m = OverlayMetrics.of(style.uiScale(h));
    var size = Vec2.zero;
    for (0..2) |_| {
        var total_w: f32 = 0;
        var max_rows: usize = 0;
        for (cols) |col| {
            const cw = m.columnW(ctx, col);
            total_w += cw[0] + 10 * m.s + cw[1];
            max_rows = @max(max_rows, col.rows.len);
        }
        total_w += m.col_gap * @as(f32, cols.len - 1);
        size = .{ .x = total_w + 2 * m.pad, .y = 2 * m.pad + 30 * m.s + @as(f32, @floatFromInt(max_rows)) * m.row_h };
        const f = @min(1, @min((W - 24 * m.s) / size.x, avail_h / size.y));
        if (f >= 0.999) break;
        m = OverlayMetrics.of(m.s * f);
    }
    const x0 = @round((W - size.x) / 2);
    const y0 = @round(@max(0, (avail_h - size.y) / 2));
    l.panel(.help, .{ .min = .{ .x = x0, .y = y0 }, .max = .{ .x = x0 + size.x, .y = y0 + size.y } }, 4 * m.s);

    var x = x0 + m.pad;
    const head_y = y0 + m.pad;
    const pxf: f32 = @floatFromInt(m.px);
    for (cols) |col| {
        const cw = m.columnW(ctx, col);
        l.push(.{ .text = .{ .pos = .{ .x = x, .y = head_y }, .s = col.title, .px = m.head_px, .color = accent } });
        var y = head_y + 30 * m.s;
        for (col.rows) |r| {
            const cy = @round(y + m.row_h / 2);
            const ty = @round(cy - pxf * 0.6);
            var kx = x;
            if (r.input) |t| {
                l.push(.{ .text = .{ .pos = .{ .x = kx, .y = ty }, .s = t, .px = m.px, .color = nord.n6 } });
            } else {
                if (r.tool) |t| {
                    l.push(.{ .icon = .{ .tool = t, .c = .{ .x = kx + m.icon / 2, .y = cy }, .size = m.icon, .color = nord.n8 } });
                    kx += m.icon + 8 * m.s;
                }
                for (r.caps[0..r.n_caps]) |c| {
                    const capw = m.capW(ctx, c);
                    const half = 11 * m.s;
                    l.push(.{ .rrect = .{ .b = .{ .min = .{ .x = kx, .y = cy - half }, .max = .{ .x = kx + capw, .y = cy + half } }, .radius = 0, .color = nord.n3 } });
                    l.push(.{ .text = .{ .pos = .{ .x = @round(kx + (capw - textW(ctx, c, m.px)) / 2), .y = ty }, .s = c, .px = m.px, .color = nord.n6 } });
                    kx += capw + m.cap_gap;
                }
            }
            l.push(.{ .text = .{ .pos = .{ .x = x + cw[0] + 10 * m.s, .y = ty }, .s = r.label, .px = m.px, .color = nord.n4 } });
            y += m.row_h;
        }
        x += cw[0] + 10 * m.s + cw[1] + m.col_gap;
    }
}

// ---- toast -------------------------------------------------------------

/// `top`: y of the pill top edge at scale 1 is 12, or below the top bar.
fn layoutToast(ctx: Ctx, l: *Layout, msg: []const u8, w: u32, s_in: f32, top: ?f32) void {
    const W: f32 = @floatFromInt(w);
    var s = s_in;
    var size = px(13 * s);
    var tw = textW(ctx, msg, size);
    if (tw + 40 * s > W) { // shrink long messages on narrow screens
        s *= (W - 4) / (tw + 40 * s);
        size = px(13 * s);
        tw = textW(ctx, msg, size);
    }
    const ph = 32 * s;
    const pw = tw + 32 * s;
    const x0 = @round((W - pw) / 2);
    const y0 = @round(top orelse 12 * s);
    const b = Bounds{ .min = .{ .x = x0, .y = y0 }, .max = .{ .x = x0 + pw, .y = y0 + ph } };
    l.panel(.toast, b, 0);
    l.push(.{ .text = .{ .pos = .{ .x = x0 + 16 * s, .y = @round(y0 + ph / 2 - @as(f32, @floatFromInt(size)) * 0.6) }, .s = msg, .px = size, .color = nord.n6 } });
}

pub fn layout(ctx: Ctx, st: State, w: u32, h: u32) Layout {
    var l = Layout{};
    const d = Dock.of(w, h, st.tool);
    const bar = TopBar.of(w, h);
    if (st.dock_visible) {
        layoutDock(&l, st, &d);
        layoutTopBar(&l, st, &bar);
        layoutPadBar(&l, st, &PadBar.of(w, h));
        layoutBrowser(&l, st, &browsergeo.Geo.of(w, h));
    }
    if (st.help_visible) layoutOverlay(ctx, &l, &d, w, h);
    const s = style.uiScale(h);
    if (st.toast) |msg| layoutToast(ctx, &l, msg, w, s, if (st.dock_visible) bar.panel.max.y + 8 * s else null);
    return l;
}

/// Screen rectangles the chrome covers.
pub fn rects(l: *const Layout) []const Rect {
    return l.panels[0..l.n_panels];
}

/// The kind of each rect of `rects`.
pub fn kinds(l: *const Layout) []const Panel {
    return l.kinds[0..l.n_panels];
}

fn rrectShape(b: Bounds, radius: f32) sdf.RoundRect {
    return .{ .min = b.min, .max = b.max, .radius = radius };
}

pub fn draw(ctx: Ctx, cv: *Canvas, clip: Rect, l: *const Layout) !void {
    var touches = false;
    for (rects(l)) |r| touches = touches or r.intersects(clip);
    if (!touches) return;
    for (l.ops[0..l.n]) |op| switch (op) {
        .rrect => |r| raster.fill(cv, clip, rrectShape(r.b, r.radius), .{ .solid = r.color }, .{}),
        .ring => |r| raster.fill(cv, clip, sdf.ring(rrectShape(r.b, r.radius), r.w), .{ .solid = r.color }, .{}),
        .disc => |d| raster.fill(cv, clip, sdf.Disc{ .c = d.c, .r = d.r }, .{ .solid = d.color }, .{}),
        .disc_ring => |d| raster.fill(cv, clip, sdf.ring(sdf.Disc{ .c = d.c, .r = d.r }, d.w), .{ .solid = d.color }, .{}),
        .icon => |i| icons.draw(cv, clip, i.tool, i.c, i.size, i.color),
        .arrow_style => |i| icons.drawArrowStyle(cv, clip, i.style, i.c, i.size, i.color),
        .text_style => |i| icons.drawTextStyle(cv, clip, i.style, i.c, i.size, i.color),
        .undo => |u| icons.drawUndo(cv, clip, u.redo, u.c, u.size, u.color),
        .canvas_bg => |i| icons.drawCanvasBg(cv, clip, i.c, i.size, i.color),
        .folder => |i| icons.drawFolder(cv, clip, i.c, i.size, i.color, false),
        .browser => |b| try browser_draw.draw(ctx, cv, clip, b),
        .ghost => |gh| browser_draw.drawGhost(cv, clip, gh.b, gh.g.row, gh.g.at),
        .text => |t| {
            var mask = try text.render(ctx.gpa, ctx.uiFont(), t.s, t.px, 0, 0, null);
            defer mask.deinit(ctx.gpa);
            cv.blendMask(mask.data, mask.w, mask.h, @intFromFloat(t.pos.x), @intFromFloat(t.pos.y), t.color, clip);
        },
        .glyph => |g| {
            var mask = try text.render(ctx.gpa, ctx.uiFont(), g.s, g.px, 1, 0, null);
            defer mask.deinit(ctx.gpa);
            const ink = mask.inkBounds();
            const ix = @as(f32, @floatFromInt(ink[0] + ink[2])) * 0.5;
            const iy = @as(f32, @floatFromInt(ink[1] + ink[3])) * 0.5;
            cv.blendMask(mask.data, mask.w, mask.h, @intFromFloat(@round(g.c.x - ix)), @intFromFloat(@round(g.c.y - iy)), g.color, clip);
        },
    };
}
