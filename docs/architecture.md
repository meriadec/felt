# Architecture

## Data flow

```
backend (x11.zig | headless.zig + script.zig)
   | core.input.Event
   v
app.zig  App.handle ──> editor.zig (state machine) ──> document.zig (annotations, undo)
   |                        | Command: save / copy / quit
   |                        v
   |                    App runs IO: exporter + image_io.savePng | clipboard.zig (xclip)
   | App.render
   v
compositor.zig: scene (image + committed annotations) + preview + chrome
   | Damage (list of screen rects)
   v
backend presents the rects (XShmPutImage) or writes PNGs
```

## Module map

`src/core/` is the `core` module: pure, no window system, no process IO except
image files. Build: `coreModule` in build.zig.

| File | Role |
|---|---|
| `root.zig` | Module root, re-exports every core file |
| `color.zig` | `Pixel` (0xAARRGGBB), `Color`, palette (keys 1-8) |
| `geom.zig` | `Vec2`, `Bounds`, `Rect` (half-open ints), `Xform` (image -> screen) |
| `canvas.zig` | Pixel buffer and pixel ops (fill, copy, blend, multiply, mask, pixelate) |
| `sdf.zig` | Signed distance shapes (capsule, disc, triangle, rects, union, subtract) |
| `raster.zig` | Tile-culled anti-aliased fill of any SDF shape |
| `resample.zig` | Area-average downscale (screen copy of the image) |
| `view.zig` | Image-to-screen transform: fit the canvas to the screen (never above 1:1, centered) |
| `font.zig`, `text.zig` | stb_truetype glyph cache; text layout, coverage masks |
| `image_io.zig` | Decode and encode image files: `png.zig` first, stb_image for the rest |
| `png.zig` | Fast PNG codec for 8-bit RGB/RGBA on libdeflate |
| `annotation.zig` | Annotation union; image coordinates and image-pixel sizes |
| `document.zig` | Annotation list, crop stack, undo/redo of both, number counter |
| `extent.zig` | Canvas of the document: the kept rectangle grown by annotations; each annotation's clip |
| `style.zig` | Size levels (stroke, font), UI scale from the screen height |
| `input.zig` | Backend-neutral events and key chords |
| `keymap.zig` | Single source of truth for keys: dispatch, dock order, help overlay, docs/keymap.md |
| `editor.zig` | Input state machine: tools, drag, typing, commands; no drawing, no IO |
| `draw.zig` | Draw one annotation through an `Xform`; its damage bounds |
| `icons.zig` | Vector tool icons (SDF shapes, any scale) |
| `dock.zig` | Dock geometry and hit test, shared by chrome (draw) and editor (clicks) |
| `topbar.zig` | Top bar geometry and hit test: Undo and Redo buttons (only these: save and copy stay on keys) |
| `chrome.zig` | Flat Nord chrome: icon dock, top bar, help overlay, toast pill, hover states (layout as draw ops) |
| `compositor.zig` | Layer cache + damage tracking; produces screen frames |
| `exporter.zig` | Full-resolution export of the canvas (shift by the canvas origin, white outside the image) |

`src/` (the `annotate` executable module):

| File | Role |
|---|---|
| `main.zig` | Entry point, dispatch by mode |
| `cli.zig` | Argument parsing, `--help` text |
| `app.zig` | One open image: font + document + editor + compositor; runs save/copy |
| `clipboard.zig` | Pipe a PNG to xclip |
| `backend/x11.zig` | Xlib window, event translation, MIT-SHM present |
| `backend/headless.zig` | Replay a script, write frame/export PNGs |
| `backend/script.zig` | Event script parser (format in docs/testing.md) |
| `bench.zig` | `--bench` timings |
| `golden.zig` | Golden replay tests and PNG diff |

## Invariants

- The core never imports a backend or `src/`. The build enforces it: a module
  cannot import files outside its root directory.
- Annotations live in image pixels of the full original image, also outside
  it. The editor converts screen input with `view.toImage` and screen sizes
  with `/ view.xf.scale`. Draw code computes geometry in image units, then
  applies the `Xform`. So the export (a shift by the canvas origin) matches
  the screen.
- The canvas (`extent.canvas`) is the kept rectangle (the image, or the last
  crop) grown by the annotations made since: a side grows when the body of a
  shape crosses it, to the shape's full bounds plus `extent.pad` (16 image
  px). Canvas outside the image is white, on screen and in the export. Each
  annotation draws only inside its own clip (`extent.itemClip`), which never
  changes after it is made, so appending to the scene equals a repaint.
  The canvas grows at most `extent.limit` past the kept rectangle (2048 to
  4096 px a side, a memory bound); the editor refuses a shape out of reach
  with a toast.
- A crop never touches the image or the annotations: `Document.crops` is a
  stack of kept rectangles, each with the number of annotations it clips.
  A crop may keep white canvas. Undo pops it. The view refits when the kept
  rectangle changes; a canvas that grows or shrinks with annotations keeps
  the view (no jumps while drawing).
- The user zooms (Ctrl+wheel about the pointer, `-` `=` `0`) and pans (middle
  drag, arrow keys) freely; the view offset stays whole pixels, so a pan is
  an exact scroll. New annotation sizes follow the scale that fits the kept
  rectangle, not the zoom: zooming out to draw around a big image does not
  make strokes fat.
- Every pixel write takes a clip `Rect`. The compositor repaints only damaged
  rects; `draw.bounds` must cover everything `draw.annotation` can touch
  (shadows and anti-aliasing included). The golden test checks that an
  incremental frame equals a full repaint.
- Pixels are opaque 0xAARRGGBB, the X11 24/32-bit TrueColor layout on
  little-endian. Loaded images with alpha are flattened over white.
- The editor does no IO and never draws. Commands (save, copy, quit) go to the
  App. Keys come only from `keymap.zig`.
- Text is UTF-8. Font sizes round to whole pixels (glyph cache key).

## Compositor layers

`scaled` (the kept part of the image at the view scale, only below 1:1;
rebuilt on zoom or crop), `scene` (background + white canvas + image +
committed annotations; appended in place, the new white bands filled when the
canvas grows; repainted after undo, resize, zoom or crop), `frame` (scene +
white canvas the shape in progress adds + crop dimming + chrome + preview). A
crop drag damages only the bands between the old and the new crop rectangle;
a drag that grows the canvas damages only the bands it adds or removes. In X11 the frame is the shared-memory image, so a present is
only `XShmPutImage` of the damaged rects.

## Add a tool

1. `keymap.zig`: add to `Tool` and `tools` (key, name, mouse help). The dock,
   the Tab cycle and the help overlay follow `tools` order.
2. `icons.zig`: draw its icon (look at a `zig build shot` frame at 900x500).
3. `annotation.zig`: add a variant with image-space fields.
4. `editor.zig`: build it in `shapeFromDrag` or `onDown`.
5. `draw.zig`: draw it and give its `bounds`.
6. `tests/scripts/<tool>.txt`, `zig build shot -Dscript=<tool>`, look at the PNG,
   `zig build test -Dupdate-goldens=true`, `zig build docs`.
