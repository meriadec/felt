//! Document: the ordered list of annotations, the crops, and the undo/redo
//! history of both, moves and deletions included. Every change bumps
//! `revision`; every removal or insertion of an annotation but an append also
//! bumps `removals`, which tells the compositor that appending on top of its
//! cache is not enough. A move changes an
//! annotation in place (same index, same text): the compositor finds it by
//! comparing with what it painted. A step may carry chained moves: the
//! re-routes of other stairs paths that the step caused (route.zig). Undo
//! and redo take a step and its chained moves together, from the stored
//! geometry: nothing is routed again.
const std = @import("std");
const Annotation = @import("annotation.zig").Annotation;
const Rect = @import("geom.zig").Rect;

/// A crop: the kept rectangle (image pixels, may reach past the image into
/// the white canvas) and the number of annotations made before it. The
/// crop clips those; later annotations can grow the canvas again.
pub const Crop = struct { rect: Rect, first: usize };

/// A move of annotation `index`: `other` is its geometry on the other side
/// of the step (before the move in the history, after it in the redo stack).
/// `other` shares the text of the annotation; it never owns it. `chained`:
/// part of the step before it (a re-route that step caused).
pub const Move = struct { index: usize, other: Annotation, chained: bool = false };

/// A deleted annotation: it sat at `index`; the last `shifted` crops had
/// counted it (their `first` is one less while it is gone). The history owns
/// its text while the annotation is deleted.
const Removed = struct { index: usize, ann: Annotation, shifted: usize };

/// One undoable step.
const Change = union(enum) { add, crop, move: Move, remove: Removed };

/// One undone step for redo. An undone `remove` holds no annotation: it is
/// back in `items`, and a redo deletes it again.
const Undone = union(enum) {
    add: Annotation,
    crop: Crop,
    move: Move,
    remove: struct { index: usize, shifted: usize },
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
    /// Every text that a text edit replaced or made. Undo and redo swap
    /// them in and out of `items` (a move never owns text), so the document
    /// owns them all until it ends; an annotation does not free these.
    edit_texts: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Document, gpa: std.mem.Allocator) void {
        for (self.items.items) |a| self.release(gpa, a);
        for (self.history.items) |c| if (c == .remove) self.release(gpa, c.remove.ann);
        for (self.undone.items) |u| if (u == .add) self.release(gpa, u.add);
        for (self.edit_texts.items) |t| gpa.free(t);
        self.edit_texts.deinit(gpa);
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
        for (self.undone.items) |u| if (u == .add) self.release(gpa, u.add);
        self.undone.clearRetainingCapacity();
    }

    /// Free the text of `a`, unless the document owns it as an edit text.
    fn release(self: *const Document, gpa: std.mem.Allocator, a: Annotation) void {
        const t = a.ownedText() orelse return;
        for (self.edit_texts.items) |e| if (e.ptr == t.ptr) return;
        gpa.free(t);
    }

    /// Replace the text of annotation `i` (a text or a callout) by a copy of
    /// `text`, in place and without a history step: `commitMove` records it
    /// with the annotation as it was before. `old` is the text it had: the
    /// document keeps it for the undo. Returns the new annotation.
    pub fn setText(self: *Document, gpa: std.mem.Allocator, i: usize, old: Annotation, text: []const u8) !Annotation {
        try self.edit_texts.ensureUnusedCapacity(gpa, 2);
        const owned = try gpa.dupe(u8, text);
        var a = old;
        switch (a) {
            .text => |*t| t.text = owned,
            .callout => |*c| c.text = owned,
            else => unreachable,
        }
        if (old.ownedText()) |o| {
            var known = false;
            for (self.edit_texts.items) |e| known = known or e.ptr == o.ptr;
            if (!known) self.edit_texts.appendAssumeCapacity(o);
        }
        self.edit_texts.appendAssumeCapacity(owned);
        self.setLive(i, a);
        return a;
    }

    /// Append `ann` and take ownership of its text. Clears the redo stack.
    pub fn add(self: *Document, gpa: std.mem.Allocator, ann: Annotation) !void {
        try self.history.ensureUnusedCapacity(gpa, 1);
        try self.items.append(gpa, ann);
        self.history.appendAssumeCapacity(.add);
        self.clearRedo(gpa);
        self.revision += 1;
    }

    /// Delete annotation `i` as one undo step; the history keeps it (and its
    /// text) for the undo. Later annotations move down one place, and so do
    /// the crops that counted it. Clears the redo stack.
    pub fn remove(self: *Document, gpa: std.mem.Allocator, i: usize) !void {
        try self.history.ensureUnusedCapacity(gpa, 1);
        const a = self.items.orderedRemove(i);
        self.history.appendAssumeCapacity(.{ .remove = .{ .index = i, .ann = a, .shifted = self.shiftCrops(i, -1) } });
        self.clearRedo(gpa);
        self.revision += 1;
        self.removals += 1;
    }

    /// Move `first` of the crops that count the annotation at `i` by `d`
    /// (-1 after its removal, +1 before its return); how many. Crops that
    /// count it are the newest ones: `first` never decreases along the stack.
    fn shiftCrops(self: *Document, i: usize, d: i32) usize {
        var n: usize = 0;
        for (self.crops.items) |*c| if (c.first > i) {
            c.first = @intCast(@as(i64, @intCast(c.first)) + d);
            n += 1;
        };
        return n;
    }

    /// Replace annotation `i` by `a` (same kind and text, new geometry)
    /// without a history step: a move in progress.
    pub fn setLive(self: *Document, i: usize, a: Annotation) void {
        self.items.items[i] = a;
        self.revision += 1;
    }

    /// Record the move of annotation `i` from `before` (its geometry when the
    /// move started) to its current geometry as one undo step. Nothing if it
    /// did not change. Clears the redo stack. Returns whether it recorded a step.
    pub fn commitMove(self: *Document, gpa: std.mem.Allocator, i: usize, before: Annotation) !bool {
        if (std.meta.eql(before, self.items.items[i])) return false;
        try self.history.append(gpa, .{ .move = .{ .index = i, .other = before } });
        self.clearRedo(gpa);
        self.revision += 1;
        return true;
    }

    /// Record that annotation `i` changed from `before` to its current
    /// geometry as part of the last step (a re-route that step caused).
    /// Nothing if it did not change. Needs a last step.
    pub fn commitChained(self: *Document, gpa: std.mem.Allocator, i: usize, before: Annotation) !void {
        std.debug.assert(self.history.items.len > 0);
        if (std.meta.eql(before, self.items.items[i])) return;
        try self.history.append(gpa, .{ .move = .{ .index = i, .other = before, .chained = true } });
        self.revision += 1;
    }

    /// Swap annotation `m.index` with `m.other`: the step seen from the other side.
    fn swapMove(self: *Document, m: Move) Move {
        const cur = self.items.items[m.index];
        self.items.items[m.index] = m.other;
        return .{ .index = m.index, .other = cur, .chained = m.chained };
    }

    fn isChained(c: anytype) bool {
        return c == .move and c.move.chained;
    }

    /// Keep only `r` (image pixels) of the canvas. Clears the redo stack.
    pub fn setCrop(self: *Document, gpa: std.mem.Allocator, r: Rect) !void {
        try self.history.ensureUnusedCapacity(gpa, 1);
        try self.crops.append(gpa, .{ .rect = r, .first = self.items.items.len });
        self.history.appendAssumeCapacity(.crop);
        self.clearRedo(gpa);
        self.revision += 1;
    }

    /// Undo the last step: its chained moves (last first), then the step.
    pub fn undo(self: *Document, gpa: std.mem.Allocator) !bool {
        if (self.history.items.len == 0) return false;
        // Room for the whole step first: it never stops half undone.
        var n: usize = 1;
        while (isChained(self.history.items[self.history.items.len - n])) n += 1;
        try self.undone.ensureUnusedCapacity(gpa, n);
        try self.items.ensureUnusedCapacity(gpa, 1);
        for (0..n) |_| switch (self.history.pop().?) {
            .remove => |r| {
                self.items.insertAssumeCapacity(r.index, r.ann);
                const shifted = r.shifted;
                for (self.crops.items[self.crops.items.len - shifted ..]) |*c| c.first += 1;
                self.undone.appendAssumeCapacity(.{ .remove = .{ .index = r.index, .shifted = shifted } });
                self.removals += 1;
            },
            .add => {
                self.undone.appendAssumeCapacity(.{ .add = self.items.pop().? });
                self.removals += 1;
            },
            .crop => self.undone.appendAssumeCapacity(.{ .crop = self.crops.pop().? }),
            .move => |m| self.undone.appendAssumeCapacity(.{ .move = self.swapMove(m) }),
        };
        self.revision += 1;
        return true;
    }

    /// Redo the last undone step, then its chained moves (first first).
    pub fn redo(self: *Document, gpa: std.mem.Allocator) !bool {
        const len = self.undone.items.len;
        if (len == 0) return false;
        var n: usize = 1;
        while (n < len and isChained(self.undone.items[len - 1 - n])) n += 1;
        try self.items.ensureUnusedCapacity(gpa, 1);
        try self.crops.ensureUnusedCapacity(gpa, 1);
        try self.history.ensureUnusedCapacity(gpa, n);
        for (0..n) |_| self.history.appendAssumeCapacity(switch (self.undone.pop().?) {
            .add => |a| blk: {
                self.items.appendAssumeCapacity(a);
                break :blk .add;
            },
            .crop => |c| blk: {
                self.crops.appendAssumeCapacity(c);
                break :blk .crop;
            },
            .move => |m| .{ .move = self.swapMove(m) },
            .remove => |r| blk: {
                const a = self.items.orderedRemove(r.index);
                for (self.crops.items[self.crops.items.len - r.shifted ..]) |*c| c.first -= 1;
                self.removals += 1;
                break :blk .{ .remove = .{ .index = r.index, .ann = a, .shifted = r.shifted } };
            },
        });
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

test "a move is one undo step: undo and redo swap the geometry back and forth" {
    const gpa = std.testing.allocator;
    var doc = Document{};
    defer doc.deinit(gpa);
    const at = struct {
        fn f(x: f32) Annotation {
            return .{ .number = .{ .center = .{ .x = x, .y = 0 }, .value = 1, .size = 10, .color = .{ .r = 0, .g = 0, .b = 0 } } };
        }
    }.f;
    try doc.add(gpa, at(0));
    try doc.add(gpa, at(5));
    const before = doc.items.items[0];
    doc.setLive(0, at(10));
    doc.setLive(0, at(20));
    try std.testing.expect(try doc.commitMove(gpa, 0, before));
    try std.testing.expect(!try doc.commitMove(gpa, 1, doc.items.items[1])); // no change: no step
    try std.testing.expectEqual(@as(usize, 3), doc.history.items.len);
    try std.testing.expect(try doc.undo(gpa));
    try std.testing.expectEqual(@as(f32, 0), doc.items.items[0].number.center.x);
    try std.testing.expect(try doc.redo(gpa));
    try std.testing.expectEqual(@as(f32, 20), doc.items.items[0].number.center.x);
    try std.testing.expect(try doc.undo(gpa));
    try std.testing.expect(try doc.undo(gpa)); // the second number
    try std.testing.expectEqual(@as(usize, 1), doc.items.items.len);
    try doc.add(gpa, at(7)); // clears the redo stack (the move and the add)
    try std.testing.expect(!try doc.redo(gpa));
    // A moved text keeps its text: the move shares it, deinit frees it once.
    try doc.add(gpa, .{ .text = .{ .pos = .{ .x = 0, .y = 0 }, .text = try gpa.dupe(u8, "hi"), .size = 10, .color = .{ .r = 0, .g = 0, .b = 0 } } });
    var t = doc.items.items[2];
    t.text.pos.x = 30;
    const tb = doc.items.items[2];
    doc.setLive(2, t);
    _ = try doc.commitMove(gpa, 2, tb);
    try std.testing.expect(try doc.undo(gpa));
}

test "chained moves undo and redo with their step, in order, exactly" {
    const gpa = std.testing.allocator;
    var doc = Document{};
    defer doc.deinit(gpa);
    const at = struct {
        fn f(x: f32) Annotation {
            return .{ .number = .{ .center = .{ .x = x, .y = 0 }, .value = 1, .size = 10, .color = .{ .r = 0, .g = 0, .b = 0 } } };
        }
    }.f;
    try doc.add(gpa, at(0));
    try doc.add(gpa, at(1));
    // An add that changed both earlier ones, the first twice.
    try doc.add(gpa, at(2));
    const b0 = doc.items.items[0];
    const b1 = doc.items.items[1];
    doc.setLive(0, at(10));
    doc.setLive(1, at(11));
    doc.setLive(0, at(20));
    try doc.commitChained(gpa, 0, b0);
    try doc.commitChained(gpa, 1, b1);
    try doc.commitChained(gpa, 2, doc.items.items[2]); // no change: no move
    try std.testing.expectEqual(@as(usize, 5), doc.history.items.len);
    try std.testing.expect(try doc.undo(gpa));
    try std.testing.expectEqual(@as(usize, 2), doc.items.items.len);
    try std.testing.expectEqual(@as(f32, 0), doc.items.items[0].number.center.x);
    try std.testing.expectEqual(@as(f32, 1), doc.items.items[1].number.center.x);
    try std.testing.expect(try doc.redo(gpa));
    try std.testing.expectEqual(@as(usize, 3), doc.items.items.len);
    try std.testing.expectEqual(@as(f32, 20), doc.items.items[0].number.center.x);
    try std.testing.expectEqual(@as(f32, 11), doc.items.items[1].number.center.x);
    // A move with a chained move: one step too; the step before stays.
    const m0 = doc.items.items[2];
    const c1 = doc.items.items[1];
    doc.setLive(2, at(30));
    _ = try doc.commitMove(gpa, 2, m0);
    doc.setLive(1, at(31));
    try doc.commitChained(gpa, 1, c1);
    try std.testing.expect(try doc.undo(gpa));
    try std.testing.expectEqual(@as(f32, 2), doc.items.items[2].number.center.x);
    try std.testing.expectEqual(@as(f32, 11), doc.items.items[1].number.center.x);
    try std.testing.expectEqual(@as(f32, 20), doc.items.items[0].number.center.x);
    try std.testing.expect(try doc.undo(gpa)); // the add and its two
    try std.testing.expectEqual(@as(usize, 2), doc.items.items.len);
    try std.testing.expect(try doc.redo(gpa));
    try std.testing.expect(try doc.redo(gpa));
    try std.testing.expectEqual(@as(f32, 30), doc.items.items[2].number.center.x);
    try std.testing.expectEqual(@as(f32, 31), doc.items.items[1].number.center.x);
    try std.testing.expect(!try doc.redo(gpa));
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

test "a deletion is one undo step: undo puts the annotation back in place, crops included" {
    const gpa = std.testing.allocator;
    var doc = Document{};
    defer doc.deinit(gpa);
    const at = struct {
        fn f(x: f32) Annotation {
            return .{ .number = .{ .center = .{ .x = x, .y = 0 }, .value = 1, .size = 10, .color = .{ .r = 0, .g = 0, .b = 0 } } };
        }
    }.f;
    try doc.add(gpa, at(0));
    try doc.add(gpa, .{ .text = .{ .pos = .{ .x = 1, .y = 0 }, .text = try gpa.dupe(u8, "hi"), .size = 10, .color = .{ .r = 0, .g = 0, .b = 0 } } });
    try doc.setCrop(gpa, Rect.fromSize(0, 0, 50, 50));
    try doc.add(gpa, at(2));
    const removals = doc.removals;
    try doc.remove(gpa, 1); // the text, made before the crop
    try std.testing.expectEqual(@as(usize, 2), doc.items.items.len);
    try std.testing.expectEqual(@as(usize, 1), doc.crop().?.first);
    try std.testing.expect(doc.removals > removals);
    try std.testing.expect(try doc.undo(gpa));
    try std.testing.expectEqual(@as(usize, 3), doc.items.items.len);
    try std.testing.expectEqualStrings("hi", doc.items.items[1].text.text);
    try std.testing.expectEqual(@as(usize, 2), doc.crop().?.first);
    try std.testing.expect(try doc.redo(gpa));
    try std.testing.expectEqual(@as(usize, 2), doc.items.items.len);
    try std.testing.expectEqual(@as(usize, 1), doc.crop().?.first);
    // Deleting an annotation made after the crop leaves the crop alone.
    try doc.remove(gpa, 1);
    try std.testing.expectEqual(@as(usize, 1), doc.crop().?.first);
    try std.testing.expect(try doc.undo(gpa));
    try std.testing.expectEqual(@as(usize, 1), doc.crop().?.first);
    try std.testing.expect(try doc.undo(gpa)); // the first deletion is still in the history
    try std.testing.expectEqual(@as(usize, 2), doc.crop().?.first);
    // A new step clears the redo stack; the deleted text is freed with the history.
    try doc.remove(gpa, 1);
    try std.testing.expect(!try doc.redo(gpa));
}
