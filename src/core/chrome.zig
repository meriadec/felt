//! UI chrome drawn over the image: the hint bar (built from keymap.bindings),
//! the compact status pill when help is hidden, and the toast at the top.
//! Layout is computed into a list of draw ops, so `rects` (for damage) and
//! `draw` share one code path.
const std = @import("std");
const geom = @import("geom.zig");
const sdf = @import("sdf.zig");
const raster = @import("raster.zig");
const text = @import("text.zig");
const color = @import("color.zig");
const keymap = @import("keymap.zig");
const style = @import("style.zig");
const Canvas = @import("canvas.zig").Canvas;
const Ctx = @import("draw.zig").Ctx;
const Editor = @import("editor.zig").Editor;

const Vec2 = geom.Vec2;
const Rect = geom.Rect;
const Color = color.Color;

pub const State = struct {
    tool: keymap.Tool,
    color_idx: u8,
    size_idx: u8,
    help_visible: bool,
    toast: ?[]const u8,

    pub fn of(ed: *const Editor) State {
        return .{ .tool = ed.tool, .color_idx = ed.color_idx, .size_idx = ed.size_idx, .help_visible = ed.help_visible, .toast = ed.toast() };
    }

    pub fn signature(s: State) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&[_]u8{ @intFromEnum(s.tool), s.color_idx, s.size_idx, @intFromBool(s.help_visible) }));
        h.update(s.toast orelse "\x00");
        return h.final();
    }
};

const panel_bg = Color{ .r = 16, .g = 16, .b = 20, .a = 215 };
const cap_bg = Color{ .r = 255, .g = 255, .b = 255, .a = 38 };
const label_fg = Color.rgb(0xc8c8c8);
const cap_fg = color.white;

const Op = union(enum) {
    rrect: struct { min: Vec2, max: Vec2, radius: f32, color: Color },
    disc: struct { c: Vec2, r: f32, color: Color },
    text: struct { pos: Vec2, s: []const u8, px: u16, color: Color },
};

const max_ops = 160;

pub const Layout = struct {
    ops: [max_ops]Op = undefined,
    n: usize = 0,
    panels: [3]Rect = undefined,
    n_panels: usize = 0,

    fn push(l: *Layout, op: Op) void {
        if (l.n < max_ops) {
            l.ops[l.n] = op;
            l.n += 1;
        }
    }
    fn panel(l: *Layout, min: Vec2, max: Vec2, radius: f32) void {
        l.push(.{ .rrect = .{ .min = min, .max = max, .radius = radius, .color = panel_bg } });
        l.panels[l.n_panels] = (geom.Bounds{ .min = min, .max = max }).expand(1).toRect();
        l.n_panels += 1;
    }
};

/// Chrome text size for a screen height.
pub fn chromePx(h: u32) u16 {
    return text.pxOf(std.math.clamp(@as(f32, @floatFromInt(h)) / 70, 12, 22));
}

const Item = struct {
    cap: []const u8,
    label: []const u8,
    kind: enum { key, colors, size } = .key,
    active: bool = false,
};

const Metrics = struct {
    px: u16,
    pxf: f32,
    cap_pad: f32,
    cap_h: f32,
    gap: f32,
    item_gap: f32,
    row_h: f32,
    pad: f32,
    margin: f32,
    swatch_r: f32,

    fn of(px: u16) Metrics {
        const p: f32 = @floatFromInt(px);
        return .{ .px = px, .pxf = p, .cap_pad = p * 0.45, .cap_h = p * 1.5, .gap = p * 0.4, .item_gap = p * 1.2, .row_h = p * 2.0, .pad = p * 0.6, .margin = p * 0.8, .swatch_r = p * 0.42 };
    }
};

fn textW(ctx: Ctx, s: []const u8, px: u16) f32 {
    return text.measure(ctx.font, s, px).width;
}

fn itemWidth(ctx: Ctx, m: Metrics, it: Item) f32 {
    const cap_w = textW(ctx, it.cap, m.px) + 2 * m.cap_pad;
    const body: f32 = switch (it.kind) {
        .key => textW(ctx, it.label, m.px),
        .colors => @as(f32, @floatFromInt(color.palette.len)) * (m.swatch_r * 2 + m.pxf * 0.25),
        .size => m.cap_h + m.gap + textW(ctx, it.label, m.px),
    };
    return cap_w + m.gap + body;
}

/// Draw one item with its left edge at x and vertical center cy.
fn placeItem(ctx: Ctx, l: *Layout, m: Metrics, st: State, it: Item, x: f32, cy: f32) void {
    const cap_w = textW(ctx, it.cap, m.px) + 2 * m.cap_pad;
    const active_c = color.palette[st.color_idx].color;
    const cap_fill = if (it.active) active_c else cap_bg;
    const cap_text = if (it.active) active_c.contrast() else cap_fg;
    l.push(.{ .rrect = .{ .min = .{ .x = x, .y = cy - m.cap_h / 2 }, .max = .{ .x = x + cap_w, .y = cy + m.cap_h / 2 }, .radius = m.pxf * 0.3, .color = cap_fill } });
    l.push(.{ .text = .{ .pos = .{ .x = x + m.cap_pad, .y = cy - m.pxf * 0.55 }, .s = it.cap, .px = m.px, .color = cap_text } });
    var bx = x + cap_w + m.gap;
    switch (it.kind) {
        .key => l.push(.{ .text = .{ .pos = .{ .x = bx, .y = cy - m.pxf * 0.55 }, .s = it.label, .px = m.px, .color = if (it.active) color.white else label_fg } }),
        .colors => for (color.palette, 0..) |p, i| {
            const c = Vec2.init(bx + m.swatch_r, cy);
            if (i == st.color_idx) l.push(.{ .disc = .{ .c = c, .r = m.swatch_r + 2.5, .color = color.white } });
            l.push(.{ .disc = .{ .c = c, .r = m.swatch_r, .color = p.color } });
            bx += m.swatch_r * 2 + m.pxf * 0.25;
        },
        .size => {
            const r = std.math.clamp(style.sizes[st.size_idx].stroke * 0.5, 1, m.cap_h * 0.5);
            l.push(.{ .disc = .{ .c = .{ .x = bx + m.cap_h / 2, .y = cy }, .r = r, .color = active_c } });
            l.push(.{ .text = .{ .pos = .{ .x = bx + m.cap_h + m.gap, .y = cy - m.pxf * 0.55 }, .s = it.label, .px = m.px, .color = label_fg } });
        },
    }
}

fn helpItems(st: State, out: []Item) []Item {
    var n: usize = 0;
    for (keymap.bindings) |b| {
        const cap = b.bar orelse continue;
        out[n] = .{ .cap = cap, .label = b.label };
        switch (b.action) {
            .tool => |t| out[n].active = t == st.tool,
            .color => out[n].kind = .colors,
            .size_down, .size_up => out[n].kind = .size,
            else => {},
        }
        n += 1;
    }
    return out[0..n];
}

fn statusItems(st: State, out: []Item) []Item {
    const info = keymap.toolInfo(st.tool);
    out[0] = .{ .cap = &[_]u8{info.key}, .label = info.name, .active = true };
    out[1] = .{ .cap = "[ ]", .label = "size", .kind = .size };
    out[2] = .{ .cap = "?", .label = "help" };
    return out[0..3];
}

pub fn layout(ctx: Ctx, st: State, w: u32, h: u32) Layout {
    var l = Layout{};
    const m = Metrics.of(chromePx(h));
    const W: f32 = @floatFromInt(w);
    const H: f32 = @floatFromInt(h);

    var buf: [32]Item = undefined;
    const items = if (st.help_visible) helpItems(st, &buf) else statusItems(st, &buf);

    // Flow items into rows no wider than the screen.
    const max_w = W - 2 * (m.margin + m.pad);
    var widths: [32]f32 = undefined;
    var row_of: [32]u8 = undefined;
    var row_w: [8]f32 = @splat(0);
    var rows: u8 = 1;
    for (items, 0..) |it, i| {
        widths[i] = itemWidth(ctx, m, it);
        const add = widths[i] + (if (row_w[rows - 1] > 0) m.item_gap else 0);
        if (row_w[rows - 1] > 0 and row_w[rows - 1] + add > max_w and rows < row_w.len) rows += 1;
        row_w[rows - 1] += widths[i] + (if (row_w[rows - 1] > 0) m.item_gap else 0);
        row_of[i] = rows - 1;
    }
    var panel_w: f32 = 0;
    for (row_w[0..rows]) |rw| panel_w = @max(panel_w, rw);
    panel_w += 2 * m.pad;
    const panel_h = @as(f32, @floatFromInt(rows)) * m.row_h + 2 * m.pad - (m.row_h - m.cap_h);
    const px0 = if (st.help_visible) @round((W - panel_w) / 2) else m.margin;
    const py0 = H - m.margin - panel_h;
    l.panel(.{ .x = px0, .y = py0 }, .{ .x = px0 + panel_w, .y = py0 + panel_h }, m.pxf * 0.5);

    var x: f32 = 0;
    var cur_row: u8 = 255;
    for (items, 0..) |it, i| {
        if (row_of[i] != cur_row) {
            cur_row = row_of[i];
            x = px0 + m.pad + (panel_w - 2 * m.pad - row_w[cur_row]) / 2;
        }
        const cy = py0 + m.pad + m.cap_h / 2 + @as(f32, @floatFromInt(cur_row)) * m.row_h;
        placeItem(ctx, &l, m, st, it, @round(x), @round(cy));
        x += widths[i] + m.item_gap;
    }

    if (st.toast) |msg| {
        const tw = textW(ctx, msg, m.px) + 2 * m.pad * 1.5;
        const th = m.cap_h + m.pad;
        const tx = @round((W - tw) / 2);
        const ty = m.margin;
        l.panel(.{ .x = tx, .y = ty }, .{ .x = tx + tw, .y = ty + th }, m.pxf * 0.5);
        l.push(.{ .text = .{ .pos = .{ .x = tx + m.pad * 1.5, .y = @round(ty + th / 2 - m.pxf * 0.55) }, .s = msg, .px = m.px, .color = color.white } });
    }
    return l;
}

/// Screen rectangles the chrome covers.
pub fn rects(l: *const Layout) []const Rect {
    return l.panels[0..l.n_panels];
}

pub fn draw(ctx: Ctx, cv: *Canvas, clip: Rect, l: *const Layout) !void {
    var touches = false;
    for (rects(l)) |r| touches = touches or r.intersects(clip);
    if (!touches) return;
    for (l.ops[0..l.n]) |op| switch (op) {
        .rrect => |r| raster.fill(cv, clip, sdf.RoundRect{ .min = r.min, .max = r.max, .radius = r.radius }, .{ .solid = r.color }, .{}),
        .disc => |d| raster.fill(cv, clip, sdf.Disc{ .c = d.c, .r = d.r }, .{ .solid = d.color }, .{}),
        .text => |t| {
            var mask = try text.render(ctx.gpa, ctx.font, t.s, t.px, 0, 0, false);
            defer mask.deinit(ctx.gpa);
            cv.blendMask(mask.data, mask.w, mask.h, @intFromFloat(t.pos.x), @intFromFloat(t.pos.y), t.color, clip);
        },
    };
}
