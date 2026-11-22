//! Backend-neutral input events. Backends translate native events to these;
//! the headless script parser produces them too. Coordinates are screen pixels.
const std = @import("std");

pub const Mods = packed struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
};

pub const Named = enum { escape, enter, backspace, delete, tab, f1, left, right, up, down, home, end };

pub const Key = union(enum) {
    /// The character the key produces with the current modifiers ('A' with shift).
    char: u21,
    named: Named,
};

pub const KeyEvent = struct {
    key: Key,
    mods: Mods = .{},
};

pub const Button = enum { left, middle, right };

pub const Pointer = struct { x: f32, y: f32 };

pub const Event = union(enum) {
    mouse_down: struct { x: f32, y: f32, button: Button = .left },
    mouse_up: struct { x: f32, y: f32, button: Button = .left },
    mouse_move: Pointer,
    /// `delta`: +1 per wheel step up, -1 down; at the pointer, with the
    /// modifiers held.
    wheel: struct { delta: i32, x: f32 = 0, y: f32 = 0, mods: Mods = .{} },
    key: KeyEvent,
    resize: struct { w: u32, h: u32 },
};

/// Parse a chord such as "a", "ctrl+shift+z", "enter", "f1", "?".
pub fn parseChord(s: []const u8) !KeyEvent {
    var ev = KeyEvent{ .key = .{ .char = 0 } };
    var rest = s;
    while (std.mem.indexOfScalar(u8, rest, '+')) |i| {
        if (i == 0 or i == rest.len - 1) break; // "+" alone or trailing
        const m = rest[0..i];
        if (std.ascii.eqlIgnoreCase(m, "ctrl")) ev.mods.ctrl = true else if (std.ascii.eqlIgnoreCase(m, "shift")) ev.mods.shift = true else if (std.ascii.eqlIgnoreCase(m, "alt")) ev.mods.alt = true else return error.UnknownModifier;
        rest = rest[i + 1 ..];
    }
    const names = [_]struct { []const u8, Named }{
        .{ "esc", .escape },          .{ "escape", .escape }, .{ "enter", .enter }, .{ "return", .enter },
        .{ "backspace", .backspace }, .{ "delete", .delete }, .{ "tab", .tab },     .{ "f1", .f1 },
        .{ "left", .left },           .{ "right", .right },   .{ "up", .up },       .{ "down", .down },
        .{ "home", .home },           .{ "end", .end },
    };
    if (std.ascii.eqlIgnoreCase(rest, "space")) {
        ev.key = .{ .char = ' ' };
        return ev;
    }
    for (names) |n| if (std.ascii.eqlIgnoreCase(rest, n[0])) {
        ev.key = .{ .named = n[1] };
        return ev;
    };
    const view = std.unicode.Utf8View.init(rest) catch return error.UnknownKey;
    var it = view.iterator();
    const cp = it.nextCodepoint() orelse return error.UnknownKey;
    if (it.nextCodepoint() != null) return error.UnknownKey;
    // shift+letter produces the upper case letter, like a real keyboard.
    ev.key = .{ .char = if (ev.mods.shift and cp < 128) std.ascii.toUpper(@intCast(cp)) else cp };
    return ev;
}

test "parse chords" {
    const z = try parseChord("ctrl+shift+z");
    try std.testing.expect(z.mods.ctrl and z.mods.shift);
    try std.testing.expectEqual(Key{ .char = 'Z' }, z.key);
    try std.testing.expectEqual(Key{ .named = .enter }, (try parseChord("Return")).key);
    try std.testing.expectEqual(Key{ .char = '?' }, (try parseChord("?")).key);
    try std.testing.expectEqual(Key{ .char = '+' }, (try parseChord("+")).key);
    try std.testing.expectError(error.UnknownKey, parseChord("nope"));
}
