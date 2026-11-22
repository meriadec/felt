//! Key map: the single source of truth for shortcuts. The editor dispatches
//! with `lookup`, the hint bar draws `bindings`, and `writeMarkdown` prints
//! docs/keymap.md (`zig build docs`). Edit shortcuts here only.
const std = @import("std");
const input = @import("input.zig");
const palette = @import("color.zig").palette;

pub const Tool = enum { arrow, text, rect, number, callout, highlight, pixelate, crop };

pub const ToolInfo = struct { tool: Tool, key: u8, name: []const u8, mouse: []const u8 };

pub const tools = [_]ToolInfo{
    .{ .tool = .arrow, .key = 'a', .name = "arrow", .mouse = "Drag from the tail to the head." },
    .{ .tool = .text, .key = 't', .name = "text", .mouse = "Click, type. Enter or Esc finishes, Shift+Enter adds a line, Backspace erases." },
    .{ .tool = .rect, .key = 'r', .name = "rect", .mouse = "Drag from corner to corner." },
    .{ .tool = .number, .key = 'n', .name = "number", .mouse = "Click to drop the next number (1, 2, 3...). Undo takes the number back." },
    .{ .tool = .callout, .key = 'c', .name = "callout", .mouse = "Drag from the point of interest to where the box goes, release, type, Enter. A plain click makes a label without a pointer." },
    .{ .tool = .highlight, .key = 'h', .name = "highlight", .mouse = "Drag over text to mark it like a highlighter pen." },
    .{ .tool = .pixelate, .key = 'p', .name = "pixelate", .mouse = "Drag over a secret to pixelate it." },
    .{ .tool = .crop, .key = 'x', .name = "crop", .mouse = "Drag the part to keep. On release the image is cropped and the previous tool comes back. Undo restores." },
};

/// The tool `delta` places after `t` in `tools` order, wrapping around.
pub fn cycleTool(t: Tool, delta: i32) Tool {
    const n: i32 = tools.len;
    for (tools, 0..) |info, i| if (info.tool == t) {
        return tools[@intCast(@mod(@as(i32, @intCast(i)) + delta, n))].tool;
    };
    unreachable;
}

pub fn toolInfo(t: Tool) *const ToolInfo {
    for (&tools) |*info| if (info.tool == t) return info;
    unreachable;
}

/// The tool key as a string with static lifetime.
pub fn toolKey(t: Tool) []const u8 {
    return (&toolInfo(t).key)[0..1];
}

pub const Action = union(enum) {
    tool: Tool,
    next_tool,
    prev_tool,
    color: u8,
    size_up,
    size_down,
    undo,
    redo,
    save,
    copy,
    quit,
    toggle_help,
};

pub const Chord = struct {
    key: input.Key,
    ctrl: bool = false,
    /// null: shift state does not matter.
    shift: ?bool = null,
};

pub const Binding = struct {
    chord: Chord,
    action: Action,
    /// Text of the key cap in the hint bar; null hides the binding there.
    bar: ?[]const u8 = null,
    /// Short label (hint bar and docs).
    label: []const u8,
};

fn ch(c: u21) input.Key {
    return .{ .char = c };
}

pub const bindings: []const Binding = blk: {
    var list: []const Binding = &.{};
    for (tools) |t| list = list ++ [_]Binding{.{ .chord = .{ .key = ch(t.key) }, .action = .{ .tool = t.tool }, .bar = &[_]u8{t.key}, .label = t.name }};
    for (palette, 0..) |p, i| list = list ++ [_]Binding{.{
        .chord = .{ .key = ch('1' + i) },
        .action = .{ .color = i },
        .bar = if (i == 0) std.fmt.comptimePrint("1-{d}", .{palette.len}) else null,
        .label = if (i == 0) "color" else p.name,
    }};
    list = list ++ [_]Binding{
        .{ .chord = .{ .key = .{ .named = .tab }, .shift = false }, .action = .next_tool, .bar = "Tab", .label = "next tool" },
        .{ .chord = .{ .key = .{ .named = .tab }, .shift = true }, .action = .prev_tool, .label = "previous tool" },
        .{ .chord = .{ .key = ch('[') }, .action = .size_down, .bar = "[ ]", .label = "size" },
        .{ .chord = .{ .key = ch(']') }, .action = .size_up, .label = "bigger" },
        .{ .chord = .{ .key = ch('z'), .ctrl = true, .shift = false }, .action = .undo, .bar = "Ctrl Z", .label = "undo" },
        .{ .chord = .{ .key = ch('z'), .ctrl = true, .shift = true }, .action = .redo, .bar = "Ctrl Y", .label = "redo" },
        .{ .chord = .{ .key = ch('y'), .ctrl = true }, .action = .redo, .label = "redo" },
        .{ .chord = .{ .key = ch('s'), .ctrl = true }, .action = .save, .bar = "Ctrl S", .label = "save" },
        .{ .chord = .{ .key = ch('c'), .ctrl = true }, .action = .copy, .bar = "Ctrl C", .label = "copy" },
        .{ .chord = .{ .key = .{ .named = .escape } }, .action = .quit, .bar = "Esc", .label = "quit" },
        .{ .chord = .{ .key = ch('?') }, .action = .toggle_help, .bar = "?", .label = "help" },
        .{ .chord = .{ .key = .{ .named = .f1 } }, .action = .toggle_help, .label = "help" },
    };
    break :blk list;
};

/// Mouse and context inputs that are not key bindings (docs only).
pub const extra = [_][2][]const u8{
    .{ "Mouse wheel", "Bigger / smaller stroke and text" },
    .{ "Right click", "Cancel the shape or text in progress" },
    .{ "Esc while drawing", "Cancel the shape in progress" },
    .{ "Esc with unsaved changes", "Shows a warning; a second Esc quits. Ctrl+C counts as saved: the clipboard keeps the image." },
    .{ "Ctrl+Z while typing", "Drop the text in progress" },
    .{ "Tab while typing", "Finish the text, then go to the next tool" },
};

fn lower(c: u21) u21 {
    return if (c < 128) std.ascii.toLower(@intCast(c)) else c;
}

pub fn matches(chord: Chord, ev: input.KeyEvent) bool {
    if (ev.mods.alt or ev.mods.ctrl != chord.ctrl) return false;
    if (chord.shift) |s| if (s != ev.mods.shift) return false;
    return switch (chord.key) {
        .named => |n| ev.key == .named and ev.key.named == n,
        .char => |c| ev.key == .char and (if (chord.ctrl) lower(ev.key.char) == lower(c) else ev.key.char == c),
    };
}

pub fn lookup(ev: input.KeyEvent) ?Action {
    for (bindings) |b| if (matches(b.chord, ev)) return b.action;
    return null;
}

pub fn chordName(buf: []u8, chord: Chord) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    if (chord.ctrl) w.writeAll("Ctrl+") catch {};
    if (chord.shift == true) w.writeAll("Shift+") catch {};
    switch (chord.key) {
        .char => |c| w.print("{u}", .{c}) catch {},
        .named => |n| w.writeAll(switch (n) {
            .escape => "Esc",
            .f1 => "F1",
            .tab => "Tab",
            else => @tagName(n),
        }) catch {},
    }
    return w.buffered();
}

/// Markdown reference, written to docs/keymap.md by `zig build docs`.
pub fn writeMarkdown(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\# Key map
        \\
        \\Generated from `src/core/keymap.zig` by `zig build docs`. Do not edit by hand.
        \\
        \\## Tools
        \\
        \\| Key | Tool | Mouse |
        \\|---|---|---|
        \\
    );
    for (tools) |t| try w.print("| `{c}` | {s} | {s} |\n", .{ t.key, t.name, t.mouse });
    try w.writeAll("\n## Keys\n\n| Key | Action |\n|---|---|\n");
    for (bindings) |b| {
        if (b.action == .tool) continue;
        var buf: [32]u8 = undefined;
        const label = switch (b.action) {
            .color => |i| palette[i].name,
            else => b.label,
        };
        try w.print("| `{s}` | {s}{s} |\n", .{ chordName(&buf, b.chord), if (b.action == .color) "color " else "", label });
    }
    try w.writeAll("\n## Mouse and context\n\n| Input | Effect |\n|---|---|\n");
    for (extra) |e| try w.print("| {s} | {s} |\n", .{ e[0], e[1] });
}

test "lookup" {
    try std.testing.expectEqual(Action{ .tool = .arrow }, lookup(.{ .key = .{ .char = 'a' } }).?);
    try std.testing.expectEqual(Action.undo, lookup(.{ .key = .{ .char = 'z' }, .mods = .{ .ctrl = true } }).?);
    try std.testing.expectEqual(Action.redo, lookup(.{ .key = .{ .char = 'Z' }, .mods = .{ .ctrl = true, .shift = true } }).?);
    try std.testing.expectEqual(Action.toggle_help, lookup(.{ .key = .{ .char = '?' }, .mods = .{ .shift = true } }).?);
    try std.testing.expectEqual(Action{ .color = 2 }, lookup(.{ .key = .{ .char = '3' } }).?);
    try std.testing.expectEqual(@as(?Action, null), lookup(.{ .key = .{ .char = 'a' }, .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(Action.next_tool, lookup(.{ .key = .{ .named = .tab } }).?);
    try std.testing.expectEqual(Action.prev_tool, lookup(.{ .key = .{ .named = .tab }, .mods = .{ .shift = true } }).?);
}

test "cycleTool wraps both ways in toolbar order" {
    try std.testing.expectEqual(tools[1].tool, cycleTool(tools[0].tool, 1));
    try std.testing.expectEqual(tools[tools.len - 1].tool, cycleTool(tools[0].tool, -1));
    try std.testing.expectEqual(tools[0].tool, cycleTool(tools[tools.len - 1].tool, 1));
}

test "markdown mentions every tool" {
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeMarkdown(&w);
    for (tools) |t| try std.testing.expect(std.mem.indexOf(u8, w.buffered(), t.name) != null);
}
