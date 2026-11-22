//! Entry point: parses the command line and starts a backend.
const std = @import("std");
const core = @import("core");

pub fn main() !void {
    std.debug.print("annotate: not implemented yet ({d} bytes of font)\n", .{core.font_ttf.len});
}

test {
    std.testing.refAllDecls(@This());
}
