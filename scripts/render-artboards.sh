#!/usr/bin/env bash
# Screenshot every artboard of docs/design/chat-feed (dark and light) into <outdir> (default .build/artboards) with Chrome headless, using
# docs/design/chat-feed/support.js as the canvas runtime. Sizes are the boards' own (canvas.json): 1240x800, the rail 288x720.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/.build/artboards}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[[ -x "$CHROME" ]] || { echo "render-artboards: no Chrome at $CHROME (set CHROME)" >&2; exit 1; }
mkdir -p "$OUT"
for board in Main B-Goal C-Run D-Verify E-Autopilot F-Tasks G-NewThread Rail Main-Light B-Goal-Light C-Run-Light D-Verify-Light \
  E-Autopilot-Light F-Tasks-Light G-NewThread-Light; do
  size=1240,800
  [[ "$board" == Rail ]] && size=288,720
  "$CHROME" --headless --disable-gpu --hide-scrollbars --allow-file-access-from-files --virtual-time-budget=4000 \
    --window-size="$size" --screenshot="$OUT/$board.png" "file://$ROOT/docs/design/chat-feed/$board.dc.html" 2>/dev/null
  [[ -s "$OUT/$board.png" ]] || { echo "render-artboards: no image for $board" >&2; exit 1; }
  echo "$OUT/$board.png"
done
