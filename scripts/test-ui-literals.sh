#!/usr/bin/env bash
# Checks scripts/check-ui-literals.sh on small trees of its own (UI_LITERALS_ROOT): a literal added over the baseline fails, one removed
# without lowering the baseline fails, a component file and a comment are not counted, and the real tree matches its baseline.
# Needs no build and no screen, so the Linux lint job runs it.
set -u
cd "$(dirname "$0")/.."
script="$PWD/scripts/check-ui-literals.sh"
status=0
fail() { echo "FAIL: $*" >&2; status=1; }
tree() { # file-name content baseline-radius
  local dir; dir=$(mktemp -d); mkdir -p "$dir/Sources/WorkbenchApp" "$dir/scripts"
  printf '%s\n' "$2" > "$dir/Sources/WorkbenchApp/$1"
  printf 'radius %s\nfontsize 0\ncapsule 0\npadding 0\n' "$3" > "$dir/scripts/ui-literals.baseline"
  echo "$dir"
}
run() { UI_LITERALS_ROOT="$1" sh "$script" 2>&1; }
lit='struct A: View { var body: some View { Color.red.clipShape(RoundedRectangle(cornerRadius: 12)) } }'

dir=$(tree View.swift "$lit" 0)
out=$(run "$dir"); code=$?
[ "$code" = 1 ] || fail "a radius over the baseline passed ($code)"
echo "$out" | grep -q "radius literals.*went from 0 to 1" || fail "the message does not say what changed: $out"
echo "$out" | grep -q "component or a Theme token" || fail "the message does not say what to do: $out"
rm -rf "$dir"

dir=$(tree View.swift "$lit" 1)
run "$dir" >/dev/null; [ "$?" = 0 ] || fail "a count equal to the baseline was refused"
rm -rf "$dir"

dir=$(tree View.swift "struct A {}" 1)
out=$(run "$dir"); code=$?
[ "$code" = 1 ] || fail "a count under the baseline passed ($code): the ratchet would let it creep back"
echo "$out" | grep -q "lower the baseline" || fail "the message does not say to lower it: $out"
rm -rf "$dir"

dir=$(tree Theme.swift "$lit" 0)
run "$dir" >/dev/null; [ "$?" = 0 ] || fail "a component file's literals were counted"
rm -rf "$dir"

dir=$(tree View.swift "// RoundedRectangle(cornerRadius: 12) was here" 0)
run "$dir" >/dev/null; [ "$?" = 0 ] || fail "a comment was counted"
rm -rf "$dir"

# and the real tree matches its baseline
sh "$script" >/dev/null 2>&1 || fail "the repository does not match scripts/ui-literals.baseline"
[ "$status" = 0 ] && echo "ui-literals check: ok"
exit $status
