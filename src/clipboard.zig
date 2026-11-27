//! Clipboard: hand a PNG to `xclip -selection clipboard -t image/png`.
//! xclip forks and keeps serving the clipboard after felt exits; subprocess
//! diagnostics are sent to stderr.
const std = @import("std");
const core = @import("core");

pub fn copyPng(gpa: std.mem.Allocator, png: []const u8) !void {
    _ = gpa;
    const io = core.sys.io();
    var child = std.process.spawn(io, .{
        .argv = &.{ "xclip", "-selection", "clipboard", "-t", "image/png", "-i" },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch |err| {
        std.debug.print("felt: clipboard: couldn't start xclip: {s}\n", .{@errorName(err)});
        return err;
    };
    child.stdin.?.writeStreamingAll(io, png) catch |err| {
        std.debug.print("felt: clipboard: writing PNG to xclip failed: {s}\n", .{@errorName(err)});
        child.kill(io);
        return err;
    };
    child.stdin.?.close(io);
    child.stdin = null;
    const term = child.wait(io) catch |err| {
        std.debug.print("felt: clipboard: waiting for xclip failed: {s}\n", .{@errorName(err)});
        return err;
    };
    if (term != .exited or term.exited != 0) {
        if (term == .exited) {
            std.debug.print("felt: clipboard: xclip exited with status {d}\n", .{term.exited});
        } else {
            std.debug.print("felt: clipboard: xclip terminated ({s})\n", .{@tagName(term)});
        }
        return error.XclipFailed;
    }
}
