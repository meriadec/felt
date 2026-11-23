//! Clipboard: hand a PNG to `xclip -selection clipboard -t image/png`.
//! xclip forks and keeps serving the clipboard after felt exits.
const std = @import("std");

pub fn copyPng(gpa: std.mem.Allocator, png: []const u8) !void {
    var child = std.process.Child.init(&.{ "xclip", "-selection", "clipboard", "-t", "image/png", "-i" }, gpa);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    child.stdin.?.writeAll(png) catch |err| {
        _ = child.kill() catch {};
        return err;
    };
    child.stdin.?.close();
    child.stdin = null;
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) return error.XclipFailed;
}
