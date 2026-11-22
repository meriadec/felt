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
| `view.zig` | Fit the image (or its crop) to the screen, never above 1:1, centered |
| `font.zig`, `text.zig` | stb_truetype glyph cache; text layout, coverage masks |
| `image_io.zig` | Decode and encode image files: `png.zig` first, stb_image for the rest |
| `png.zig` | Fast PNG codec for 8-bit RGB/RGBA on libdeflate |
| `annotation.zig` | Annotation union; image coordinates and image-pixel sizes |
| `document.zig` | Annotation list, crop rectangle, undo/redo of both, number counter |
| `style.zig` | Size levels (stroke, font), UI scale from the screen height |
| `input.zig` | Backend-neutral events and key chords |
| `keymap.zig` | Single source of truth for keys: dispatch, hint bar, docs/keymap.md |
| `editor.zig` | Input state machine: tools, drag, typing, commands; no drawing, no IO |
| `draw.zig` | Draw one annotation through an `Xform`; its damage bounds |
| `chrome.zig` | Hint bar, status pill, toast (layout as draw ops) |
| `compositor.zig` | Layer cache + damage tracking; produces screen frames |
| `exporter.zig` | Full-resolution export of the kept part (crop origin shift) |

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
- Annotations live in image pixels of the full original image. The editor
  converts screen input with `view.toImage` and screen sizes with
  `/ view.xf.scale`. Draw code computes geometry in image units, then applies
  the `Xform`. So the export (a shift by the crop origin) matches the screen.
- A crop never touches the image or the annotations: `Document.crop` is the
  kept rectangle; the view fits it, the export copies it. Undo just restores
  the previous rectangle. Annotations are clipped to the kept part on screen
  (`view.dst`) and in the export.
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

`base` (background + downscaled kept part of the image, built lazily for
undo), `scene` (base + committed annotations, appended in place, rebuilt after
undo, resize or crop), `frame` (scene + crop dimming + chrome + preview). A crop
drag damages only the bands between the old and the new crop rectangle. In X11 the frame is the shared-memory image, so a present is
only `XShmPutImage` of the damaged rects.

## Add a tool

1. `keymap.zig`: add to `Tool` and `tools` (key, name, mouse help).
2. `annotation.zig`: add a variant with image-space fields.
3. `editor.zig`: build it in `shapeFromDrag` or `onDown`.
4. `draw.zig`: draw it and give its `bounds`.
5. `tests/scripts/<tool>.txt`, `zig build shot -Dscript=<tool>`, look at the PNG,
   `zig build test -Dupdate-goldens=true`, `zig build docs`.
