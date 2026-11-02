#!/usr/bin/env bash
# Source this: it points DEVELOPER_DIR at the Xcode named in .xcode-version (the one CI builds with), so a script does not build with
# whatever Xcode the system happens to select (a newer one has its own compiler bugs, docs/swift-bugs/).
#   . "$ROOT/scripts/use-xcode.sh"
# - DEVELOPER_DIR already set: left alone (someone chose).
# - the pinned Xcode is installed (in /Applications or ~/Applications, as Xcode_26.6.app, Xcode-26.6.app or Xcode-26.6.0.app): used.
# - it is not: a line on stderr says so, and the system's Xcode is used (nothing is installed or changed).
# XCODE_SEARCH_DIRS (space separated) replaces the places looked in; the tests use it.
use_pinned_xcode() {
  local root version dir app
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  [[ -n "${DEVELOPER_DIR:-}" ]] && return 0
  version="$(tr -d '[:space:]' <"$root/.xcode-version" 2>/dev/null)"
  [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "use-xcode: $root/.xcode-version is missing or not a version" >&2; return 0; }
  for dir in ${XCODE_SEARCH_DIRS:-/Applications "$HOME/Applications"}; do
    for app in "$dir/Xcode_$version.app" "$dir/Xcode-$version.app" "$dir/Xcode_$version.0.app" "$dir/Xcode-$version.0.app"; do
      if [[ -d "$app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="$app/Contents/Developer"
        return 0
      fi
    done
  done
  echo "use-xcode: Xcode $version (.xcode-version) is not installed; building with $(xcode-select -p 2>/dev/null || echo 'the system Xcode')" >&2
}
use_pinned_xcode
