#!/usr/bin/env bash
# Capture mode smoke test on a real display (needs DISPLAY, xdotool, ImageMagick).
# Runs `felt --capture` three times under xdotool and checks the saved PNG:
#   1. a drag of 400x300, released: the editor opens on exactly that region;
#   2. Esc: exit status 1, no editor;
#   3. Tab (delay 1 s on), then a drag of 300x200: the editor opens on the
#      region grabbed fresh after about 1 s.
# Run through `zig build smoke-capture`. Takes about 10 s and grabs the pointer
# and keyboard meanwhile; it clicks nothing outside felt's own windows.
set -euo pipefail
bin=${1:-zig-out/bin/felt}
out=test-out/x11-capture-smoke
mkdir -p "$out"
rm -f "$out"/*.png "$out"/*.txt
rm -rf "$out/xdg"

for tool in xdotool identify; do
  command -v "$tool" >/dev/null || { echo "capture-smoke: $tool not found" >&2; exit 2; }
done
[ -n "${DISPLAY:-}" ] || { echo "capture-smoke: DISPLAY is not set (try DISPLAY=:0)" >&2; exit 2; }

pid=
trap '[ -n "$pid" ] && kill $pid 2>/dev/null || true' EXIT

# Start felt --capture with args; wait for the overlay window.
start() {
  XDG_CONFIG_HOME="$PWD/$out/xdg" "$bin" --capture --timing "$@" 2>>"$out/log.txt" &
  pid=$!
  local w=
  for _ in $(seq 50); do
    w=$(xdotool search --class '^felt-capture$' 2>/dev/null | head -1) && [ -n "$w" ] && return 0
    sleep 0.1
  done
  echo "capture-smoke: no overlay window after 5 s" >&2; cat "$out/log.txt" >&2; exit 1
}

# Wait for the editor window (class felt), save with Ctrl+S, quit with Esc.
save_and_quit() {
  local file=$1 w=
  for _ in $(seq 100); do
    w=$(xdotool search --class '^felt$' 2>/dev/null | head -1) && [ -n "$w" ] && break
    sleep 0.1
  done
  [ -n "$w" ] || { echo "capture-smoke: no editor window after the selection" >&2; cat "$out/log.txt" >&2; exit 1; }
  sleep 0.4
  xdotool windowfocus --sync "$w"
  xdotool key ctrl+s
  for _ in $(seq 50); do [ -s "$file" ] && break; sleep 0.1; done
  sleep 0.2
  xdotool key Escape
  for _ in $(seq 30); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
  if kill -0 $pid 2>/dev/null; then echo "capture-smoke: felt did not quit on Esc" >&2; exit 1; fi
  wait $pid
  pid=
}

size_of() { identify -format '%wx%h' "$1"; }

drag() { # x0 y0 x1 y1
  xdotool mousemove --sync "$1" "$2" mousedown 1
  for i in 1 2 3 4; do
    xdotool mousemove $(($1 + ($3 - $1) * i / 4)) $(($2 + ($4 - $2) * i / 4))
    sleep 0.03
  done
  xdotool mouseup 1
}

# 1. Drag, confirm on release.
start -o "$out/drag.png"
sleep 0.3
drag 500 400 900 700
save_and_quit "$out/drag.png"
[ "$(size_of "$out/drag.png")" = "400x300" ] || { echo "capture-smoke: drag saved $(size_of "$out/drag.png"), expected 400x300" >&2; exit 1; }

# 2. Esc cancels: exit status 1, no editor.
start -o "$out/cancel.png"
sleep 0.3
xdotool key Escape
status=0
wait $pid || status=$?
pid=
[ "$status" -eq 1 ] || { echo "capture-smoke: Esc gave exit status $status, expected 1" >&2; exit 1; }
[ -z "$(xdotool search --class '^felt$' 2>/dev/null)" ] || { echo "capture-smoke: an editor window opened after Esc" >&2; exit 1; }
[ ! -e "$out/cancel.png" ] || { echo "capture-smoke: Esc wrote a file" >&2; exit 1; }

# 3. Tab: delay on; the overlay goes away, then the region is grabbed live.
start -o "$out/delay.png"
sleep 0.3
xdotool key Tab
sleep 0.2
drag 600 500 900 700
save_and_quit "$out/delay.png"
[ "$(size_of "$out/delay.png")" = "300x200" ] || { echo "capture-smoke: delayed drag saved $(size_of "$out/delay.png"), expected 300x200" >&2; exit 1; }

cat "$out/log.txt"
echo "capture-smoke: OK ($out/*.png)"
