# Key map

Generated from `src/core/keymap.zig` by `zig build docs`. Do not edit by hand.

## Tools

| Key | Tool | Mouse |
|---|---|---|
| `a` | arrow | Drag from the tail to the head. Style: straight, or stairs (an elbow with round corners); `a` again or the switch above the dock changes it for new arrows and callout pointers, for the rest of the session. A stairs path turns where it crosses and crowds no other path, if it can (the paths around it move aside too). |
| `t` | text | Click, type. Enter or Esc finishes, Shift+Enter adds a line, Backspace erases. |
| `r` | rect | Drag from corner to corner. |
| `n` | number | Click to drop the next number (1, 2, 3...). Undo takes the number back. |
| `c` | callout | Drag from the point of interest to where the box goes, release, type, Enter. The pointer is an arrow from the box to the point: straight or stairs, the arrow style (`c` again or the switch above the dock changes it, for arrows too). A plain click makes a label without a pointer. |
| `p` | pixelate | Drag over a secret to pixelate it. |
| `m` | move | Point at an annotation: it lights up. Drag it to move it. A callout: drag the box (the tip stays), or the tip alone. An arrow: drag an end to move only that end. A stairs path: drag the dot on its middle to pin where it turns; back to the middle, it routes itself again. Undo puts it back. |
| `x` | crop | Drag the part to keep. On release the image is cropped and the previous tool comes back. Undo restores. |

## Keys

| Key | Action |
|---|---|
| `a` again (arrow tool active) | arrow style: straight / stairs |
| `c` again (callout tool active) | pointer style: straight / stairs |
| `1` | color red |
| `2` | color orange |
| `3` | color yellow |
| `4` | color green |
| `5` | color blue |
| `6` | color purple |
| `7` | color white |
| `8` | color dark |
| `Tab` | next tool |
| `Shift+Tab` | previous tool |
| `[` | smaller |
| `]` | bigger |
| `Ctrl+Z` | undo |
| `Ctrl+Shift+Z` | redo |
| `Ctrl+Y` | redo |
| `Ctrl+S` | save |
| `Ctrl+C` | copy |
| `Esc` | quit |
| `q` | quit |
| `?` | help |
| `F1` | help |
| `Space` | hide / show the panels |
| `=` | zoom in |
| `+` | zoom in |
| `-` | zoom out (room to draw around) |
| `0` | fit the canvas to the screen |
| `←` | pan |
| `→` | pan |
| `↑` | pan |
| `↓` | pan |

## Mouse and context

| Input | Effect |
|---|---|
| Mouse wheel | Bigger / smaller stroke and text |
| Ctrl+wheel | Zoom in / out about the pointer |
| Middle drag | Pan the view |
| Drawing past the image | The canvas grows white to hold the shape; the export holds it all. Zoom out (`-`) for room around a full-screen image |
| Right click | Cancel the shape or text in progress |
| Click on the dock | Pick a tool or a color; the size slot steps the size, `?` opens this help. With the arrow or callout tool, the switch above the dock picks the arrow style (arrows and callout pointers) |
| Click on the top bar | Undo or redo (a dim button has nothing to do) |
| Esc or q while drawing | Cancel the shape in progress |
| Esc or q with unsaved changes | Shows a warning; a second Esc or q quits. Ctrl+C counts as saved: the clipboard keeps the image. |
| Esc, q or a click with help open | Close the help |
| Esc or q while typing | Esc finishes the text; q is a letter |
| Ctrl+Z while typing | Drop the text in progress |
| Tab while typing | Finish the text, then go to the next tool |
