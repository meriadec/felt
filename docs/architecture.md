# Architecture

## Data flow

```
backend (x11.zig | headless.zig + script.zig)
   | core.input.Event
   v
app.zig  App.handle ──> editor.zig (state machine) ──> document.zig (annotations, undo)
   |                        | Command: save / copy / quit / save_settings
   |                        v
   |                    App runs IO: exporter + image_io.savePng | clipboard.zig (xclip)
   |                                 | config.zig (settings file, window mode only)
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
| `stairs.zig` | Stairs arrow path: elbow route (turn position, axis order), round corners, its signed distance |
| `route.zig` | Auto-routing of stairs paths: the elbow with the fewest crossings and the least crowding (`best`), re-routes around a change (`settle`) |
| `raster.zig` | Tile-culled anti-aliased fill of any SDF shape |
| `resample.zig` | Area-average downscale (screen copy of the image) |
| `view.zig` | Image-to-screen transform: fit the canvas to the screen (never above 1:1, centered) |
| `font.zig`, `text.zig` | stb_truetype glyph cache; text layout, coverage masks |
| `image_io.zig` | Decode and encode image files: `png.zig` first, stb_image for the rest |
| `png.zig` | Fast PNG codec for 8-bit RGB/RGBA on libdeflate |
| `annotation.zig` | Annotation union; image coordinates and image-pixel sizes |
| `document.zig` | Annotation list, crop stack, undo/redo of both, number counter |
| `extent.zig` | Canvas of the document: the kept rectangle plus the canvas padding (`Ctx.pad`), grown by annotations; each annotation's clip |
| `style.zig` | Size levels (stroke, font), UI scale from the screen height |
| `settings.zig` | User settings, not document state: the canvas background (light, dark grey), the canvas padding and its step list (`padding_steps`); the config file text (`parse`, `write`) |
| `input.zig` | Backend-neutral events and key chords |
| `keymap.zig` | Single source of truth for keys: dispatch, dock order, help overlay, docs/keymap.md; a tool key pressed again (`ToolInfo.again`) |
| `editor.zig` | Input state machine: tools, drag, typing, commands; no drawing, no IO |
| `draw.zig` | Draw one annotation through an `Xform`; its damage bounds; a callout pointer as an arrow (`calloutPointer`) |
| `icons.zig` | Vector tool icons (SDF shapes, any scale) |
| `dock.zig` | Dock geometry and hit test, shared by chrome (draw) and editor (clicks); the arrow style switch above it (arrow and callout tools) |
| `topbar.zig` | Top bar geometry and hit test: Undo, Redo, a separator, the canvas background switch, the canvas padding slider (notch geometry, nearest step); save and copy stay on keys |
| `chrome.zig` | Flat Nord chrome: icon dock, top bar, help overlay, toast pill, hover states (layout as draw ops); a signature per panel (`State.panelSig`) for damage |
| `compositor.zig` | Layer cache + damage tracking; produces screen frames |
| `picker.zig` | Capture picker state machine: hover a window, drag a rectangle, confirm on release, cancel, delay toggle; rect normalization; `crop` of the frozen screen |
| `picker_draw.zig` | Picker drawing: frozen screen dimmed, bright rectangle with border, size pill, delay pill; `Scene.render` repaints only the difference |
| `exporter.zig` | Full-resolution export of the canvas (shift by the canvas origin, the canvas background outside the image) |

`src/` (the `felt` executable module):

| File | Role |
|---|---|
| `main.zig` | Entry point, dispatch by mode (capture: picker first, then the editor on the result) |
| `cli.zig` | Argument parsing, `--help` text; no image means capture mode; the capture save path |
| `app.zig` | One open image: font + document + editor + compositor; runs save/copy and writes the settings |
| `config.zig` | Settings file `$XDG_CONFIG_HOME/felt/config`: path, load (bad file: defaults), atomic save, the `--canvas-bg` flag on top |
| `clipboard.zig` | Pipe a PNG to xclip |
| `backend/xlib.zig` | The one Xlib C import, the MIT-SHM `Surface`, key translation: shared by both X11 backends |
| `backend/x11.zig` | Editor window: Xlib window, event translation, MIT-SHM present |
| `backend/x11_capture.zig` | Capture mode: root grab (XShmGetImage), full-screen override-redirect overlay, window list snapshot, picker events, live regrab after a delay |
| `backend/headless.zig` | Replay a script, write frame/export PNGs |
| `backend/script.zig` | Event script parser (format in docs/testing.md) |
| `bench.zig` | `--bench` timings |
| `golden.zig` | Golden replay tests and PNG diff |

## Capture mode

`felt` with no image (or `--capture`) runs `x11_capture.run`, then the
editor on the canvas it returns (`x11.Options.image`, owned by the App).
Order matters: (1) grab the root window into a shared-memory `Surface`
(the frozen screen, no copy through the socket), (2) snapshot the viewable
top-level windows (`XQueryTree`, frames included, topmost first) before any
window of ours exists, (3) map the override-redirect overlay and grab the
pointer and keyboard, (4) feed events to `core.picker.Picker` and present
`picker_draw.Scene` damage, (5) on release, either crop the frozen screen
(delay 0) or destroy the overlay, wait the delay (at least 100 ms, so the
screen repaints) and `XGetImage` the region live. Cancelled: `null`, exit 1.
The picker is pure; headless scripts with `capture` replay it on an image
that stands for the screen (tests/scripts/capture_*.txt). The X11 part is
checked by `zig build smoke-capture`. Frames cost: first frame 4 ms and a
drag frame 1.1 ms avg (p95 3.0) at 4K (docs/perf.md).

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
  px). Canvas outside the image takes the canvas background (light or
  dark grey, see Settings), on screen and in the export. Each
  annotation draws only inside its own clip (`extent.itemClip`): a pure
  function of its current geometry, the kept rectangle when it was made, and
  the crops made after it. Adding an annotation never changes another's
  clip, so appending to the scene equals a repaint.
- Move (tool `m`): the editor changes the annotation in place while the
  drag runs (`Document.setLive`, no history), and on release records one
  `Document.Move` step with the geometry from before. Undo and redo swap the
  two geometries; the text is shared, never copied. A move changes only the
  moved annotation's clip and the canvas, both recomputed from geometry, so
  undo is exact. A step may carry chained moves (`Move.chained`): the
  re-routes of other stairs paths that the step caused (see Auto-routing).
  Undo and redo take a step with all its chained moves and swap the
  stored geometry: nothing is routed again, so they are exact. The
  compositor keeps a shallow copy of what it painted and
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
  is not saved). At startup: the callout tool with stairs
  (`editor.default_tool`, `default_arrow_style`). Tests, golden scripts
  and the bench set their start tool and style, so they keep their meaning
  if the defaults change. A stairs arrow
  (stairs.zig) is an elbow connector: along the dominant axis to the
  midpoint, along the other axis, along the dominant axis into the head.
  Its `elbow` (annotation.Elbow) can move the turn off the midpoint (`at`,
  a fraction of the first axis, so it scales with the arrow) and run
  along the minor axis first (`flip`, only where that axis has room for
  full corners and a full head; a callout pointer never flips). The head
  length follows the span, not the turn, and the turn is clamped so the
  head keeps its straight stretch. The path always stays in the box of
  its two ends, so an elbow never changes bounds, clips or the canvas.
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
- Auto-routing (route.zig): a stairs path that is not pinned picks its
  elbow among fixed candidates (the midpoint first, then 49 turn
  positions across the room with full corners, then the same flipped; a
  strictly lower cost wins, so the choice is deterministic). Cost: 1000
  per crossing with another path (stairs segments, straight arrows,
  callout pointers); 3 per px run along one (within 15 degrees) closer
  than `nearGap` = 1.5 x the two stroke widths, weighted by closeness;
  100 per near touch (an end or a corner that close to another path); 2
  per px through a label box (text, callout box, number; not one the path
  starts on or points at; grown by a stroke width); 0.2 per px the turn
  moves off the midpoint; 200 for a flip. Paths from or to one point share
  their stretch freely. Rect outlines and pixelates are not obstacles (an
  arrow often points into a rect). With nothing in the box of its ends, a
  path keeps the default elbow: the look of the stairs before routing.
  Who routes: the path being drawn (preview and commit) or moved, each
  frame, against all others. On a commit (an add, the end of a move) the
  auto paths whose end box touches the old or new body bounds of the
  change re-route (`route.settle`): in creation order, two passes, the
  changed one included; they go in the same undo step as chained moves.
  Paths do not re-route on undo, redo or a crop. Straight arrows never
  change. The compositor repaints a re-routed path like a moved one (old
  and new cover).
- Bend pin (move tool): a stairs path whose middle segment is longer than
  three handle radii shows a handle in its middle (the outline's third
  dot). A press there drags the turn along the first axis (inside the
  room for full corners) and pins the elbow (`Elbow.pinned`: no routing,
  it stays as set when its ends move, as a fraction). Within a handle
  radius of the midpoint it snaps to the default and is auto again; on
  release a toast says "Bend pinned" or "Bend: auto". The pin is part of
  the annotation, so undo restores it.
- Callout move: a press on the tip (handle radius 9 px at 1080p) moves the
  tip alone; anywhere else on the callout (box or pointer, but the bend
  handle) moves the box
  alone, the tip stays on its target and the pointer re-routes. An arrow longer than four handle radii: a press on
  an end moves that end alone.
  The canvas grows at most `extent.limit` past the kept rectangle (2048 to
  4096 px a side, a memory bound); the editor refuses a shape out of reach
  with a toast.
- A crop never touches the image or the annotations: `Document.crops` is a
  stack of kept rectangles, each with the number of annotations it clips.
  A crop may keep grown canvas. Undo pops it. The view refits when the kept
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
- The editor does no IO and never draws. Commands (save, copy, quit,
  save_settings) go to the App. Keys come only from `keymap.zig`.
- Settings vs. document (settings.zig): the document holds what the user
  drew (annotations, crops) and its undo history; `Editor.settings` holds
  how the canvas looks. Today one setting: the canvas background, light
  (nord4 #D8DEE9) or dark (nord3 #4C566A), the color of the canvas outside
  the image on screen and in the export. `b` or the top bar switch toggles
  it with a toast ("Canvas: dark"). It is not an undo step: it changes no
  annotation, no clip and no canvas size, so undo keeps walking the
  drawing, and it stays for the next sessions. But when the canvas holds
  some outside the image, the export changes color: the switch counts as
  an unsaved change (`Editor.dirty`, against `saved_bg`) until a save or a
  switch back. The editor returns `Command.save_settings`; the App writes the file
  (config.zig) only if it has a path: only the window mode has one.
  Startup: file, then `--canvas-bg` on top; headless runs, the bench and
  tests start from the defaults plus the flag and never read or write the
  file. Both colors stay apart from the screen background (nord0) and the
  panels (nord1), so the canvas edge and the dock stay visible; every
  palette color reads on both (the dark palette color on dark grey and
  white on light grey are the weakest, kept visible by their shadow).
- Canvas padding (settings `padding`, one of `settings.padding_steps`: 0, 64,
  96, 128, 192 image px, all four sides; the slider in the top bar, `,` `.`,
  the wheel over the slider): an empty margin of canvas background around
  the kept rectangle, on screen and in the export. It enters the core as
  `draw.Ctx.pad` (the editor and the App fill it from the settings), and
  `extent` counts the kept rectangle as `pad` px bigger on every side: for
  the canvas, each annotation's clip and the reach limit. So a shape inside
  the padding shows and never grows the canvas, and a shape past it grows
  the canvas as before, to its bounds plus `extent.pad`. A crop keeps its
  rectangle; the padding goes around it (an annotation made before the crop
  stays cut by the crop rectangle, so the padding of the crop shows only
  what came after). Like the canvas background it is not an undo step (no
  annotation changes), it is persisted, and an unsaved change counts as
  dirty (`Editor.saved_padding`) because the export differs. A step changes
  every clip and the canvas, so the editor refits the view and the
  compositor repaints the whole scene (`scene_pad`; 5 to 8 ms at 1080p,
  docs/perf.md). Padding 0 is exactly the old behavior (goldens unchanged).
  Slider: a press sets the nearest step, a drag follows x, the release asks
  for `save_settings` (one file write per gesture); the wheel over it steps
  (no size change). No `--padding` flag: the file and the slider are enough.
- Text is UTF-8. Font sizes round to whole pixels (glyph cache key).

## Compositor layers

`scaled` (the kept part of the image at the view scale, only below 1:1;
rebuilt on zoom or crop), `scene` (background + canvas background + image +
committed annotations; appended in place; repainted in place where an
annotation moved or the canvas grew or shrank, and in the bands around the
image when the canvas background changes, repainted in full when the padding changes; repainted in full after the
undo of an add or a crop, resize or zoom), `frame` (scene +
canvas the shape in progress adds + crop dimming + move outline +
chrome + preview). Each chrome panel (dock, style switch, top bar, help,
toast) repaints only when its rect or its signature changes: a toast that
changes each frame does not repaint the dock. A
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
