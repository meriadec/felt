# annotate

Fast full-screen screenshot annotation for X11. Opens an image, you draw
arrows, text labels, boxes, numbered bubbles, callouts, highlights and
pixelation with one-letter tools, crop it, then save (Ctrl+S) or copy (Ctrl+C). Built to replace
`ksnip -e` in an i3 setup.

## Install

Needs Zig 0.15.2 (pinned in `mise.toml`), X11 headers (`libx11-dev`,
`libxext-dev`) and, for Ctrl+C, `xclip`.

```sh
mise exec -- zig build -Doptimize=ReleaseFast --prefix ~/.local install
# -> ~/.local/bin/annotate
```

## Use

```sh
annotate shot.png            # Ctrl+S overwrites shot.png
annotate -e shot.png         # same (ksnip-compatible flag)
annotate -o out.png shot.png # Ctrl+S writes out.png
```

The image fits the screen (never upscaled). A small icon dock at the bottom
center shows the tools (each with its key letter), the colors and the size;
click it or use the keys. A small bar at the top center has Undo and Redo
buttons. Tab and Shift+Tab cycle the tools. Space hides or shows both
panels; `?` or F1 shows every shortcut. Crop (`x`) keeps the part you
drag; undo restores it. Move (`m`) drags any annotation; it lights up
under the pointer. A callout box moves alone (the tip stays) or its tip
alone; an arrow end moves alone. Draw past the image edge and the canvas grows white
to hold the shape (the saved PNG too); undo shrinks it back. Around a
full-screen image, zoom out with `-` or Ctrl+wheel to get room; `0` fits,
middle drag or the arrow keys pan. The UI and the default sizes scale with the screen
height (2x at 4K). Esc or q quits (q is a letter while you type); with unsaved changes, press it twice. Ctrl+C
counts as saved, because xclip keeps the image in the clipboard after annotate
exits.

Full key map: [docs/keymap.md](docs/keymap.md).

## i3

Replace the ksnip lines with:

```
bindsym $mod+e exec "annotate -e $(/bin/ls -1td /home/mpillet/* | head -n 1)"
for_window [class="annotate"] floating enable, fullscreen enable
```

The first line opens the newest file in your home directory (`ls -1td` with a
glob gives full paths, so the working directory of i3 does not matter).
annotate asks for full screen itself; the `for_window` line keeps i3 from
tiling it for a moment. To shoot and annotate in one key:

```
bindsym Print exec "maim -s /tmp/shot.png && annotate -o $HOME/shot-$(date +%s).png /tmp/shot.png"
```

## Develop

See [AGENTS.md](AGENTS.md).
