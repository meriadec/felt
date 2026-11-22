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
| `stairs.zig` | Stairs arrow path: elbow route, round corners, its signed distance |
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
| `keymap.zig` | Single source of truth for keys: dispatch, dock order, help overlay, docs/keymap.md; a tool key pressed again (`ToolInfo.again`) |
| `editor.zig` | Input state machine: tools, drag, typing, commands; no drawing, no IO |
| `draw.zig` | Draw one annotation through an `Xform`; its damage bounds; a callout pointer as an arrow (`calloutPointer`) |
| `icons.zig` | Vector tool icons (SDF shapes, any scale) |
| `dock.zig` | Dock geometry and hit test, shared by chrome (draw) and editor (clicks); the arrow style switch above it (arrow and callout tools) |
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
  annotation draws only inside its own clip (`extent.itemClip`): a pure
  function of its current geometry, the kept rectangle when it was made, and
  the crops made after it. Adding an annotation never changes another's
  clip, so appending to the scene equals a repaint.
- Move (tool `m`): the editor changes the annotation in place while the
  drag runs (`Document.setLive`, no history), and on release records one
  `Document.Move` step with the geometry from before. Undo and redo swap the
  two geometries; the text is shared, never copied. A move changes only the
  moved annotation's clip and the canvas, both recomputed from geometry, so
  undo is exact. The compositor keeps a shallow copy of what it painted and
  repaints the old and new bounds of any annotation that differs, the bands
  the canvas gained or lost, and grows each repaint rect to hold any
  pixelate it touches (a pixelate averages the pixels under it).
- Arrow styles: each arrow and each callout stores its `style` (straight,
  stairs). The editor's `arrow_style` is the style of new arrows and new
  callout pointers: one setting for both. `a` with the arrow tool active,
  `c` with the callout tool active, or the switch above the dock (only
  with these two tools, over the active tool's slot) sets it, with a toast
  in the words of the tool ("Arrow: stairs", "Pointer: stairs"); a shape
  in progress follows. It stays for the session, across tool switches (it
  is not saved). A stairs arrow
  (stairs.zig) is an elbow connector: along the dominant axis to the
  midpoint, along the other axis, along the dominant axis into the head.
  Its two corners are quarter circles of `cornerRadius(width)`, clamped so
  the middle segment and the head keep room; a rise under the stroke width
  draws straight. Hit tests, bounds, clips and move repaints follow the
  real path (`draw.arrowShape`, `draw.cover`).
- Move and crops: an annotation made before a crop stays under that crop.
  Its clip stays cut by the crop, it never grows the canvas, and the pointer
  grabs it only where it shows. A move position that would hide its body
  (outside the crop or past the reach) is skipped: it stops at the last
  place where it shows. Annotations made after the last crop grow and
  shrink the canvas as they move.
- Callout pointer: an arrow (`draw.calloutPointer`) with the callout's
  stroke `width` (the arrow width of its size level), color and style,
  from `anchor` to `target`, drawn before the box, so the box covers its
  start. The box sits on the far side of `anchor` from the target along
  the dominant axis, so `anchor` is the middle of the box side that faces
  the target: a straight pointer leaves there, and a stairs pointer runs
  along that same axis first, so it leaves across the side. A target
  nearer `anchor` than one head length (`headLength(width)`) shows no
  pointer (it would be only a head stuck to the box); the tip handle
  still pulls it out. Hit tests, outlines, bounds, clips and move
  repaints take the box and the pointer (`CalloutShape`, `draw.cover`).
- Callout move: a press on the tip (handle radius 9 px at 1080p) moves the
  tip alone; anywhere else on the callout (box or pointer) moves the box
  alone, the tip stays on its target and the pointer re-routes. An arrow longer than four handle radii: a press on
  an end moves that end alone.
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
committed annotations; appended in place; repainted in place where an
annotation moved or the canvas grew or shrank; repainted in full after the
undo of an add or a crop, resize or zoom), `frame` (scene +
white canvas the shape in progress adds + crop dimming + move outline +
chrome + preview). A
move repaints the scene only in slabs along the old and the new place
(`draw.cover`), merged where that adds no pixel. A
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
