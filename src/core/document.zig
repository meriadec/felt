//! Document: the ordered list of annotations plus the redo stack.
//! Every change bumps `revision`; every removal also bumps `removals`, which
//! tells the compositor that appending on top of its cache is not enough.
const std = @import("std");
const Annotation = @import("annotation.zig").Annotation;

pub const Document = struct {
    items: std.ArrayList(Annotation) = .empty,
    undone: std.ArrayList(Annotation) = .empty,
    revision: u64 = 0,
    removals: u64 = 0,

    pub fn deinit(self: *Document, gpa: std.mem.Allocator) void {
        for (self.items.items) |a| a.deinit(gpa);
        for (self.undone.items) |a| a.deinit(gpa);
        self.items.deinit(gpa);
        self.undone.deinit(gpa);
    }

    /// Append `ann` and take ownership of its text. Clears the redo stack.
    pub fn add(self: *Document, gpa: std.mem.Allocator, ann: Annotation) !void {
        try self.items.append(gpa, ann);
        for (self.undone.items) |a| a.deinit(gpa);
        self.undone.clearRetainingCapacity();
        self.revision += 1;
    }

    pub fn undo(self: *Document, gpa: std.mem.Allocator) !bool {
        try self.undone.ensureUnusedCapacity(gpa, 1);
        const a = self.items.pop() orelse return false;
        self.undone.appendAssumeCapacity(a);
        self.revision += 1;
        self.removals += 1;
        return true;
    }

    pub fn redo(self: *Document, gpa: std.mem.Allocator) !bool {
        try self.items.ensureUnusedCapacity(gpa, 1);
        const a = self.undone.pop() orelse return false;
        self.items.appendAssumeCapacity(a);
        self.revision += 1;
        return true;
    }

    /// Value of the next numbered bubble: one more than the highest present.
    pub fn nextNumber(self: *const Document) u32 {
        var n: u32 = 0;
        for (self.items.items) |a| switch (a) {
            .number => |b| n = @max(n, b.value),
            else => {},
        };
        return n + 1;
    }
};

test "undo and redo move items and the number counter" {
    const gpa = std.testing.allocator;
    var doc = Document{};
    defer doc.deinit(gpa);
    const num = Annotation{ .number = .{ .center = .{ .x = 0, .y = 0 }, .value = 1, .size = 10, .color = .{ .r = 0, .g = 0, .b = 0 } } };
    try doc.add(gpa, num);
    try std.testing.expectEqual(@as(u32, 2), doc.nextNumber());
    try std.testing.expect(try doc.undo(gpa));
    try std.testing.expectEqual(@as(u32, 1), doc.nextNumber());
    try std.testing.expect(try doc.redo(gpa));
    try std.testing.expectEqual(@as(u32, 2), doc.nextNumber());
    try std.testing.expect(!try doc.redo(gpa));
    const t = Annotation{ .text = .{ .pos = .{ .x = 0, .y = 0 }, .text = try gpa.dupe(u8, "hi"), .size = 10, .color = .{ .r = 0, .g = 0, .b = 0 } } };
    try doc.add(gpa, t);
    try std.testing.expect(try doc.undo(gpa)); // text now on the redo stack, freed by deinit
}
