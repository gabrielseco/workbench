#!/usr/bin/env bash
# Re-render Resources/AppIcon.png (1024 px, transparent) from Resources/AppIcon.svg. Run it after editing the SVG; the PNG is committed,
# so building the app needs no browser. Chrome headless does the drawing, as it does for the Triage app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[[ -x "$CHROME" ]] || { echo "render-icon: no Chrome at $CHROME (set CHROME to a Chrome or Chromium binary)" >&2; exit 1; }
"$CHROME" --headless --disable-gpu --hide-scrollbars --default-background-color=00000000 --window-size=1024,1024 \
  --screenshot="$ROOT/Resources/AppIcon.png" "file://$ROOT/Resources/AppIcon.svg" 2>/dev/null
[[ -s "$ROOT/Resources/AppIcon.png" ]] || { echo "render-icon: Chrome wrote no image" >&2; exit 1; }
echo "$ROOT/Resources/AppIcon.png"
