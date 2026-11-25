//! The UI font: the optional font file named by the settings (`ui_font`,
//! `ui_font_size`) for the chrome, the browser, the picker and the ruler.
//! Annotation text keeps the embedded font. A file that is missing or does
//! not load gives the embedded font (one stderr warning). Hold it at a
//! stable address: the font points into the file bytes.
const std = @import("std");
const Font = @import("font.zig").Font;
const settings = @import("settings.zig");

pub const max_file = 32 * 1024 * 1024;

pub const UiFont = struct {
    gpa: std.mem.Allocator,
    bytes: ?[]u8 = null,
    font: ?Font = null,

    pub fn init(gpa: std.mem.Allocator, s: settings.Settings) UiFont {
        var u = UiFont{ .gpa = gpa };
        const path = s.ui_font.slice();
        if (path.len == 0) return u;
        u.load(path, s.ui_font_size) catch |err| {
            std.log.warn("ui_font {s}: {s}; using the embedded font", .{ path, @errorName(err) });
            u.deinit();
        };
        return u;
    }

    fn load(u: *UiFont, path: []const u8, size: u8) !void {
        u.bytes = try std.fs.cwd().readFileAlloc(u.gpa, path, max_file);
        var f = try Font.init(u.gpa, u.bytes.?);
        f.size_k = @as(f32, @floatFromInt(size)) / @as(f32, @floatFromInt(settings.ui_font_size_default));
        f.by_em = true;
        u.font = f;
    }

    pub fn deinit(u: *UiFont) void {
        if (u.font) |*f| f.deinit();
        if (u.bytes) |b| u.gpa.free(b);
        u.font = null;
        u.bytes = null;
    }

    /// The font to draw the UI with, or null for the embedded one.
    pub fn get(u: *UiFont) ?*Font {
        return if (u.font != null) &u.font.? else null;
    }
};

test "no path, a missing file and a file that is no font all give the embedded font" {
    const gpa = std.testing.allocator;
    var a = UiFont.init(gpa, .{});
    defer a.deinit();
    try std.testing.expectEqual(@as(?*Font, null), a.get());
    var b = UiFont.init(gpa, .{ .ui_font = settings.FontPath.of("/nonexistent/felt-font.otf") });
    defer b.deinit();
    try std.testing.expectEqual(@as(?*Font, null), b.get());
    var c = UiFont.init(gpa, .{ .ui_font = settings.FontPath.of("build.zig") });
    defer c.deinit();
    try std.testing.expectEqual(@as(?*Font, null), c.get());
}

test "a font file loads and scales its pixel sizes" {
    const gpa = std.testing.allocator;
    var u = UiFont.init(gpa, .{ .ui_font = settings.FontPath.of("vendor/fonts/DejaVuSans-Bold.ttf"), .ui_font_size = 22 });
    defer u.deinit();
    const f = u.get().?;
    try std.testing.expectApproxEqAbs(@as(f32, 2), f.size_k, 0.001);
    // 11 nominal px at size 22: an em of 22 px, a line a bit taller.
    try std.testing.expect(f.lineHeight(11) >= 22);
    try std.testing.expect(f.lineHeight(11) < 30);
}
