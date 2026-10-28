#!/usr/bin/env bash
# Builds Workbench.app: a release build of the SwiftUI app in a bundle with an Info.plist, the dock icon and a signature. A bare
# binary has no Dock icon of its own, and some things (notifications, a login item) need a bundle.
#   scripts/bundle-app.sh            build the bundle, then check it: the plist lints, the icon has every size, the signature holds
#   scripts/bundle-app.sh --check    the same, then launch it, find its window by pid, render the Dock icon to a PNG, end that pid
# Output: .build/bundle/Workbench.app, or WORKBENCH_APP=<path ending in .app>. It writes that bundle, this repository's .build/ and a
# temporary folder, and replaces an existing output only if it is a Workbench bundle. `--check` also removes the window state and
# settings that its own throwaway bundle id (dev.rogal.workbench.check-<pid>) leaves under ~/Library, and nothing under any other id.
# Environment:
#   WORKBENCH_APP        where to write the bundle (default .build/bundle/Workbench.app)
#   WORKBENCH_SIGN_ID    a code-signing identity to sign with; unset: ad hoc, which needs no certificate and works in CI
#   WORKBENCH_BUNDLE_ID  the bundle id (default dev.rogal.workbench); --check uses one of its own, so the check leaves no settings
# Exit codes: 0 done, 1 a step failed (the step on stderr), 2 not macOS or a usage problem. --check prints PASS or FAIL per step.
set -euo pipefail

# Testable on any system: scripts/test-bundle-app-guard.sh sets it to check the refusal.
PLATFORM="${WORKBENCH_BUNDLE_UNAME:-$(uname -s)}"
if [[ "$PLATFORM" != Darwin ]]; then
  echo "bundle-app: Workbench.app is a macOS app and this is $PLATFORM; build the library and the CLI with 'swift build'" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK=0
for argument in "$@"; do
  case "$argument" in
    --check) CHECK=1 ;;
    *) echo "usage: scripts/bundle-app.sh [--check]" >&2; exit 2 ;;
  esac
done

APP="${WORKBENCH_APP:-$ROOT/.build/bundle/Workbench.app}"
BUNDLE_ID="${WORKBENCH_BUNDLE_ID:-dev.rogal.workbench}"
[[ "$APP" == *.app ]] || { echo "bundle-app: WORKBENCH_APP must end in .app: $APP" >&2; exit 2; }
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "bundle-app: not a bundle id: $BUNDLE_ID" >&2; exit 2; }
PNG="$ROOT/Resources/AppIcon.png"
[[ -s "$PNG" ]] || { echo "bundle-app: no $PNG (scripts/render-icon.sh makes it from the SVG)" >&2; exit 1; }

TMP="$(mktemp -d)"
PID=""
cleanup() {
  [[ -n "$PID" ]] && kill "$PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

PASSED=0
FAILED=0
step() {  # step "<name>" <command...>: prints PASS or FAIL for it and keeps going
  local name="$1"
  shift
  if "$@" >"$TMP/step.out" 2>&1; then
    PASSED=$((PASSED + 1)); printf 'PASS  %s\n' "$name"
  else
    FAILED=$((FAILED + 1)); printf 'FAIL  %s: %s\n' "$name" "$(head -c 300 "$TMP/step.out" | tr '\n' ' ')"
  fi
}

# --- build ---------------------------------------------------------------------------------------------------------------------

# Low CPU priority: this runs while someone is working.
nice -n 10 swift build -c release -q --product WorkbenchApp --package-path "$ROOT"
BIN="$(swift build -c release --product WorkbenchApp --package-path "$ROOT" --show-bin-path)/WorkbenchApp"
[[ -x "$BIN" ]] || { echo "bundle-app: the build left no $BIN" >&2; exit 1; }

# Replace only what is already a Workbench bundle: a wrong WORKBENCH_APP must never delete someone else's folder.
if [[ -e "$APP" ]]; then
  [[ -f "$APP/Contents/Info.plist" && -f "$APP/Contents/MacOS/WorkbenchApp" ]] \
    || { echo "bundle-app: $APP exists and is not a Workbench bundle; not replacing it" >&2; exit 2; }
  rm -rf "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WorkbenchApp"

# The icon: every size macOS asks for, from the 1024 px master (scripts/render-icon.sh makes it from the SVG).
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Workbench</string>
  <key>CFBundleDisplayName</key><string>Workbench</string>
  <key>CFBundleExecutable</key><string>WorkbenchApp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Sign: ad hoc unless an identity is named. A named identity that is not there is an error, not a quiet fallback.
SIGN_ID="${WORKBENCH_SIGN_ID:--}"
if [[ "$SIGN_ID" != "-" ]] && ! security find-identity -p codesigning | grep -qF "\"$SIGN_ID\""; then
  echo "bundle-app: no code-signing identity named '$SIGN_ID' (unset WORKBENCH_SIGN_ID to sign ad hoc)" >&2
  exit 1
fi
codesign --force --sign "$SIGN_ID" "$APP" >/dev/null
echo "signed with: $([[ "$SIGN_ID" == "-" ]] && echo "ad hoc" || echo "$SIGN_ID")"

# --- the checks that need no screen ----------------------------------------------------------------------------------------------

icon_sizes() {
  iconutil -c iconset "$APP/Contents/Resources/AppIcon.icns" -o "$TMP/back.iconset" >/dev/null
  [[ "$(ls "$TMP/back.iconset" | wc -l | tr -d ' ')" == 10 ]]
}
step "Info.plist lints" plutil -lint "$APP/Contents/Info.plist"
step "AppIcon.icns has all ten sizes" icon_sizes
step "the signature holds" codesign --verify --strict "$APP"

# --- --check: launch it -----------------------------------------------------------------------------------------------------------

if [[ "$CHECK" == 1 ]]; then
  # A bundle id of its own, so the check saves no window state or settings under the real one, and removes what it made.
  CHECK_ID="dev.rogal.workbench.check-$$"
  /usr/bin/plutil -replace CFBundleIdentifier -string "$CHECK_ID" "$APP/Contents/Info.plist"
  codesign --force --sign "$SIGN_ID" "$APP" >/dev/null

  launch() {
    open -g -n "$APP"
    for _ in $(seq 1 50); do
      PID="$(pgrep -f "$APP/Contents/MacOS/WorkbenchApp" | head -1 || true)"
      [[ -n "$PID" ]] && return 0
      sleep 0.2
    done
    return 1
  }
  has_window() {
    for _ in $(seq 1 30); do
      swift "$ROOT/scripts/window-info.swift" "$PID" >"$TMP/window" 2>"$TMP/window.err" && { cat "$TMP/window"; return 0; }
      # Exit 1 is "no window yet"; anything else is the helper itself failing, which is no reason to keep trying.
      [[ $? -eq 1 ]] || break
      sleep 0.3
    done
    cat "$TMP/window.err" >&2
    return 1
  }
  step "the bundle launches" launch
  step "the process shows a window, found by its pid" has_window
  step "the Dock icon is the generated one (amber in it)" swift "$ROOT/scripts/app-icon.swift" "$APP" "$TMP/dock-icon.png"
  [[ -f "$TMP/dock-icon.png" && -n "${WORKBENCH_ICON_OUT:-}" ]] && cp "$TMP/dock-icon.png" "$WORKBENCH_ICON_OUT"
  # Only the pid this script started, then what its id left behind.
  if [[ -n "$PID" ]]; then
    kill "$PID" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
    kill -9 "$PID" 2>/dev/null || true
    PID=""
  fi
  defaults delete "$CHECK_ID" 2>/dev/null || true
  rm -rf "$HOME/Library/Saved Application State/$CHECK_ID.savedState" "$HOME/Library/Caches/$CHECK_ID" "$HOME/Library/HTTPStorages/$CHECK_ID"
  rm -f "$HOME/Library/Preferences/$CHECK_ID.plist"
fi

echo "$APP"
printf 'RESULT: %s (%d passed, %d failed)\n' "$([[ $FAILED == 0 ]] && echo PASS || echo FAIL)" "$PASSED" "$FAILED"
[[ "$FAILED" == 0 ]]
