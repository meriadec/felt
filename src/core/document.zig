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
const scene_mod = @import("scene.zig");
const Scene = scene_mod.Scene;
const Placed = scene_mod.Placed;
const Vec2 = @import("geom.zig").Vec2;
const Canvas = @import("canvas.zig").Canvas;

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
const Removed = struct { index: usize, ann: Annotation, owner: u32, shifted: usize };

/// Owner of an annotation drawn where no image is.
pub const no_image: u32 = std.math.maxInt(u32);

/// A move of the image `id` by (`dx`, `dy`) scene px, with its annotations.
const ImageMove = struct { id: u32, dx: i32, dy: i32 };

/// One undoable step.
/// `image_remove`: the `n` steps before it are the removals of the annotations
/// of the image (one undo step together); the history owns the image.
const Change = union(enum) {
    add,
    crop,
    move: Move,
    remove: Removed,
    image_add,
    image_move: ImageMove,
    image_remove: struct { placed: Placed, index: usize, n: usize },
};

/// One undone step for redo. An undone `remove` holds no annotation: it is
/// back in `items`, and a redo deletes it again.
const Undone = union(enum) {
    add: struct { ann: Annotation, owner: u32 },
    crop: Crop,
    move: Move,
    remove: struct { index: usize, shifted: usize },
    image_add: Placed,
    image_move: ImageMove,
    image_remove: struct { index: usize, n: usize },
};

pub const Document = struct {
    /// The placed images (scene.zig). Annotations live in its space.
    scene: Scene = .{},
    items: std.ArrayList(Annotation) = .empty,
    /// The image (`Placed.id`) each annotation was drawn on, parallel to
    /// `items`; `no_image` if it was drawn where no image is. A moved image
    /// carries its annotations.
    owners: std.ArrayList(u32) = .empty,
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
        for (self.history.items) |c| switch (c) {
            .remove => |r| self.release(gpa, r.ann),
            .image_remove => |r| r.placed.release(gpa),
            else => {},
        };
        for (self.undone.items) |u| switch (u) {
            .add => |a| self.release(gpa, a.ann),
            .image_add => |p| p.release(gpa),
            else => {},
        };
        for (self.edit_texts.items) |t| gpa.free(t);
        self.edit_texts.deinit(gpa);
        self.scene.deinit(gpa);
        self.items.deinit(gpa);
        self.owners.deinit(gpa);
        self.crops.deinit(gpa);
        self.history.deinit(gpa);
        self.undone.deinit(gpa);
    }

    /// The last crop, if any.
    pub fn crop(self: *const Document) ?Crop {
        const n = self.crops.items.len;
        return if (n == 0) null else self.crops.items[n - 1];
    }

    /// Place the first image at (0, 0), without an undo step. `canvas` null:
    /// a size-only image (pure tests). The scene does not own the canvas.
    pub fn seed(self: *Document, gpa: std.mem.Allocator, w: u32, h: u32, canvas: ?*const Canvas) !void {
        try self.scene.images.append(gpa, .{ .id = self.scene.newId(), .w = @intCast(w), .h = @intCast(h), .x = 0, .y = 0, .canvas = canvas });
    }

    /// The bounding box of the placed images (scene px): the image of a
    /// one-image document.
    pub fn base(self: *const Document) Rect {
        return self.scene.bounds();
    }

    /// The kept rectangle before annotations grow it: the last crop, or all
    /// of the placed images.
    pub fn kept(self: *const Document) Rect {
        return if (self.crop()) |c| c.rect else self.base();
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
        for (self.undone.items) |u| switch (u) {
            .add => |a| self.release(gpa, a.ann),
            .image_add => |p| p.release(gpa),
            else => {},
        };
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
        try self.owners.ensureUnusedCapacity(gpa, 1);
        try self.items.append(gpa, ann);
        self.owners.appendAssumeCapacity(if (self.scene.nearest(ann.anchor())) |i| self.scene.images.items[i].id else no_image);
        self.history.appendAssumeCapacity(.add);
        self.clearRedo(gpa);
        self.revision += 1;
    }

    /// Delete annotation `i` as one undo step; the history keeps it (and its
    /// text) for the undo. Later annotations move down one place, and so do
    /// the crops that counted it. Clears the redo stack.
    pub fn remove(self: *Document, gpa: std.mem.Allocator, i: usize) !void {
        try self.history.ensureUnusedCapacity(gpa, 1);
        self.removeRaw(i);
        self.clearRedo(gpa);
    }

    /// Remove annotation `i` into the history; the room is made.
    fn removeRaw(self: *Document, i: usize) void {
        const a = self.items.orderedRemove(i);
        const o = self.owners.orderedRemove(i);
        self.history.appendAssumeCapacity(.{ .remove = .{ .index = i, .ann = a, .owner = o, .shifted = self.shiftCrops(i, -1) } });
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

    /// Place `canvas` (null: size only) at (`x`, `y`) on top of the others,
    /// as one undo step; returns its id. `owned`: the scene frees the canvas.
    pub fn addImage(self: *Document, gpa: std.mem.Allocator, w: u32, h: u32, x: i32, y: i32, canvas: ?*const Canvas, owned: bool) !u32 {
        try self.history.ensureUnusedCapacity(gpa, 1);
        try self.scene.images.ensureUnusedCapacity(gpa, 1);
        const id = self.scene.newId();
        self.scene.images.appendAssumeCapacity(.{ .id = id, .w = @intCast(w), .h = @intCast(h), .x = x, .y = y, .canvas = canvas, .owned = owned });
        self.history.appendAssumeCapacity(.image_add);
        self.clearRedo(gpa);
        self.touchScene();
        return id;
    }

    /// Move the image `id` to (`x`, `y`) with its annotations, as one undo
    /// step. Nothing if it is there already. Returns whether it moved.
    pub fn moveImage(self: *Document, gpa: std.mem.Allocator, id: u32, x: i32, y: i32) !bool {
        const i = self.scene.indexOf(id).?;
        const p = self.scene.images.items[i];
        if (p.x == x and p.y == y) return false;
        try self.history.ensureUnusedCapacity(gpa, 1);
        const m = ImageMove{ .id = id, .dx = x - p.x, .dy = y - p.y };
        self.applyImageMove(m, 1);
        self.history.appendAssumeCapacity(.{ .image_move = m });
        self.clearRedo(gpa);
        return true;
    }

    /// Remove the image `id` and the annotations drawn on it, as one undo
    /// step. The history keeps them.
    pub fn removeImage(self: *Document, gpa: std.mem.Allocator, id: u32) !void {
        const index = self.scene.indexOf(id).?;
        var n: usize = 0;
        for (self.owners.items) |o| n += @intFromBool(o == id);
        try self.history.ensureUnusedCapacity(gpa, n + 1);
        var i = self.items.items.len;
        while (i > 0) {
            i -= 1;
            if (self.owners.items[i] == id) self.removeRaw(i);
        }
        const p = self.scene.images.orderedRemove(index);
        self.history.appendAssumeCapacity(.{ .image_remove = .{ .placed = p, .index = index, .n = n } });
        self.clearRedo(gpa);
        self.touchScene();
    }

    /// Shift the image of `m` and its annotations by `m` times `sign`.
    fn applyImageMove(self: *Document, m: ImageMove, sign: i32) void {
        const d = Vec2.init(@floatFromInt(m.dx * sign), @floatFromInt(m.dy * sign));
        const p = &self.scene.images.items[self.scene.indexOf(m.id).?];
        p.x += m.dx * sign;
        p.y += m.dy * sign;
        for (self.items.items, self.owners.items) |*a, o| if (o == m.id) {
            a.* = a.shifted(d);
        };
        self.touchScene();
    }

    /// A change of the scene: the compositor repaints everything.
    fn touchScene(self: *Document) void {
        self.revision += 1;
        self.removals += 1;
    }

    /// Steps that undo takes together: the top one, its chained moves, or
    /// an image removal with the removals of its annotations.
    fn undoLen(self: *const Document) usize {
        const top = self.history.items[self.history.items.len - 1];
        if (top == .image_remove) return 1 + top.image_remove.n;
        var n: usize = 1;
        while (isChained(self.history.items[self.history.items.len - n])) n += 1;
        return n;
    }

    /// Undo one annotation removal (the room is made).
    fn unremove(self: *Document, r: Removed) void {
        self.items.insertAssumeCapacity(r.index, r.ann);
        self.owners.insertAssumeCapacity(r.index, r.owner);
        for (self.crops.items[self.crops.items.len - r.shifted ..]) |*c| c.first += 1;
        self.undone.appendAssumeCapacity(.{ .remove = .{ .index = r.index, .shifted = r.shifted } });
        self.removals += 1;
    }

    /// Undo the last step: its chained moves (last first), then the step.
    pub fn undo(self: *Document, gpa: std.mem.Allocator) !bool {
        if (self.history.items.len == 0) return false;
        // Room for the whole step first: it never stops half undone.
        const n = self.undoLen();
        try self.undone.ensureUnusedCapacity(gpa, n);
        try self.items.ensureUnusedCapacity(gpa, n);
        try self.owners.ensureUnusedCapacity(gpa, n);
        try self.scene.images.ensureUnusedCapacity(gpa, 1);
        for (0..n) |_| switch (self.history.pop().?) {
            .remove => |r| self.unremove(r),
            .add => {
                self.undone.appendAssumeCapacity(.{ .add = .{ .ann = self.items.pop().?, .owner = self.owners.pop().? } });
                self.removals += 1;
            },
            .crop => self.undone.appendAssumeCapacity(.{ .crop = self.crops.pop().? }),
            .move => |m| self.undone.appendAssumeCapacity(.{ .move = self.swapMove(m) }),
            .image_add => {
                self.undone.appendAssumeCapacity(.{ .image_add = self.scene.images.pop().? });
                self.touchScene();
            },
            .image_move => |m| {
                self.applyImageMove(m, -1);
                self.undone.appendAssumeCapacity(.{ .image_move = m });
            },
            .image_remove => |r| {
                self.scene.images.insertAssumeCapacity(r.index, r.placed);
                self.touchScene();
                // Its annotations come back, then the marker goes last on
                // the redo stack: a redo meets it first.
                for (0..r.n) |_| self.unremove(self.history.pop().?.remove);
                self.undone.appendAssumeCapacity(.{ .image_remove = .{ .index = r.index, .n = r.n } });
                return self.finishUndo();
            },
        };
        return self.finishUndo();
    }

    fn finishUndo(self: *Document) bool {
        self.revision += 1;
        return true;
    }

    /// Redo one annotation removal (the room is made).
    fn reremove(self: *Document, r: anytype) void {
        const a = self.items.orderedRemove(r.index);
        const o = self.owners.orderedRemove(r.index);
        for (self.crops.items[self.crops.items.len - r.shifted ..]) |*c| c.first -= 1;
        self.removals += 1;
        self.history.appendAssumeCapacity(.{ .remove = .{ .index = r.index, .ann = a, .owner = o, .shifted = r.shifted } });
    }

    /// Redo the last undone step, then its chained moves (first first).
    pub fn redo(self: *Document, gpa: std.mem.Allocator) !bool {
        const len = self.undone.items.len;
        if (len == 0) return false;
        var n: usize = 1;
        const top = self.undone.items[len - 1];
        if (top == .image_remove) {
            n += top.image_remove.n;
        } else while (n < len and isChained(self.undone.items[len - 1 - n])) n += 1;
        try self.items.ensureUnusedCapacity(gpa, 1);
        try self.owners.ensureUnusedCapacity(gpa, 1);
        try self.crops.ensureUnusedCapacity(gpa, 1);
        try self.scene.images.ensureUnusedCapacity(gpa, 1);
        try self.history.ensureUnusedCapacity(gpa, n);
        for (0..n) |_| switch (self.undone.pop().?) {
            .add => |a| {
                self.items.appendAssumeCapacity(a.ann);
                self.owners.appendAssumeCapacity(a.owner);
                self.history.appendAssumeCapacity(.add);
            },
            .crop => |c| {
                self.crops.appendAssumeCapacity(c);
                self.history.appendAssumeCapacity(.crop);
            },
            .move => |m| self.history.appendAssumeCapacity(.{ .move = self.swapMove(m) }),
            .remove => |r| self.reremove(r),
            .image_add => |p| {
                self.scene.images.appendAssumeCapacity(p);
                self.history.appendAssumeCapacity(.image_add);
                self.touchScene();
            },
            .image_move => |m| {
                self.applyImageMove(m, 1);
                self.history.appendAssumeCapacity(.{ .image_move = m });
            },
            .image_remove => |r| {
                // The annotations go first (they are the next `r.n` on the
                // stack), then the image.
                for (0..r.n) |_| self.reremove(self.undone.pop().?.remove);
                const p = self.scene.images.orderedRemove(r.index);
                self.history.appendAssumeCapacity(.{ .image_remove = .{ .placed = p, .index = r.index, .n = r.n } });
                self.touchScene();
                break;
            },
        };
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
    try doc.seed(gpa, 100, 80, null);
    try doc.add(gpa, num);
    try doc.setCrop(gpa, r);
    try doc.add(gpa, num);
    try std.testing.expectEqual(Rect.fromSize(0, 0, 100, 80), blk: {
        var d = Document{};
        defer d.deinit(gpa);
        try d.seed(gpa, 100, 80, null);
        break :blk d.kept();
    });
    try std.testing.expectEqual(r, doc.kept());
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

test "images: add, move with their annotations, remove; undo and redo each" {
    const gpa = std.testing.allocator;
    var doc = Document{};
    defer doc.deinit(gpa);
    try doc.seed(gpa, 100, 80, null);
    const b = try doc.addImage(gpa, 50, 50, 164, 0, null, false);
    const num = struct {
        fn at(x: f32, y: f32) Annotation {
            return .{ .number = .{ .center = .{ .x = x, .y = y }, .value = 1, .size = 10, .color = .{ .r = 0, .g = 0, .b = 0 } } };
        }
    }.at;
    try doc.add(gpa, num(10, 10)); // on image 0
    try doc.add(gpa, num(180, 20)); // on image b
    try std.testing.expectEqual(@as(u32, 0), doc.owners.items[0]);
    try std.testing.expectEqual(b, doc.owners.items[1]);
    try std.testing.expectEqual(Rect.fromSize(0, 0, 214, 80), doc.base());

    // Move b: its annotation follows, the other stays.
    try std.testing.expect(try doc.moveImage(gpa, b, 0, 144));
    try std.testing.expect(!try doc.moveImage(gpa, b, 0, 144));
    try std.testing.expectEqual(Vec2.init(10, 10), doc.items.items[0].number.center);
    try std.testing.expectEqual(Vec2.init(16, 164), doc.items.items[1].number.center);
    try std.testing.expectEqual(Rect.fromSize(0, 0, 100, 194), doc.base());
    try std.testing.expect(try doc.undo(gpa));
    try std.testing.expectEqual(Vec2.init(180, 20), doc.items.items[1].number.center);
    try std.testing.expect(try doc.redo(gpa));
    try std.testing.expectEqual(Vec2.init(16, 164), doc.items.items[1].number.center);

    // Remove b with its annotation; undo brings both back, redo removes again.
    try doc.removeImage(gpa, b);
    try std.testing.expectEqual(@as(usize, 1), doc.scene.count());
    try std.testing.expectEqual(@as(usize, 1), doc.items.items.len);
    try std.testing.expectEqual(Rect.fromSize(0, 0, 100, 80), doc.base());
    try std.testing.expect(try doc.undo(gpa));
    try std.testing.expectEqual(@as(usize, 2), doc.scene.count());
    try std.testing.expectEqual(@as(usize, 2), doc.items.items.len);
    try std.testing.expectEqual(b, doc.owners.items[1]);
    try std.testing.expectEqual(Rect.fromSize(0, 0, 100, 194), doc.base());
    try std.testing.expect(try doc.redo(gpa));
    try std.testing.expectEqual(@as(usize, 1), doc.scene.count());
    try std.testing.expectEqual(@as(usize, 1), doc.items.items.len);

    // Everything back to the start, and forward again.
    while (try doc.undo(gpa)) {}
    try std.testing.expectEqual(@as(usize, 1), doc.scene.count());
    try std.testing.expectEqual(@as(usize, 0), doc.items.items.len);
    while (try doc.redo(gpa)) {}
    try std.testing.expectEqual(@as(usize, 1), doc.scene.count());
    try std.testing.expectEqual(@as(usize, 1), doc.items.items.len);
}
