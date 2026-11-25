# Key map

Generated from `src/core/keymap.zig` by `zig build docs`. Do not edit by hand.

## Tools

| Key | Tool | Mouse |
|---|---|---|
| `c` | callout | The tool at startup. Press where the box goes, drag to the point of interest and release there, then type, Enter. The pointer is an arrow from the box to the point: stairs (at startup) or straight, the arrow style (`c` again or the switch above the dock changes it, for arrows too). A plain click makes a label without a pointer. |
| `a` | arrow | Press at the tail and release at the head (the point), like a callout. Style: stairs (an elbow with round corners, the start style) or straight; `a` again or the switch above the dock changes it for new arrows and callout pointers, for the rest of the session. A stairs path turns where it crosses and crowds no other path, if it can (the paths around it move aside too). |
| `t` | text | Click, type. Enter or Esc finishes, Shift+Enter adds a line, Backspace and Delete erase, the arrows (Ctrl: by word), Home and End move the caret, Shift with them selects, Ctrl+A selects all, and typing over a selection replaces it. Style: plain letters in the color (the start style) or on a filled box; `t` again or the switch above the dock changes it for new texts, for the rest of the session. |
| `r` | rect | Drag from corner to corner. |
| `n` | number | Click to drop the next number (1, 2, 3...). Undo takes the number back. |
| `p` | pixelate | Drag over a secret to pixelate it. |
| `m` | move/select | Point at an annotation: it lights up. Drag it to move it; it stays selected (outlined) after you let go, and Delete or Backspace deletes it (undo brings it back). A click on empty space, Esc, another tool, undo or redo clears the selection. A callout: drag the box (the tip stays), or the tip alone. An arrow: drag an end to move only that end. A stairs path: drag the dot on its middle to pin where it turns; back to the middle, it routes itself again. Undo puts it back. With two or more images on the canvas, drag an image (where no annotation is under the pointer) to move it to another place: the free slots next to the other images show dashed, the nearest one lit, and a ghost outline follows the pointer; the view zooms out if a slot would be off screen; let go to drop (one undo step, its annotations go with it), Esc or right click cancels; a drop refits the whole scene at once (like 0), a cancel restores the view you had. Double click a text or a callout: edit its text again (Enter or Esc keeps the change; a blank or unchanged text keeps the old one); undo restores the old text. |
| `x` | crop | Drag the part to keep. On release the image is cropped and the previous tool comes back. Undo restores. |

## Keys

| Key | Action |
|---|---|
| `c` again (callout tool active) | pointer style: straight / stairs |
| `a` again (arrow tool active) | arrow style: straight / stairs |
| `t` again (text tool active) | text style: plain / boxed |
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
| `Delete` | delete selection (move/select) |
| `Backspace` | delete selection (move/select) |
| `Esc` | quit |
| `q` | quit |
| `?` | help |
| `F1` | help |
| `o` | open / close the file browser |
| `h` | hide / show the panels |
| `Space` | hold: hand, drag the canvas with the left button |
| `b` | canvas: light / dark grey |
| `.` | canvas padding: more |
| `,` | canvas padding: less |
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
| Drawing past the image | The canvas grows to hold the shape, in light or dark grey (`b`, kept for the next sessions); the export holds it all. Zoom out (`-`) for room around a full-screen image |
| Right click | Cancel the shape or text in progress |
| Click on the dock | Pick a tool or a color; the size slot steps the size, `?` opens this help. With the arrow or callout tool, the switch above the dock picks the arrow style (arrows and callout pointers); with the text tool, the text style (plain or boxed) |
| Click on the top bar | Undo or redo (a dim button has nothing to do); the half-filled circle switches the canvas background (like `b`); the slider sets the canvas padding: empty margin of 0, 64, 96, 128 or 192 px in the canvas color, in the export too (click or drag to a notch, or wheel over it; like `,` `.`; kept for the next sessions) |
| Folder button (top left) or `o` | Opens a file browser panel over the left of the canvas (it does not shrink the canvas): your home folder at first, then the last folder. It lists folders and images (PNG, JPEG, BMP) only, hidden names left out, newest first, folders and images mixed, with a thumbnail, the date and the image size. Click a folder or `..` (or the up arrow) to go in or up; the wheel scrolls |
| Drag an image from the browser | Drag a row onto the canvas: the free magnet slots next to the placed images show dashed and the nearest one lights up; let go to place the image there (one undo step), Esc, right click or a release over the panel cancels. The view zooms out if a slot would be off screen, then jumps to the fit of the whole scene (the open panel overlays it; Esc restores the old view). The panel stays open |
| Esc with the browser open | Close the browser (before the other Esc actions, but after cancelling a drag and closing the help) |
| Esc or q while drawing | Cancel the shape in progress |
| Esc with a selection | Clear the selection |
| Esc or q with unsaved changes | Shows a warning; a second Esc or q quits. Ctrl+C counts as saved: the clipboard keeps the image. |
| Esc, q or a click with help open | Close the help |
| Esc or q while typing | Esc finishes the text; q is a letter |
| Ctrl+Z while typing | Drop the text in progress |
| Tab while typing | Finish the text, then go to the next tool |
