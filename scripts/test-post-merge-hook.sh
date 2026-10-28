#!/usr/bin/env bash
# Checks .githooks/post-merge decides right, in a throwaway repository, without building anything (WORKBENCH_HOOK_DRY_RUN=1).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo "skip: the hook is macOS only"; exit 0; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
git init -q -b main
git config user.email t@t && git config user.name t
mkdir -p Sources docs scripts
echo a > Sources/a.swift && echo a > docs/a.md && echo a > scripts/bundle-app.sh
git add -A && git commit -q -m one
FAILED=0
check() {  # name, expected substring, then the commit to make
  local name="$1" expect="$2"
  shift 2
  "$@"
  git update-ref ORIG_HEAD HEAD~1
  local out
  out="$(WORKBENCH_HOOK_DRY_RUN=1 bash "$ROOT/.githooks/post-merge" 2>&1 || true)"
  if [[ "$out" == *"$expect"* ]]; then echo "PASS  $name"; else echo "FAIL  $name: wanted '$expect', got '$out'"; FAILED=1; fi
}
change() { echo "$RANDOM" >> "$1"; git add -A; git commit -q -m c; }
check "an app source change rebuilds" "post-merge: rebuild" change Sources/a.swift
check "a docs change does not" "skip: nothing the app is built from changed" change docs/a.md
check "the bundle script changing rebuilds" "post-merge: rebuild" change scripts/bundle-app.sh
git checkout -q -b feature
check "a feature branch is skipped" "skip: not main" change Sources/a.swift
exit "$FAILED"
