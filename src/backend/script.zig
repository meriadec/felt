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
    /// A slot of the arrow style switch. With a name, it clicks only if the
    /// style is not that one yet (null: the style not in use, a toggle).
    arrow_style: ?core.annotation.ArrowStyle,
    text_style: ?core.annotation.TextStyle,
    /// The canvas background switch of the top bar. With a name, it clicks
    /// only if the canvas is not that one yet (null: always, a toggle).
    canvas_bg: ?core.settings.CanvasBg,
    /// The padding widget: click the notch of the step
    /// nearest to this many px, unless that step is already set.
    padding: u16,
    /// The folder button (top left): opens or closes the file browser.
    browser,
};

/// A file browser command (`browser ...` in a script). Rows are found by
/// name (`..` for the parent row) and clicked at their place, so the hit
/// test is part of the replay; a row that is scrolled out is scrolled in.
pub const BrowserCmd = union(enum) {
    /// The folder the browser starts in (a repo-relative path; owned). Before the first open.
    home: []const u8,
    /// Click the row named so (a folder or `..`).
    cd: []const u8,
    /// Click the up button of the header.
    up,
    /// Press on the row, move to (x, y) in steps, release. `hold`: stay down (a script that ends mid-drag).
    drag: struct { name: []const u8, x: f32, y: f32, hold: bool },
    /// Wheel steps over the panel (positive: down).
    scroll: i32,
};

pub const Step = union(enum) {
    event: Event,
    /// Click a chrome item.
    ui: UiTarget,
    /// Move the pointer onto a chrome item (hover, no click).
    hover: UiTarget,
    /// Place another image on the scene (`place`, `addimage`).
    add_image: AddImage,
    /// Show (`dropzone W H X Y`) or hide (`dropzone off`) the montage drop slots.
    dropzone: ?core.dropzone.Drop,
    browser: BrowserCmd,
    /// Set the modification time of a file or folder (repo-relative; owned) to `secs` since the epoch.
    touch: struct { path: []const u8, secs: i64 },
};

/// Where `add_image` puts the image: at a scene point, or on a magnet side
/// of the image placed last.
pub const AddImage = struct {
    path: []const u8,
    at: union(enum) { pos: [2]i32, side: core.magnet.Side },
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
    /// `capture`: replay on the capture picker, with the image as the
    /// frozen screen (the screen has the image's size).
    capture: bool = false,
    /// `window`: top-level windows for the picker, topmost first.
    windows: std.ArrayList(core.geom.Rect) = .empty,
    /// `delay`: the picker's initial delay, ms.
    delay_ms: u32 = 0,

    pub fn deinit(self: *Script, gpa: std.mem.Allocator) void {
        self.windows.deinit(gpa);
        if (self.image) |p| gpa.free(p);
        for (self.events.items) |st| switch (st) {
            .add_image => |a| gpa.free(a.path),
            .touch => |t| gpa.free(t.path),
            .browser => |b| switch (b) {
                .home, .cd => |n| gpa.free(n),
                .drag => |d| gpa.free(d.name),
                else => {},
            },
            else => {},
        };
        self.events.deinit(gpa);
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
    } else if (std.mem.eql(u8, cmd, "place") or std.mem.eql(u8, cmd, "addimage")) {
        const path = it.next() orelse return fail(err, "needs an image path");
        const at: @FieldType(AddImage, "at") = if (cmd[0] == 'p') .{ .pos = .{
            @intFromFloat(try num(err, &it)),
            @intFromFloat(try num(err, &it)),
        } } else .{ .side = std.meta.stringToEnum(core.magnet.Side, it.next() orelse "") orelse return fail(err, "side must be left, top, right or bottom") };
        const owned = try gpa.dupe(u8, path);
        errdefer gpa.free(owned);
        try s.events.append(gpa, .{ .add_image = .{ .path = owned, .at = at } });
    } else if (std.mem.eql(u8, cmd, "dropzone")) {
        const first = it.peek() orelse return fail(err, "dropzone needs `off` or W H X Y");
        if (std.mem.eql(u8, first, "off")) {
            try s.events.append(gpa, .{ .dropzone = null });
        } else {
            const w: i32 = @intFromFloat(try num(err, &it));
            const h: i32 = @intFromFloat(try num(err, &it));
            const x = try num(err, &it);
            const y = try num(err, &it);
            try s.events.append(gpa, .{ .dropzone = .{ .w = w, .h = h, .pointer = core.geom.Vec2.init(x, y) } });
        }
    } else if (std.mem.eql(u8, cmd, "touch")) {
        const path = it.next() orelse return fail(err, "touch needs a path and a time in seconds");
        const secs: i64 = @intFromFloat(try num(err, &it));
        const owned = try gpa.dupe(u8, path);
        errdefer gpa.free(owned);
        try s.events.append(gpa, .{ .touch = .{ .path = owned, .secs = secs } });
    } else if (std.mem.eql(u8, cmd, "browser")) {
        const what = it.next() orelse return fail(err, browser_help);
        const eq = std.mem.eql;
        if (eq(u8, what, "up")) {
            try s.events.append(gpa, .{ .browser = .up });
        } else if (eq(u8, what, "scroll")) {
            try s.events.append(gpa, .{ .browser = .{ .scroll = @intFromFloat(try num(err, &it)) } });
        } else if (eq(u8, what, "home") or eq(u8, what, "cd")) {
            const name = it.next() orelse return fail(err, browser_help);
            const owned = try gpa.dupe(u8, name);
            errdefer gpa.free(owned);
            try s.events.append(gpa, .{ .browser = if (what[0] == 'h') .{ .home = owned } else .{ .cd = owned } });
        } else if (eq(u8, what, "drag")) {
            const name = it.next() orelse return fail(err, browser_help);
            const x = try num(err, &it);
            const y = try num(err, &it);
            const hold = if (it.next()) |w| eq(u8, w, "hold") else false;
            const owned = try gpa.dupe(u8, name);
            errdefer gpa.free(owned);
            try s.events.append(gpa, .{ .browser = .{ .drag = .{ .name = owned, .x = x, .y = y, .hold = hold } } });
        } else return fail(err, browser_help);
    } else if (std.mem.eql(u8, cmd, "capture")) {
        s.capture = true;
    } else if (std.mem.eql(u8, cmd, "window")) {
        const x: i32 = @intFromFloat(try num(err, &it));
        const y: i32 = @intFromFloat(try num(err, &it));
        const w: i32 = @intFromFloat(try num(err, &it));
        const h: i32 = @intFromFloat(try num(err, &it));
        try s.windows.append(gpa, core.geom.Rect.fromSize(x, y, w, h));
    } else if (std.mem.eql(u8, cmd, "delay")) {
        s.delay_ms = @intFromFloat(@round(try num(err, &it) * 1000));
    } else if (std.mem.eql(u8, cmd, "size")) {
        s.size = .{ @intFromFloat(try num(err, &it)), @intFromFloat(try num(err, &it)) };
    } else if (std.mem.eql(u8, cmd, "move")) {
        if (it.peek() != null and std.mem.eql(u8, it.peek().?, "ui")) { // hover a chrome item
            _ = it.next();
            try s.events.append(gpa, .{ .hover = try parseUi(&it, err) });
        } else try ev.append(gpa, .{ .mouse_move = .{ .x = try num(err, &it), .y = try num(err, &it) } });
    } else if (std.mem.eql(u8, cmd, "down") or std.mem.eql(u8, cmd, "up") or std.mem.eql(u8, cmd, "click")) {
        const x = try num(err, &it);
        const y = try num(err, &it);
        const b: input.Button = if (it.next()) |bn| std.meta.stringToEnum(input.Button, bn) orelse return fail(err, "button must be left, middle or right") else .left;
        if (cmd[0] != 'u') try ev.append(gpa, .{ .mouse_down = .{ .x = x, .y = y, .button = b } });
        if (cmd[0] != 'd') try ev.append(gpa, .{ .mouse_up = .{ .x = x, .y = y, .button = b } });
    } else if (std.mem.eql(u8, cmd, "dblclick")) { // two clicks; the second one is the double click
        const x = try num(err, &it);
        const y = try num(err, &it);
        try ev.append(gpa, .{ .mouse_down = .{ .x = x, .y = y } });
        try ev.append(gpa, .{ .mouse_up = .{ .x = x, .y = y } });
        try ev.append(gpa, .{ .mouse_down = .{ .x = x, .y = y, .clicks = 2 } });
        try ev.append(gpa, .{ .mouse_up = .{ .x = x, .y = y } });
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
    } else if (std.mem.eql(u8, cmd, "keyup")) { // a key released (`key space` presses it: the hand)
        while (it.next()) |chord| {
            const k = input.parseChord(chord) catch return fail(err, "unknown key");
            try ev.append(gpa, .{ .key_up = k });
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
        try s.events.append(gpa, .{ .ui = try parseUi(&it, err) });
    } else if (std.mem.eql(u8, cmd, "resize")) {
        try ev.append(gpa, .{ .resize = .{ .w = @intFromFloat(try num(err, &it)), .h = @intFromFloat(try num(err, &it)) } });
    } else {
        return fail(err, "unknown command (image, size, move, down, up, click, drag, key, type, wheel, resize, ui, capture, window, delay)");
    }
}

/// The chrome item after `ui` (or `move ui`).
fn parseUi(it: *std.mem.TokenIterator(u8, .scalar), err: *ParseError) !UiTarget {
    const what = it.next() orelse return fail(err, ui_help);
    const eq = std.mem.eql;
    if (eq(u8, what, "tool")) {
        const name = it.next() orelse return fail(err, ui_help);
        for (core.keymap.tools) |info| {
            // The name up to a slash: `move` for "move/select".
            const short = info.name[0 .. std.mem.indexOfScalar(u8, info.name, '/') orelse info.name.len];
            if (eq(u8, info.name, name) or eq(u8, short, name)) return .{ .tool = info.tool };
        }
        return fail(err, "ui tool: unknown tool name (see the key map)");
    }
    if (eq(u8, what, "color")) {
        const k = try num(err, it);
        if (k < 1 or k > core.color.palette.len) return fail(err, "ui color: 1 to the palette size");
        return .{ .color = @intFromFloat(k - 1) };
    }
    if (eq(u8, what, "arrow-style") or eq(u8, what, "pointer-style")) {
        const name = it.next() orelse return .{ .arrow_style = null };
        return .{ .arrow_style = std.meta.stringToEnum(core.annotation.ArrowStyle, name) orelse return fail(err, "ui arrow-style: straight or stairs (none: the other one)") };
    }
    if (eq(u8, what, "text-style")) {
        const name = it.next() orelse return .{ .text_style = null };
        return .{ .text_style = std.meta.stringToEnum(core.annotation.TextStyle, name) orelse return fail(err, "ui text-style: plain or boxed (none: the other one)") };
    }
    if (eq(u8, what, "canvas-bg")) {
        const name = it.next() orelse return .{ .canvas_bg = null };
        return .{ .canvas_bg = std.meta.stringToEnum(core.settings.CanvasBg, name) orelse return fail(err, "ui canvas-bg: light or dark (none: the other one)") };
    }
    if (eq(u8, what, "padding")) {
        const px = try num(err, it);
        if (px < 0 or px > 65535) return fail(err, "ui padding: px, 0 to 65535 (the nearest step is used)");
        return .{ .padding = @intFromFloat(px) };
    }
    if (eq(u8, what, "browser")) return .browser;
    if (eq(u8, what, "size")) return .size;
    if (eq(u8, what, "help")) return .help;
    if (eq(u8, what, "undo")) return .undo;
    if (eq(u8, what, "redo")) return .redo;
    return fail(err, ui_help);
}

const browser_help = "browser needs: home DIR, cd NAME, up, scroll N or drag NAME X Y [hold]";

const ui_help = "ui needs: browser, tool NAME, color N, size, help, undo, redo, canvas-bg [light|dark], padding PX, arrow-style [straight|stairs] (alias pointer-style) or text-style [plain|boxed]";

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
        \\ui pointer-style straight
        \\ui canvas-bg
        \\ui canvas-bg dark
        \\move ui redo
    , &err);
    defer s.deinit(gpa);
    try std.testing.expectEqual(UiTarget.redo, s.events.pop().?.hover);
    try std.testing.expectEqual(UiTarget{ .canvas_bg = .dark }, s.events.pop().?.ui);
    try std.testing.expectEqual(UiTarget{ .canvas_bg = null }, s.events.pop().?.ui);
    try std.testing.expectEqual([2]u32{ 800, 500 }, s.size.?);
    try std.testing.expectEqualStrings("tests/fixtures/strip.png", s.image.?);
    try std.testing.expectEqual(@as(usize, 1 + 6 + 4 + 2 + 1 + 3 + 3), s.events.items.len);
    try std.testing.expectEqual(UiTarget{ .arrow_style = null }, s.events.items[s.events.items.len - 3].ui);
    try std.testing.expectEqual(UiTarget{ .arrow_style = .stairs }, s.events.items[s.events.items.len - 2].ui);
    try std.testing.expectEqual(UiTarget{ .arrow_style = .straight }, s.events.items[s.events.items.len - 1].ui);
    s.events.shrinkRetainingCapacity(s.events.items.len - 3);
    const z = s.events.items[s.events.items.len - 4].event.wheel;
    try std.testing.expect(z.mods.ctrl and z.delta == -1 and z.x == 10 and z.y == 20);
    try std.testing.expectError(error.BadScript, parse(gpa, "key a\nfly 1 2", &err));
    try std.testing.expectEqual(@as(usize, 2), err.line);
    try std.testing.expectEqual(UiTarget{ .tool = .crop }, s.events.items[s.events.items.len - 3].ui);
    try std.testing.expectEqual(UiTarget{ .color = 2 }, s.events.items[s.events.items.len - 2].ui);
    try std.testing.expectError(error.BadScript, parse(gpa, "ui tool lasso", &err));
    try std.testing.expectError(error.BadScript, parse(gpa, "ui arrow-style curly", &err));
    try std.testing.expectError(error.BadScript, parse(gpa, "ui canvas-bg white", &err));
}

test "parse capture script" {
    const gpa = std.testing.allocator;
    var err: ParseError = undefined;
    var s = try parse(gpa, "capture\nwindow 10 20 300 200\nwindow 0 0 640 480\ndelay 1.5\ndrag 5 5 50 50 3\nkey tab\n", &err);
    defer s.deinit(gpa);
    try std.testing.expect(s.capture);
    try std.testing.expectEqual(@as(usize, 2), s.windows.items.len);
    try std.testing.expectEqual(core.geom.Rect.fromSize(10, 20, 300, 200), s.windows.items[0]);
    try std.testing.expectEqual(@as(u32, 1500), s.delay_ms);
    try std.testing.expectError(error.BadScript, parse(gpa, "window 1 2 3", &err));
}

test "parse ui padding" {
    const gpa = std.testing.allocator;
    var err: ParseError = undefined;
    var s = try parse(gpa, "ui padding 96\nmove ui padding 0", &err);
    defer s.deinit(gpa);
    try std.testing.expectEqual(UiTarget{ .padding = 0 }, s.events.pop().?.hover);
    try std.testing.expectEqual(UiTarget{ .padding = 96 }, s.events.pop().?.ui);
    try std.testing.expectError(error.BadScript, parse(gpa, "ui padding wide", &err));
}

test "parse browser commands and touch" {
    const gpa = std.testing.allocator;
    var err: ParseError = undefined;
    var s = try parse(gpa,
        \\touch tests/fixtures/browser/a.png 1700000000
        \\browser home tests/fixtures/browser
        \\ui browser
        \\browser cd trips
        \\browser up
        \\browser scroll -2
        \\browser drag sunset.png 700 250 hold
    , &err);
    defer s.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 7), s.events.items.len);
    try std.testing.expectEqual(@as(i64, 1700000000), s.events.items[0].touch.secs);
    try std.testing.expectEqualStrings("tests/fixtures/browser", s.events.items[1].browser.home);
    try std.testing.expect(s.events.items[2].ui == .browser);
    try std.testing.expectEqualStrings("trips", s.events.items[3].browser.cd);
    try std.testing.expect(s.events.items[4].browser == .up);
    try std.testing.expectEqual(@as(i32, -2), s.events.items[5].browser.scroll);
    const d = s.events.items[6].browser.drag;
    try std.testing.expect(d.hold and d.x == 700 and d.y == 250);
    try std.testing.expectError(error.BadScript, parse(gpa, "browser fly", &err));
}
