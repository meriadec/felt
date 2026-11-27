//! Clipboard: hand a PNG to `xclip -selection clipboard -t image/png`.
//! xclip forks and keeps serving the clipboard after felt exits.
const std = @import("std");
const core = @import("core");

pub fn copyPng(gpa: std.mem.Allocator, png: []const u8) !void {
    _ = gpa;
    const io = core.sys.io();
    var child = try std.process.spawn(io, .{
        .argv = &.{ "xclip", "-selection", "clipboard", "-t", "image/png", "-i" },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    child.stdin.?.writeStreamingAll(io, png) catch |err| {
        child.kill(io);
        return err;
    };
    child.stdin.?.close(io);
    child.stdin = null;
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.XclipFailed;
}
