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

# `type` names the field it would fill, refuses what is not text, and types nowhere without a field.
expect 1 "No text field to type into" type "hello"
printf 'AXButton\tDoctor\nAXTextArea\tDescribe the change\n' > "$tmp/fields"
WORKBENCH_AX_FIXTURE="$tmp/fields" expect 0 "typed (fixture) AXTextArea Describe the change" type "hello"
WORKBENCH_AX_FIXTURE="$tmp/fields" expect 2 "at most 2000 characters" type "$(printf 'x%.0s' $(seq 1 2001))"
WORKBENCH_AX_FIXTURE="$tmp/fields" expect 2 "no control characters" type "$(printf 'a\033[31mb')"
WORKBENCH_AX_FIXTURE="$tmp/fields" expect 0 "typed (fixture)" type "$(printf 'two\nlines')"
# `focus` names an editable field by its text or its placeholder and nothing else; `click` and `hover` name what they would hit and refuse
# the labels `press` refuses; `key` takes five names; `typekeys` is bounded and printable.
printf 'AXButton\tEvent log 4\nAXButton\tJudge\nAXTextField\tWhat must hold\nAXTextArea\tDo the thing.\nAXStaticText\tbase: main\n' > "$tmp/drive"
export WORKBENCH_AX_FIXTURE="$tmp/drive"
expect 0 "focused (fixture) AXTextField What must hold" focus "What must"
expect 0 "focused (fixture) AXTextArea Do the thing." focus "Do the"
expect 1 "Nothing is labelled" focus "Judge"
expect 1 "Nothing is labelled" focus "base: main"
expect 0 "clicked (fixture) AXButton Judge" click Judge
expect 0 "hovered (fixture) AXTextField What must hold" hover "What must hold"
expect 1 'Refused: "Eve" is "Event log 4"' click Eve
expect 1 'Refused: "Event log" is "Event log 4"' hover "Event log"
expect 2 "usage: click <label>" click ""
expect 0 "key (fixture) tab" key tab
expect 0 "key (fixture) escape" key escape
expect 2 "usage: key return|tab|escape|up|down" key q
expect 2 "usage: key return|tab|escape|up|down" key cmd-q
expect 2 "usage: key return|tab|escape|up|down" key
expect 0 "typekeys (fixture) 5 characters" typekeys hello
expect 2 "at most 200 printable characters" typekeys "$(printf 'x%.0s' $(seq 1 201))"
expect 2 "at most 200 printable characters" typekeys "$(printf 'two\nlines')"
expect 2 "at most 200 printable characters" typekeys "$(printf 'a\033b')"
export WORKBENCH_AX_FIXTURE="$tmp/tree"
expect 2 "usage: press <label>" press ""
expect 2 "usage: press <label>" press
expect 0 $'AXStaticText\tbase: main' list
expect 2 "supports list and press" resize 1 1
expect 2 "supports list and press" scroll 1

[ "$status" = 0 ] && echo "verify-app ax: ok"
exit $status
