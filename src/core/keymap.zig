//! Key map: the single source of truth for shortcuts. The editor dispatches
//! with `lookup`, the dock follows `tools` order, the help overlay lists
//! `bindings` and `extra`, and `writeMarkdown` prints docs/keymap.md
//! (`zig build docs`). Edit shortcuts here only.
const std = @import("std");
const input = @import("input.zig");
const palette = @import("color.zig").palette;

pub const Tool = enum { arrow, text, rect, number, callout, pixelate, move, crop };

pub const ToolInfo = struct {
    tool: Tool,
    key: u8,
    name: []const u8,
    mouse: []const u8,
    /// What the tool key does when the tool is already active.
    again: ?Again = null,
};

/// A second press of the active tool's key.
pub const Again = struct { action: Action, label: []const u8 };

pub const tools = [_]ToolInfo{
    .{ .tool = .callout, .key = 'c', .name = "callout", .mouse = "The tool at startup. Drag from the point of interest to where the box goes, release, type, Enter. The pointer is an arrow from the box to the point: stairs (at startup) or straight, the arrow style (`c` again or the switch above the dock changes it, for arrows too). A plain click makes a label without a pointer.", .again = .{ .action = .arrow_style, .label = "pointer style: straight / stairs" } },
    .{ .tool = .arrow, .key = 'a', .name = "arrow", .mouse = "Drag from the head (the point) to the tail, like a callout. Style: stairs (an elbow with round corners, the start style) or straight; `a` again or the switch above the dock changes it for new arrows and callout pointers, for the rest of the session. A stairs path turns where it crosses and crowds no other path, if it can (the paths around it move aside too).", .again = .{ .action = .arrow_style, .label = "arrow style: straight / stairs" } },
    .{ .tool = .text, .key = 't', .name = "text", .mouse = "Click, type. Enter or Esc finishes, Shift+Enter adds a line, Backspace and Delete erase, the arrows (Ctrl: by word), Home and End move the caret, Shift with them selects, Ctrl+A selects all, and typing over a selection replaces it. Style: plain letters in the color (the start style) or on a filled box; `t` again or the switch above the dock changes it for new texts, for the rest of the session.", .again = .{ .action = .text_style, .label = "text style: plain / boxed" } },
    .{ .tool = .rect, .key = 'r', .name = "rect", .mouse = "Drag from corner to corner." },
    .{ .tool = .number, .key = 'n', .name = "number", .mouse = "Click to drop the next number (1, 2, 3...). Undo takes the number back." },
    .{ .tool = .pixelate, .key = 'p', .name = "pixelate", .mouse = "Drag over a secret to pixelate it." },
    .{ .tool = .move, .key = 'm', .name = "move/select", .mouse = "Point at an annotation: it lights up. Drag it to move it; it stays selected (outlined) after you let go, and Delete or Backspace deletes it (undo brings it back). A click on empty space, Esc, another tool, undo or redo clears the selection. A callout: drag the box (the tip stays), or the tip alone. An arrow: drag an end to move only that end. A stairs path: drag the dot on its middle to pin where it turns; back to the middle, it routes itself again. Undo puts it back. With two or more images on the canvas, drag an image (where no annotation is under the pointer) to move it to another place: the free slots next to the other images show dashed, the nearest one lit, and a ghost outline follows the pointer; the view zooms out if a slot would be off screen; let go to drop (one undo step, its annotations go with it), Esc or right click cancels; after either, the view eases back to the zoom you had, following the image. Double click a text or a callout: edit its text again (Enter or Esc keeps the change; a blank or unchanged text keeps the old one); undo restores the old text." },
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
    /// Switch the style of new arrows and callout pointers (straight, stairs).
    arrow_style,
    /// Switch the style of new texts (plain, boxed).
    text_style,
    /// Delete the selected annotation (move/select tool).
    delete_selected,
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
    toggle_dock,
    toggle_hand,
    zoom_in,
    zoom_out,
    zoom_fit,
    /// Move the image by a fraction of the screen: x, y in -1..1.
    pan: [2]i8,
    /// Switch the canvas background (outside the image): light / dark grey.
    canvas_bg,
    /// Canvas padding one step bigger / smaller (settings.padding_steps).
    padding_up,
    padding_down,
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
    /// Short label (help overlay and docs).
    label: []const u8,
};

fn ch(c: u21) input.Key {
    return .{ .char = c };
}

pub const bindings: []const Binding = blk: {
    var list: []const Binding = &.{};
    for (tools) |t| list = list ++ [_]Binding{.{ .chord = .{ .key = ch(t.key) }, .action = .{ .tool = t.tool }, .label = t.name }};
    for (palette, 0..) |p, i| list = list ++ [_]Binding{.{ .chord = .{ .key = ch('1' + i) }, .action = .{ .color = i }, .label = p.name }};
    list = list ++ [_]Binding{
        .{ .chord = .{ .key = .{ .named = .tab }, .shift = false }, .action = .next_tool, .label = "next tool" },
        .{ .chord = .{ .key = .{ .named = .tab }, .shift = true }, .action = .prev_tool, .label = "previous tool" },
        .{ .chord = .{ .key = ch('[') }, .action = .size_down, .label = "smaller" },
        .{ .chord = .{ .key = ch(']') }, .action = .size_up, .label = "bigger" },
        .{ .chord = .{ .key = ch('z'), .ctrl = true, .shift = false }, .action = .undo, .label = "undo" },
        .{ .chord = .{ .key = ch('z'), .ctrl = true, .shift = true }, .action = .redo, .label = "redo" },
        .{ .chord = .{ .key = ch('y'), .ctrl = true }, .action = .redo, .label = "redo" },
        .{ .chord = .{ .key = ch('s'), .ctrl = true }, .action = .save, .label = "save" },
        .{ .chord = .{ .key = ch('c'), .ctrl = true }, .action = .copy, .label = "copy" },
        .{ .chord = .{ .key = .{ .named = .delete } }, .action = .delete_selected, .label = "delete selection (move/select)" },
        .{ .chord = .{ .key = .{ .named = .backspace } }, .action = .delete_selected, .label = "delete selection (move/select)" },
        .{ .chord = .{ .key = .{ .named = .escape } }, .action = .quit, .label = "quit" },
        .{ .chord = .{ .key = ch('q') }, .action = .quit, .label = "quit" },
        .{ .chord = .{ .key = ch('?') }, .action = .toggle_help, .label = "help" },
        .{ .chord = .{ .key = .{ .named = .f1 } }, .action = .toggle_help, .label = "help" },
        .{ .chord = .{ .key = ch('h') }, .action = .toggle_dock, .label = "hide / show the panels" },
        .{ .chord = .{ .key = ch(' ') }, .action = .toggle_hand, .label = "hold: hand, drag the canvas with the left button" },
        .{ .chord = .{ .key = ch('b') }, .action = .canvas_bg, .label = "canvas: light / dark grey" },
        .{ .chord = .{ .key = ch('.') }, .action = .padding_up, .label = "canvas padding: more" },
        .{ .chord = .{ .key = ch(',') }, .action = .padding_down, .label = "canvas padding: less" },
        .{ .chord = .{ .key = ch('=') }, .action = .zoom_in, .label = "zoom in" },
        .{ .chord = .{ .key = ch('+') }, .action = .zoom_in, .label = "zoom in" },
        .{ .chord = .{ .key = ch('-') }, .action = .zoom_out, .label = "zoom out (room to draw around)" },
        .{ .chord = .{ .key = ch('0') }, .action = .zoom_fit, .label = "fit the canvas to the screen" },
        .{ .chord = .{ .key = .{ .named = .left } }, .action = .{ .pan = .{ 1, 0 } }, .label = "pan" },
        .{ .chord = .{ .key = .{ .named = .right } }, .action = .{ .pan = .{ -1, 0 } }, .label = "pan" },
        .{ .chord = .{ .key = .{ .named = .up } }, .action = .{ .pan = .{ 0, 1 } }, .label = "pan" },
        .{ .chord = .{ .key = .{ .named = .down } }, .action = .{ .pan = .{ 0, -1 } }, .label = "pan" },
    };
    break :blk list;
};

pub const Extra = struct {
    input: []const u8,
    /// Full text (docs).
    effect: []const u8,
    /// Short text (help overlay).
    short: []const u8,
};

/// Mouse and context inputs that are not key bindings.
pub const extra = [_]Extra{
    .{ .input = "Mouse wheel", .effect = "Bigger / smaller stroke and text", .short = "size" },
    .{ .input = "Ctrl+wheel", .effect = "Zoom in / out about the pointer", .short = "zoom" },
    .{ .input = "Middle drag", .effect = "Pan the view", .short = "pan" },
    .{ .input = "Drawing past the image", .effect = "The canvas grows to hold the shape, in light or dark grey (`b`, kept for the next sessions); the export holds it all. Zoom out (`-`) for room around a full-screen image", .short = "grow canvas" },
    .{ .input = "Right click", .effect = "Cancel the shape or text in progress", .short = "cancel" },
    .{ .input = "Click on the dock", .effect = "Pick a tool or a color; the size slot steps the size, `?` opens this help. With the arrow or callout tool, the switch above the dock picks the arrow style (arrows and callout pointers); with the text tool, the text style (plain or boxed)", .short = "pick" },
    .{ .input = "Click on the top bar", .effect = "Undo or redo (a dim button has nothing to do); the half-filled circle switches the canvas background (like `b`); the slider sets the canvas padding: empty margin of 0, 64, 96, 128 or 192 px in the canvas color, in the export too (click or drag to a notch, or wheel over it; like `,` `.`; kept for the next sessions)", .short = "undo, redo, canvas, pad" },
    .{ .input = "Esc or q while drawing", .effect = "Cancel the shape in progress", .short = "cancel" },
    .{ .input = "Esc with a selection", .effect = "Clear the selection", .short = "deselect" },
    .{ .input = "Esc or q with unsaved changes", .effect = "Shows a warning; a second Esc or q quits. Ctrl+C counts as saved: the clipboard keeps the image.", .short = "warn, again quits" },
    .{ .input = "Esc, q or a click with help open", .effect = "Close the help", .short = "close help" },
    .{ .input = "Esc or q while typing", .effect = "Esc finishes the text; q is a letter", .short = "Esc: done, q: letter" },
    .{ .input = "Ctrl+Z while typing", .effect = "Drop the text in progress", .short = "drop text" },
    .{ .input = "Tab while typing", .effect = "Finish the text, then go to the next tool", .short = "finish, next tool" },
};

fn upper(c: u21) u21 {
    return if (c < 128) std.ascii.toUpper(@intCast(c)) else c;
}

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

fn namedName(n: input.Named) []const u8 {
    return switch (n) {
        .escape => "Esc",
        .f1 => "F1",
        .tab => "Tab",
        .enter => "Enter",
        .backspace => "Backspace",
        .delete => "Delete",
        .left => "←",
        .right => "→",
        .up => "↑",
        .down => "↓",
        else => @tagName(n),
    };
}

/// Key cap text of a chord, e.g. "Ctrl+Shift+Z" (bindings are ASCII).
fn capText(comptime chord: Chord) []const u8 {
    comptime {
        var s: []const u8 = "";
        if (chord.ctrl) s = s ++ "Ctrl+";
        if (chord.shift == true) s = s ++ "Shift+";
        return s ++ switch (chord.key) {
            .char => |c| if (c == ' ') "Space" else &[_]u8{@intCast(if (chord.ctrl) upper(c) else c)},
            .named => |n| namedName(n),
        };
    }
}

/// Key cap text of each binding, same order as `bindings`. Static strings.
pub const caps: [bindings.len][]const u8 = blk: {
    var a: [bindings.len][]const u8 = undefined;
    for (bindings, 0..) |b, i| a[i] = capText(b.chord);
    break :blk a;
};

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
    for (tools) |t| if (t.again) |ag| try w.print("| `{c}` again ({s} tool active) | {s} |\n", .{ t.key, t.name, ag.label });
    for (bindings, caps) |b, cap| {
        if (b.action == .tool) continue;
        try w.print("| `{s}` | {s}{s} |\n", .{ cap, if (b.action == .color) "color " else "", b.label });
    }
    try w.writeAll("\n## Mouse and context\n\n| Input | Effect |\n|---|---|\n");
    for (extra) |e| try w.print("| {s} | {s} |\n", .{ e.input, e.effect });
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
    try std.testing.expectEqual(Action.zoom_in, lookup(.{ .key = .{ .char = '+' }, .mods = .{ .shift = true } }).?);
    try std.testing.expectEqual(Action.zoom_out, lookup(.{ .key = .{ .char = '-' } }).?);
    try std.testing.expectEqual(Action.quit, lookup(.{ .key = .{ .char = 'q' } }).?);
    try std.testing.expectEqual(Action.canvas_bg, lookup(.{ .key = .{ .char = 'b' } }).?);
}

test "cycleTool wraps both ways in toolbar order" {
    try std.testing.expectEqual(tools[1].tool, cycleTool(tools[0].tool, 1));
    try std.testing.expectEqual(tools[tools.len - 1].tool, cycleTool(tools[0].tool, -1));
    try std.testing.expectEqual(tools[0].tool, cycleTool(tools[tools.len - 1].tool, 1));
}

test "caps" {
    var found: usize = 0;
    for (bindings, caps) |b, cap| {
        if (b.action == .redo and b.chord.shift == true) {
            try std.testing.expectEqualStrings("Ctrl+Shift+Z", cap);
            found += 1;
        }
        if (b.action == .prev_tool) {
            try std.testing.expectEqualStrings("Shift+Tab", cap);
            found += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), found);
}

test "markdown mentions every tool" {
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeMarkdown(&w);
    for (tools) |t| try std.testing.expect(std.mem.indexOf(u8, w.buffered(), t.name) != null);
}
