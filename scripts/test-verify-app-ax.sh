#!/usr/bin/env bash
# Checks how scripts/ax.swift resolves and refuses a label, on a fixture tree instead of a live window: no GUI, no permission, no process.
# `press` matches an exact label before a prefix, never presses text that is not a button, and refuses by the label it resolves to, so a
# short prefix cannot reach a button the script's own refusal list would catch. macOS only (ax.swift imports AppKit); the app job runs it.
set -u
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
status=0
fail() { echo "FAIL: $*" >&2; status=1; }

# Doctor, Not run comes before Doctor on purpose: an exact label must win over the first prefix match.
printf 'AXButton\tChoose project, now x\nAXStaticText\tbase: main\nAXStaticText\tEvent log in words\nAXButton\tDoctor, Not run\nAXButton\tDoctor\nAXButton\tEvent log 4\n' > "$tmp/tree"
export WORKBENCH_AX_FIXTURE="$tmp/tree"
export WORKBENCH_REFUSE='^(Choose project|Event log|Open the event log)'

# expect <exit code> <text the output must contain> <args...>
expect() {
  local want="$1" text="$2"
  shift 2
  local out code
  out=$(swift scripts/ax.swift "$@" 2>&1); code=$?
  [ "$code" = "$want" ] || fail "'$*' exits $code, not $want: $out"
  echo "$out" | grep -qF -- "$text" || fail "'$*' does not say '$text': $out"
}

expect 1 'Refused: "Eve" is "Event log 4"' press Eve
expect 1 'Refused: "Choose" is "Choose project, now x"' press Choose
expect 1 'Refused: "Event log 4" is "Event log 4"' press "Event log 4"
expect 0 "pressed (fixture) AXButton Doctor" press Doctor
out=$(swift scripts/ax.swift press Doctor 2>&1); [ "$out" = "pressed (fixture) AXButton Doctor" ] || fail "an exact label did not win over the prefix: $out"
expect 0 "pressed (fixture) AXButton Doctor, Not run" press "Doctor,"
expect 1 "Nothing pressable is labelled" press "base"
expect 1 "Nothing pressable is labelled" press "Event log in"
expect 1 "Nothing pressable is labelled" press "Nope"
expect 2 "usage: press <label>" press ""
expect 2 "usage: press <label>" press
expect 0 "AXStaticText	base: main" list
expect 2 "supports list and press" resize 1 1

[ "$status" = 0 ] && echo "verify-app ax: ok"
exit $status
