//! App: wires the core together for one image (font, document, editor,
//! compositor) and runs editor commands that need IO: save and copy.
//! Backends own an App, feed it events, and present its frame.
const std = @import("std");
const core = @import("core");
const clipboard = @import("clipboard.zig");

const Canvas = core.canvas.Canvas;
const Editor = core.editor.Editor;

pub const Clipboard = union(enum) {
    /// Pipe the PNG to `xclip -selection clipboard`.
    xclip,
    /// Write the PNG to this path (headless tests).
    file: []const u8,
    none,
};

pub const Config = struct {
    /// Ctrl+S target; null disables save.
    output_path: ?[]const u8,
    clipboard: Clipboard = .xclip,
};

pub const Result = struct {
    redraw: bool = false,
    quit: bool = false,
};

pub const App = struct {
    gpa: std.mem.Allocator,
    font: core.font.Font,
    image: Canvas,
    doc: core.document.Document = .{},
    editor: Editor,
    comp: core.compositor.Compositor,
    cfg: Config,

    /// Takes ownership of `image`.
    pub fn create(gpa: std.mem.Allocator, image: Canvas, w: u32, h: u32, cfg: Config) !*App {
        const self = try gpa.create(App);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .font = try core.font.Font.init(gpa, core.font_ttf),
            .image = image,
            .editor = undefined,
            .comp = .{ .gpa = gpa },
            .cfg = cfg,
        };
        self.editor = Editor.init(gpa, &self.font, &self.doc, image.width, image.height, w, h);
        return self;
    }

    pub fn destroy(self: *App) void {
        self.comp.deinit();
        self.editor.deinit();
        self.doc.deinit(self.gpa);
        self.font.deinit();
        self.image.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn ctx(self: *App) core.draw.Ctx {
        return .{ .gpa = self.gpa, .font = &self.font };
    }

    pub fn handle(self: *App, ev: core.input.Event) !Result {
        const eff = try self.editor.handle(ev);
        var res = Result{ .redraw = eff.redraw };
        if (eff.command) |cmd| switch (cmd) {
            .quit => res.quit = true,
            .save => {
                self.save();
                res.redraw = true;
            },
            .copy => {
                self.copy();
                res.redraw = true;
            },
        };
        return res;
    }

    pub fn render(self: *App) !core.compositor.Damage {
        return self.comp.render(self.ctx(), &self.image, &self.doc, &self.editor);
    }

    pub fn frame(self: *const App) *const Canvas {
        return &self.comp.frame.?;
    }

    /// Full-resolution image with annotations. Caller owns it.
    pub fn exportImage(self: *App) !Canvas {
        return core.exporter.render(self.ctx(), &self.image, &self.doc);
    }

    fn save(self: *App) void {
        const path = self.cfg.output_path orelse {
            self.editor.setToast("Save is off (headless run without -o).", .{});
            return;
        };
        self.saveTo(path) catch |err| {
            self.editor.setToast("Save failed: {s} ({s})", .{ @errorName(err), path });
            return;
        };
        self.editor.markSaved();
        self.editor.setToast("Saved {s}", .{path});
    }

    fn saveTo(self: *App, path: []const u8) !void {
        var out = try self.exportImage();
        defer out.deinit(self.gpa);
        try core.image_io.savePng(self.gpa, &out, path);
    }

    fn copy(self: *App) void {
        self.copyImpl() catch |err| {
            switch (err) {
                error.FileNotFound => self.editor.setToast("Copy failed: xclip not found. Install xclip.", .{}),
                else => self.editor.setToast("Copy failed: {s}", .{@errorName(err)}),
            }
            return;
        };
        self.editor.markSaved(); // the clipboard keeps the image after quit
        self.editor.setToast("Copied to clipboard", .{});
    }

    fn copyImpl(self: *App) !void {
        if (self.cfg.clipboard == .none) return error.ClipboardDisabled;
        var out = try self.exportImage();
        defer out.deinit(self.gpa);
        const png = try core.image_io.encodePng(self.gpa, &out);
        defer self.gpa.free(png);
        switch (self.cfg.clipboard) {
            .xclip => try clipboard.copyPng(self.gpa, png),
            .file => |p| try std.fs.cwd().writeFile(.{ .sub_path = p, .data = png }),
            .none => unreachable,
        }
    }
};
