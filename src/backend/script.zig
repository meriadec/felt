//! Event scripts for the headless backend: one command per line, screen
//! coordinates. Format reference: docs/testing.md. Errors name the line.
const std = @import("std");
const core = @import("core");

const input = core.input;
const Event = input.Event;

/// A click on a chrome item, placed when the script runs (from the screen
/// size then), so scripts survive dock layout changes.
pub const UiTarget = union(enum) {
    tool: core.keymap.Tool,
    /// Palette index (the script names the color key, 1-based).
    color: u8,
    size,
    help,
    undo,
    redo,
    /// A slot of the arrow style switch (null: the style not in use, a toggle).
    arrow_style: ?core.annotation.ArrowStyle,
};

pub const Step = union(enum) {
    event: Event,
    ui: UiTarget,
};

/// A list of steps that takes events, for the parser.
const Steps = struct {
    list: *std.ArrayList(Step),
    gpa: std.mem.Allocator,

    fn append(self: Steps, _: std.mem.Allocator, ev: Event) !void {
        try self.list.append(self.gpa, .{ .event = ev });
    }
};

pub const Script = struct {
    events: std.ArrayList(Step) = .empty,
    size: ?[2]u32 = null,
    /// Image to replay on (path from the repo root); wins over the CLI image.
    image: ?[]const u8 = null,

    pub fn deinit(self: *Script, gpa: std.mem.Allocator) void {
        self.events.deinit(gpa);
        if (self.image) |p| gpa.free(p);
    }
};

pub const ParseError = struct {
    line: usize,
    msg: []const u8,
};

pub fn parse(gpa: std.mem.Allocator, src: []const u8, err: *ParseError) !Script {
    var s = Script{};
    errdefer s.deinit(gpa);
    var lines = std.mem.splitScalar(u8, src, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        err.line = n;
        parseLine(gpa, &s, std.mem.trimRight(u8, raw, "\r"), err) catch |e| {
            if (e == error.OutOfMemory) return e;
            return error.BadScript;
        };
    }
    return s;
}

fn fail(err: *ParseError, msg: []const u8) error{BadScript} {
    err.msg = msg;
    return error.BadScript;
}

fn num(err: *ParseError, it: *std.mem.TokenIterator(u8, .scalar)) !f32 {
    const t = it.next() orelse return fail(err, "missing number");
    return std.fmt.parseFloat(f32, t) catch fail(err, "bad number");
}

fn parseLine(gpa: std.mem.Allocator, s: *Script, line: []const u8, err: *ParseError) !void {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    if (trimmed.len == 0 or trimmed[0] == '#') return;
    var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
    const cmd = it.next().?;
    const ev = Steps{ .list = &s.events, .gpa = gpa };
    if (std.mem.eql(u8, cmd, "image")) {
        const path = it.next() orelse return fail(err, "image needs a path");
        if (s.image) |old| gpa.free(old);
        s.image = try gpa.dupe(u8, path);
    } else if (std.mem.eql(u8, cmd, "size")) {
        s.size = .{ @intFromFloat(try num(err, &it)), @intFromFloat(try num(err, &it)) };
    } else if (std.mem.eql(u8, cmd, "move")) {
        try ev.append(gpa, .{ .mouse_move = .{ .x = try num(err, &it), .y = try num(err, &it) } });
    } else if (std.mem.eql(u8, cmd, "down") or std.mem.eql(u8, cmd, "up") or std.mem.eql(u8, cmd, "click")) {
        const x = try num(err, &it);
        const y = try num(err, &it);
        const b: input.Button = if (it.next()) |bn| std.meta.stringToEnum(input.Button, bn) orelse return fail(err, "button must be left, middle or right") else .left;
        if (cmd[0] != 'u') try ev.append(gpa, .{ .mouse_down = .{ .x = x, .y = y, .button = b } });
        if (cmd[0] != 'd') try ev.append(gpa, .{ .mouse_up = .{ .x = x, .y = y, .button = b } });
    } else if (std.mem.eql(u8, cmd, "drag")) {
        const x0 = try num(err, &it);
        const y0 = try num(err, &it);
        const x1 = try num(err, &it);
        const y1 = try num(err, &it);
        const steps: usize = if (it.peek() != null) @intFromFloat(try num(err, &it)) else 8;
        try ev.append(gpa, .{ .mouse_down = .{ .x = x0, .y = y0 } });
        for (1..steps + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
            try ev.append(gpa, .{ .mouse_move = .{ .x = x0 + (x1 - x0) * t, .y = y0 + (y1 - y0) * t } });
        }
        try ev.append(gpa, .{ .mouse_up = .{ .x = x1, .y = y1 } });
    } else if (std.mem.eql(u8, cmd, "key")) {
        while (it.next()) |chord| {
            const k = input.parseChord(chord) catch return fail(err, "unknown key (examples: a, ctrl+z, ctrl+shift+z, enter, esc, backspace, f1, ?, space)");
            try ev.append(gpa, .{ .key = k });
        }
    } else if (std.mem.eql(u8, cmd, "type")) {
        // Everything after "type " is literal text; "\n" types Shift+Enter.
        const rest = std.mem.trimLeft(u8, trimmed["type".len..], " ");
        const text = if (rest.len > 0 and rest[0] == '"' and rest[rest.len - 1] == '"' and rest.len >= 2) rest[1 .. rest.len - 1] else rest;
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '\\' and i + 1 < text.len and text[i + 1] == 'n') {
                try ev.append(gpa, .{ .key = .{ .key = .{ .named = .enter }, .mods = .{ .shift = true } } });
                i += 2;
                continue;
            }
            const l = std.unicode.utf8ByteSequenceLength(text[i]) catch return fail(err, "bad UTF-8");
            if (i + l > text.len) return fail(err, "bad UTF-8");
            const cp = std.unicode.utf8Decode(text[i .. i + l]) catch return fail(err, "bad UTF-8");
            const upper = cp < 128 and std.ascii.isUpper(@intCast(cp));
            try ev.append(gpa, .{ .key = .{ .key = .{ .char = cp }, .mods = .{ .shift = upper } } });
            i += l;
        }
    } else if (std.mem.eql(u8, cmd, "wheel")) {
        // wheel up|down [N] [at X Y] [ctrl]
        const dir = it.next() orelse return fail(err, "wheel needs up or down");
        const step: i32 = if (std.mem.eql(u8, dir, "up")) 1 else if (std.mem.eql(u8, dir, "down")) -1 else return fail(err, "wheel needs up or down");
        var times: usize = 1;
        var x: f32 = 0;
        var y: f32 = 0;
        var mods = input.Mods{};
        while (it.next()) |t| {
            if (std.mem.eql(u8, t, "at")) {
                x = try num(err, &it);
                y = try num(err, &it);
            } else if (std.mem.eql(u8, t, "ctrl")) {
                mods.ctrl = true;
            } else {
                times = @intFromFloat(std.fmt.parseFloat(f32, t) catch return fail(err, "wheel: expected N, at X Y, or ctrl"));
            }
        }
        for (0..times) |_| try ev.append(gpa, .{ .wheel = .{ .delta = step, .x = x, .y = y, .mods = mods } });
    } else if (std.mem.eql(u8, cmd, "ui")) {
        const what = it.next() orelse return fail(err, ui_help);
        const t: UiTarget = if (std.mem.eql(u8, what, "tool")) blk: {
            const name = it.next() orelse return fail(err, ui_help);
            for (core.keymap.tools) |info| if (std.mem.eql(u8, info.name, name)) break :blk .{ .tool = info.tool };
            return fail(err, "ui tool: unknown tool name (see the key map)");
        } else if (std.mem.eql(u8, what, "color")) blk: {
            const k = try num(err, &it);
            if (k < 1 or k > core.color.palette.len) return fail(err, "ui color: 1 to the palette size");
            break :blk .{ .color = @intFromFloat(k - 1) };
        } else if (std.mem.eql(u8, what, "arrow-style")) blk: {
            const name = it.next() orelse break :blk .{ .arrow_style = null };
            break :blk .{ .arrow_style = std.meta.stringToEnum(core.annotation.ArrowStyle, name) orelse return fail(err, "ui arrow-style: straight or stairs (none: the other one)") };
        } else if (std.mem.eql(u8, what, "size")) .size else if (std.mem.eql(u8, what, "help")) .help else if (std.mem.eql(u8, what, "undo")) .undo else if (std.mem.eql(u8, what, "redo")) .redo else return fail(err, ui_help);
        try s.events.append(gpa, .{ .ui = t });
    } else if (std.mem.eql(u8, cmd, "resize")) {
        try ev.append(gpa, .{ .resize = .{ .w = @intFromFloat(try num(err, &it)), .h = @intFromFloat(try num(err, &it)) } });
    } else {
        return fail(err, "unknown command (image, size, move, down, up, click, drag, key, type, wheel, resize, ui)");
    }
}

const ui_help = "ui needs: tool NAME, color N, size, help, undo, redo or arrow-style [straight|stairs]";

test "parse script" {
    const gpa = std.testing.allocator;
    var err: ParseError = undefined;
    var s = try parse(gpa,
        \\# comment
        \\image tests/fixtures/strip.png
        \\size 800 500
        \\key a
        \\drag 10 10 100 100 4
        \\type Hi\n!
        \\wheel up 2
        \\wheel down at 10 20 ctrl
        \\ui tool crop
        \\ui color 3
        \\ui redo
        \\ui arrow-style
        \\ui arrow-style stairs
    , &err);
    defer s.deinit(gpa);
    try std.testing.expectEqual([2]u32{ 800, 500 }, s.size.?);
    try std.testing.expectEqualStrings("tests/fixtures/strip.png", s.image.?);
    try std.testing.expectEqual(@as(usize, 1 + 6 + 4 + 2 + 1 + 3 + 2), s.events.items.len);
    try std.testing.expectEqual(UiTarget{ .arrow_style = null }, s.events.items[s.events.items.len - 2].ui);
    try std.testing.expectEqual(UiTarget{ .arrow_style = .stairs }, s.events.items[s.events.items.len - 1].ui);
    s.events.shrinkRetainingCapacity(s.events.items.len - 2);
    const z = s.events.items[s.events.items.len - 4].event.wheel;
    try std.testing.expect(z.mods.ctrl and z.delta == -1 and z.x == 10 and z.y == 20);
    try std.testing.expectError(error.BadScript, parse(gpa, "key a\nfly 1 2", &err));
    try std.testing.expectEqual(@as(usize, 2), err.line);
    try std.testing.expectEqual(UiTarget{ .tool = .crop }, s.events.items[s.events.items.len - 3].ui);
    try std.testing.expectEqual(UiTarget{ .color = 2 }, s.events.items[s.events.items.len - 2].ui);
    try std.testing.expectError(error.BadScript, parse(gpa, "ui tool lasso", &err));
    try std.testing.expectError(error.BadScript, parse(gpa, "ui arrow-style curly", &err));
}
