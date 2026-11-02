#!/usr/bin/env bash
# Checks scripts/use-xcode.sh picks the pinned Xcode, leaves a chosen DEVELOPER_DIR alone, and says so when the Xcode is missing.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
VERSION="$(tr -d '[:space:]' <"$ROOT/.xcode-version")"
FAILED=0
result() { if [[ "$2" == "$3" ]]; then echo "PASS  $1"; else echo "FAIL  $1: wanted '$3', got '$2'"; FAILED=1; fi; }
run() { # env assignments..., prints "<DEVELOPER_DIR>|<stderr>"
  local err; err="$TMP/err"
  local dir; dir="$(env -u DEVELOPER_DIR "$@" bash -c '. "$0/scripts/use-xcode.sh" 2>"$1"; echo "${DEVELOPER_DIR:-}"' "$ROOT" "$err")"
  echo "$dir|$(cat "$err")"
}
mkdir -p "$TMP/a/Xcode-$VERSION.0.app/Contents/Developer" "$TMP/b/Xcode_$VERSION.app/Contents/Developer"
r="$(run XCODE_SEARCH_DIRS="$TMP/a")"
result "Xcode-$VERSION.0.app is found" "$r" "$TMP/a/Xcode-$VERSION.0.app/Contents/Developer|"
r="$(run XCODE_SEARCH_DIRS="$TMP/b")"
result "Xcode_$VERSION.app is found" "$r" "$TMP/b/Xcode_$VERSION.app/Contents/Developer|"
r="$(run XCODE_SEARCH_DIRS="$TMP/b" DEVELOPER_DIR=/somewhere/else)"
result "a chosen DEVELOPER_DIR is left alone" "$r" "/somewhere/else|"
mkdir -p "$TMP/empty"
r="$(run XCODE_SEARCH_DIRS="$TMP/empty")"
case "$r" in "|use-xcode: Xcode $VERSION"*"is not installed"*) echo "PASS  a missing Xcode is said, not fatal";; *) echo "FAIL  a missing Xcode: got '$r'"; FAILED=1;; esac
exit "$FAILED"
