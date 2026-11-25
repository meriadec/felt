<p align="center">
  <img src="assets/felt-mark.svg" alt="Felt logo" width="128">
</p>

<h1 align="center">Felt</h1>

<p align="center">
  Fast full-screen screenshot annotation for X11.<br>
  Capture, mark, save. All with one-letter keys.
</p>

<p align="center">
  <img src="assets/screenshot.png" alt="Felt annotating a web page with callouts and arrows" width="720">
</p>

Press a hotkey, drag a rectangle around what you want to show, and you land
in an editor with the capture already open. Draw callouts, arrows, boxes and
numbered bubbles with one-letter keys, hide secrets with pixelate, then save
(Ctrl+S) or copy (Ctrl+C) the PNG. The first frame shows in about 0.1 s, so it
fits on a screenshot key.

## Features

| Key | Tool |
| --- | --- |
| `c` (or `a`) | Callout: a text box with a pointer (straight or stairs); with no text, an arrow |
| `r` | Box |
| `t` | Text: plain letters, or on a box (`t` again) |
| `n` | Numbered bubble |
| `p` | Pixelate (hide secrets) |
| `m` | Move / select any annotation (Delete removes the selected one) |
| `x` | Crop |

- **Built-in capture.** Pick a region or a window; the screen is frozen while you choose.
- **Undo and redo** for every change, including crops.
- **Room to draw.** The canvas grows when you draw past the image edge, and a
  slider adds padding around the image.
- **Zoom and pan**, with a UI that scales to your screen (2x at 4K).
- **No GPU needed.** A software renderer in pure Zig, with a thin X11 backend.
- **Tested by replay.** A headless mode replays scripts, so every tool has a golden test.

## Install

Needs Zig 0.15.2 (pinned in `mise.toml`), X11 headers (`libx11-dev`,
`libxext-dev`) and, for Ctrl+C, `xclip`.

```sh
mise exec -- zig build -Doptimize=ReleaseFast --prefix ~/.local install
# -> ~/.local/bin/felt
# -> ~/.local/share/applications/felt.desktop and the icons
```

## Quick start

```sh
felt                     # capture a region, then annotate it
felt shot.png            # annotate an existing image; Ctrl+S overwrites it
felt -o out.png shot.png # Ctrl+S writes out.png instead
```

Bind `felt` to a key and you have a screenshot tool (see [i3](#i3)).

## Capture

Run `felt` (or `felt --capture`). Felt grabs all monitors, then shows the
frozen picture slightly dimmed in a full-screen overlay.

- **Drag** a rectangle. It lights up with a size label (`812x430`), and the
  capture is taken when you release the button. No Enter needed.
- **Click** without dragging to take the window under the pointer, frame
  included. The window lights up as you move the mouse.
- **Tab** toggles a delay (`delay 1s: on` shows at the top). After you select,
  the overlay goes away, felt waits, then grabs the region from the live
  screen. Use it to open a menu or place the pointer first. `--delay 2` sets
  the delay to 2 s.
- **Esc** or a right click cancels: no editor, exit status 1.

The editor then opens on the capture in its normal window. Ctrl+S writes
`$HOME/<unix time>.png` (`-o` picks another path). Ctrl+C copies.

## Editing

The image fits the screen and is never upscaled. A dock at the bottom center
shows the tools (each with its key), the colors and the size. Click it or use
the keys. `h` hides the panels, hold `Space` for the hand (drag with the left button to pan), `?` or F1 shows every shortcut. The full
list is in [docs/keymap.md](docs/keymap.md).

- **Callouts and arrows.** The callout tool is active at startup: press where the
  box goes, drag to the point of interest, then type. Commit with no text
  (Enter, Esc or a click elsewhere) and the callout becomes a plain arrow. The
  pointer is straight at startup; press `c` (or `a`) again, or use the switch
  above the dock, for stairs.
- **Tools.** Tab and Shift+Tab cycle them.
- **Move / select** (`m`) drags any annotation, which lights up under the
  pointer. A callout box moves alone (the tip stays), or its tip moves alone. An
  arrow end moves alone. The last annotation you pressed stays selected
  (outlined): Delete or Backspace deletes it (undo brings it back); Esc, a click
  on empty space or another tool clears the selection.
- **Crop** (`x`) keeps the part you drag. Undo restores it.
- **Undo and redo** are in the top bar and on the usual keys.
- **Canvas.** Draw past the image edge and the canvas grows, in the window and
  in the saved PNG. Undo shrinks it back. `b`, or the half-filled circle in the
  top bar, switches the grown area between light and dark grey.
- **Padding.** The slider next to it (or `,` and `.`, or the wheel over it) adds
  a margin of 0, 64, 96, 128 or 192 px around the image. You can draw in it.
- **View.** Zoom out with `-` or Ctrl+wheel to get room. `0` fits the image.
  Middle drag or the arrow keys pan.
- **Quit** with Esc or `q`. With unsaved changes, press it twice. Ctrl+C counts
  as saved, because xclip keeps the image in the clipboard after felt exits.

The canvas background and the padding are settings, not undo steps.

## Settings

Felt keeps the canvas background for the next sessions in
`$XDG_CONFIG_HOME/felt/config` (default `~/.config/felt/config`):

```
canvas_bg=dark
```

It writes the file when you switch the background. A missing
or broken file gives the defaults (`light`). The padding is not kept: every
session starts at 0. `--canvas-bg light|dark` overrides the file for one
run and does not change it. Headless runs (`--headless`, tests) never read or
write the file.

## i3

One line gives you a screenshot key:

```
bindsym Print exec felt --capture
```

Felt asks for full screen itself. To keep i3 from tiling the editor window for
a moment, add:

```
for_window [class="felt"] floating enable, fullscreen enable
```

To open the newest file in your home directory instead, use
`bindsym $mod+e exec "felt $(/bin/ls -1td $HOME/* | head -n 1)"`.

## Develop

See [AGENTS.md](AGENTS.md).
