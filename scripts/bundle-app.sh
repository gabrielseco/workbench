#!/usr/bin/env bash
# Builds Workbench.app: a release build of the SwiftUI app in a bundle with an Info.plist, the dock icon and a signature. A bare
# binary has no Dock icon of its own, and some things (notifications, a login item) need a bundle.
#   scripts/bundle-app.sh            build the bundle, then check it: the plist lints, the icon has every size, the signature holds
#   scripts/bundle-app.sh --check    the same, then launch it, find its window by pid, render the Dock icon to a PNG, end that pid
#   scripts/bundle-app.sh --install  build into ~/Applications/Workbench.app and open it, so its Dock icon can be kept there (right-click
#                                    the icon, Options, Keep in Dock). A Workbench already running from there is never ended: the new
#                                    build is in place, and quitting it (⌘Q) and opening it again gives you that build.
# Output: .build/bundle/Workbench.app, or WORKBENCH_APP=<path ending in .app>. The script writes that bundle and this repository's
# .build/ (its scratch space and, for --check, .build/bundle/dock-icon.png), and replaces an existing output only if it is a
# Workbench bundle. `--check` runs on a disposable copy with a bundle id of its own (dev.rogal.workbench.check-<pid>), so the bundle
# it built keeps its id and signature; macOS saves the launched copy's window state under that id in ~/Library, and the script
# deletes those files, only under that id. The tools it runs (SwiftPM, the Swift compiler, and Chrome for render-icon.sh) keep their own
# usual per-user caches; those are theirs, not redirected, and nothing else is written outside the repository.
# Environment:
#   WORKBENCH_APP        where to write the bundle (default .build/bundle/Workbench.app; with --install, $WORKBENCH_INSTALL_DIR/Workbench.app)
#   WORKBENCH_INSTALL_DIR  where --install puts it (default ~/Applications)
#   WORKBENCH_SIGN_ID    a code-signing identity to sign with; unset: ad hoc, which needs no certificate and works in CI
#   WORKBENCH_BUNDLE_ID  the bundle id (default dev.rogal.workbench)
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
INSTALL=0
for argument in "$@"; do
  case "$argument" in
    --check) CHECK=1 ;;
    --install) INSTALL=1 ;;
    *) echo "usage: scripts/bundle-app.sh [--check] [--install]" >&2; exit 2 ;;
  esac
done

if [[ "$INSTALL" == 1 ]]; then
  APP="${WORKBENCH_APP:-${WORKBENCH_INSTALL_DIR:-$HOME/Applications}/Workbench.app}"
else
  APP="${WORKBENCH_APP:-$ROOT/.build/bundle/Workbench.app}"
fi
BUNDLE_ID="${WORKBENCH_BUNDLE_ID:-dev.rogal.workbench}"
[[ "$APP" == *.app ]] || { echo "bundle-app: WORKBENCH_APP must end in .app: $APP" >&2; exit 2; }
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "bundle-app: not a bundle id: $BUNDLE_ID" >&2; exit 2; }
PNG="$ROOT/Resources/AppIcon.png"
[[ -s "$PNG" ]] || { echo "bundle-app: no $PNG (scripts/render-icon.sh makes it from the SVG)" >&2; exit 1; }

# Scratch space inside this repository's .build/, so nothing is written to the system temp folder.
mkdir -p "$ROOT/.build"
TMP="$(mktemp -d "$ROOT/.build/bundle-tmp.XXXXXX")"
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

# A Workbench running from the output path keeps running (its files are replaced under it); it is told about at the end, never ended.
RUNNING_FROM_APP=""
if [[ "$INSTALL" == 1 ]]; then
  RUNNING_FROM_APP="$(pgrep -f "$APP/Contents/MacOS/WorkbenchApp" | head -1 || true)"
fi

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
has_bundle_id() { [[ "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" == "$BUNDLE_ID" ]]; }
step "the bundle id is $BUNDLE_ID" has_bundle_id

# --- --check: launch it -----------------------------------------------------------------------------------------------------------

if [[ "$CHECK" == 1 ]]; then
  # On a disposable copy at a path of its own, never on the bundle that was built: the copy gets a bundle id of its own (so the
  # check saves no window state or settings under the real one) and is signed again, while the deliverable keeps its id and its
  # signature. The unique path also means the pid lookup below can only ever match the instance this run launched.
  CHECK_ID="dev.rogal.workbench.check-$$"
  CHECK_APP="$TMP/check/Workbench.app"
  mkdir -p "$TMP/check"
  cp -R "$APP" "$CHECK_APP"
  /usr/bin/plutil -replace CFBundleIdentifier -string "$CHECK_ID" "$CHECK_APP/Contents/Info.plist"
  codesign --force --sign "$SIGN_ID" "$CHECK_APP" >/dev/null 2>&1

  launch() {
    open -g -n "$CHECK_APP"
    for _ in $(seq 1 50); do
      PID="$(pgrep -f "$CHECK_APP/Contents/MacOS/WorkbenchApp" | head -1 || true)"
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
  step "the Dock icon is the generated one (amber in it)" swift "$ROOT/scripts/app-icon.swift" "$CHECK_APP" "$TMP/dock-icon.png"
  # What macOS showed as the icon, for a person to look at: next to the bundle's default home, inside .build.
  mkdir -p "$ROOT/.build/bundle"
  [[ -f "$TMP/dock-icon.png" ]] && cp "$TMP/dock-icon.png" "$ROOT/.build/bundle/dock-icon.png"
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
  # The bundle that was built is what the person copies: it must still have its own id and a signature that holds.
  step "the built bundle is untouched by the check (id and signature)" bash -c '
    [[ "$(plutil -extract CFBundleIdentifier raw "$1/Contents/Info.plist")" == "$2" ]] && codesign --verify --strict "$1"' _ "$APP" "$BUNDLE_ID"
fi

if [[ "$INSTALL" == 1 && "$FAILED" == 0 ]]; then
  if [[ -n "$RUNNING_FROM_APP" ]]; then
    echo "installed: $APP (Workbench is running from it, pid $RUNNING_FROM_APP; quit it with ⌘Q and open it again to get this build)"
  else
    open "$APP"
    echo "installed and opened: $APP (right-click its Dock icon, Options, Keep in Dock, to keep it there)"
  fi
fi

echo "$APP"
printf 'RESULT: %s (%d passed, %d failed)\n' "$([[ $FAILED == 0 ]] && echo PASS || echo FAIL)" "$PASSED" "$FAILED"
[[ "$FAILED" == 0 ]]
