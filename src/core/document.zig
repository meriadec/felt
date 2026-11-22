//! Document: the ordered list of annotations, the crops, and the undo/redo
//! history of both. Every change bumps `revision`; every removal of an
//! annotation also bumps `removals`, which tells the compositor that
//! appending on top of its cache is not enough.
const std = @import("std");
const Annotation = @import("annotation.zig").Annotation;
const Rect = @import("geom.zig").Rect;

/// A crop: the kept rectangle (image pixels, may reach past the image into
/// the white canvas) and the number of annotations made before it. The
/// crop clips those; later annotations can grow the canvas again.
pub const Crop = struct { rect: Rect, first: usize };

/// One undoable step.
const Change = enum { add, crop };

/// One undone step for redo.
const Undone = union(enum) {
    add: Annotation,
    crop: Crop,

    fn deinit(u: Undone, gpa: std.mem.Allocator) void {
        if (u == .add) u.add.deinit(gpa);
    }
};

pub const Document = struct {
    items: std.ArrayList(Annotation) = .empty,
    /// Active crops, oldest first. Annotations keep their image
    /// coordinates: a crop only moves the window.
    crops: std.ArrayList(Crop) = .empty,
    history: std.ArrayList(Change) = .empty,
    undone: std.ArrayList(Undone) = .empty,
    revision: u64 = 0,
    removals: u64 = 0,

    pub fn deinit(self: *Document, gpa: std.mem.Allocator) void {
        for (self.items.items) |a| a.deinit(gpa);
        for (self.undone.items) |u| u.deinit(gpa);
        self.items.deinit(gpa);
        self.crops.deinit(gpa);
        self.history.deinit(gpa);
        self.undone.deinit(gpa);
    }

    /// The last crop, if any.
    pub fn crop(self: *const Document) ?Crop {
        const n = self.crops.items.len;
        return if (n == 0) null else self.crops.items[n - 1];
    }

    /// The kept rectangle before annotations grow it: the last crop, or all
    /// of an image of size w x h.
    pub fn kept(self: *const Document, w: u32, h: u32) Rect {
        return if (self.crop()) |c| c.rect else Rect.fromSize(0, 0, @intCast(w), @intCast(h));
    }

    /// Annotations that can grow the canvas: those made after the last crop.
    pub fn growing(self: *const Document) []const Annotation {
        return self.items.items[if (self.crop()) |c| c.first else 0..];
    }

    /// Clip of annotation `i` from the crops made after it (image pixels);
    /// null when no crop came after it.
    pub fn clipOf(self: *const Document, i: usize) ?Rect {
        var r: ?Rect = null;
        for (self.crops.items) |c| {
            if (c.first <= i) continue;
            r = if (r) |x| x.intersect(c.rect) else c.rect;
        }
        return r;
    }

    fn clearRedo(self: *Document, gpa: std.mem.Allocator) void {
        for (self.undone.items) |u| u.deinit(gpa);
        self.undone.clearRetainingCapacity();
    }

    /// Append `ann` and take ownership of its text. Clears the redo stack.
    pub fn add(self: *Document, gpa: std.mem.Allocator, ann: Annotation) !void {
        try self.history.ensureUnusedCapacity(gpa, 1);
        try self.items.append(gpa, ann);
        self.history.appendAssumeCapacity(.add);
        self.clearRedo(gpa);
        self.revision += 1;
    }

    /// Keep only `r` (image pixels) of the canvas. Clears the redo stack.
    pub fn setCrop(self: *Document, gpa: std.mem.Allocator, r: Rect) !void {
        try self.history.ensureUnusedCapacity(gpa, 1);
        try self.crops.append(gpa, .{ .rect = r, .first = self.items.items.len });
        self.history.appendAssumeCapacity(.crop);
        self.clearRedo(gpa);
        self.revision += 1;
    }

    pub fn undo(self: *Document, gpa: std.mem.Allocator) !bool {
        try self.undone.ensureUnusedCapacity(gpa, 1);
        const change = self.history.pop() orelse return false;
        switch (change) {
            .add => {
                self.undone.appendAssumeCapacity(.{ .add = self.items.pop().? });
                self.removals += 1;
            },
            .crop => self.undone.appendAssumeCapacity(.{ .crop = self.crops.pop().? }),
        }
        self.revision += 1;
        return true;
    }

    pub fn redo(self: *Document, gpa: std.mem.Allocator) !bool {
        try self.items.ensureUnusedCapacity(gpa, 1);
        try self.crops.ensureUnusedCapacity(gpa, 1);
        try self.history.ensureUnusedCapacity(gpa, 1);
        const u = self.undone.pop() orelse return false;
        switch (u) {
            .add => |a| self.items.appendAssumeCapacity(a),
            .crop => |c| self.crops.appendAssumeCapacity(c),
        }
        self.history.appendAssumeCapacity(if (u == .add) .add else .crop);
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

test "crop is undone and redone in order with annotations" {
    const gpa = std.testing.allocator;
    var doc = Document{};
    defer doc.deinit(gpa);
    const num = Annotation{ .number = .{ .center = .{ .x = 0, .y = 0 }, .value = 1, .size = 10, .color = .{ .r = 0, .g = 0, .b = 0 } } };
    const r = Rect.fromSize(10, 10, 50, 40);
    try doc.add(gpa, num);
    try doc.setCrop(gpa, r);
    try doc.add(gpa, num);
    try std.testing.expectEqual(Rect.fromSize(0, 0, 100, 80), (Document{}).kept(100, 80));
    try std.testing.expectEqual(r, doc.kept(100, 80));
    try std.testing.expectEqual(r, doc.clipOf(0).?);
    try std.testing.expectEqual(@as(?Rect, null), doc.clipOf(1));
    try std.testing.expectEqual(@as(usize, 1), doc.growing().len);
    try std.testing.expect(try doc.undo(gpa)); // second number
    try std.testing.expectEqual(r, doc.crop().?.rect);
    try std.testing.expect(try doc.undo(gpa)); // crop
    try std.testing.expectEqual(@as(?Crop, null), doc.crop());
    try std.testing.expectEqual(@as(usize, 1), doc.items.items.len);
    try std.testing.expect(try doc.redo(gpa));
    try std.testing.expectEqual(r, doc.crop().?.rect);
    try std.testing.expect(try doc.redo(gpa));
    try std.testing.expectEqual(@as(usize, 2), doc.items.items.len);
}

test "an annotation is clipped by every later crop" {
    const gpa = std.testing.allocator;
    var doc = Document{};
    defer doc.deinit(gpa);
    const num = Annotation{ .number = .{ .center = .{ .x = 0, .y = 0 }, .value = 1, .size = 10, .color = .{ .r = 0, .g = 0, .b = 0 } } };
    try doc.add(gpa, num);
    try doc.setCrop(gpa, Rect.fromSize(0, 0, 50, 50));
    try doc.add(gpa, num);
    try doc.setCrop(gpa, Rect.fromSize(-20, 10, 60, 60));
    try std.testing.expectEqual(Rect{ .x0 = 0, .y0 = 10, .x1 = 40, .y1 = 50 }, doc.clipOf(0).?);
    try std.testing.expectEqual(Rect.fromSize(-20, 10, 60, 60), doc.clipOf(1).?);
}
