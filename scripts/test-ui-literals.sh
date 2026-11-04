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
  printf 'radius %s\nfontsize 0\ncapsule 0\npadding 0\ntextstyle 0\n' "$3" > "$dir/scripts/ui-literals.baseline"
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

# each literal it counts is found, not only radius
tree2() { # file-name content (baseline all zero)
  local dir; dir=$(mktemp -d); mkdir -p "$dir/Sources/WorkbenchApp" "$dir/scripts"
  printf '%s\n' "$2" > "$dir/Sources/WorkbenchApp/$1"
  printf 'radius 0\nfontsize 0\ncapsule 0\npadding 0\ntextstyle 0\n' > "$dir/scripts/ui-literals.baseline"
  echo "$dir"
}
for case in 'fontsize|Text("x").font(.system(size: 11))' 'capsule|Color.red.clipShape(Capsule())' 'padding|Text("x").padding(.horizontal, 8)' 'textstyle|Text("x").font(.caption).foregroundStyle(.secondary)'; do
  name=${case%%|*}; code=${case#*|}
  dir=$(tree2 View.swift "struct A: View { var body: some View { $code } }")
  out=$(run "$dir"); rc=$?
  [ "$rc" = 1 ] && echo "$out" | grep -q "$name literals.*went from 0 to 1" || fail "a $name literal over the baseline was not caught ($rc): $out"
  rm -rf "$dir"
done
# spellings that are still a literal
for code in 'RoundedRectangle(cornerRadius:12)' 'RoundedRectangle(cornerRadius:   12)' 'Text("x").padding(
    .horizontal,
    8
)' 'Text("x").font(.system(
    size: 11))' 'Text("x").padding(.top, -2)' 'Text("x").padding(-4)'; do
  dir=$(tree2 View.swift "struct A: View { var body: some View { $code } }")
  out=$(run "$dir"); rc=$?
  [ "$rc" = 1 ] || fail "a literal written as [$code] was not caught ($rc)"
  rm -rf "$dir"
done
# a URL's // is not a comment: a literal after it on the line still counts
dir=$(tree2 View.swift 'struct A: View { var body: some View { Link("https://example.test", destination: u).clipShape(RoundedRectangle(cornerRadius: 12)) } }')
run "$dir" >/dev/null; [ "$?" = 1 ] || fail "a literal after a URL on the same line was hidden by its //"
rm -rf "$dir"
dir=$(tree2 View.swift 'struct A: View { var body: some View { A() } } // RoundedRectangle(cornerRadius: 12) is gone')
run "$dir" >/dev/null; [ "$?" = 0 ] || fail "a trailing comment was counted"
rm -rf "$dir"
# a font is a TextStyle: any raw .font( counts, a token inside it too
dir=$(tree2 View.swift 'struct A: View { var body: some View { Text("x").font(Theme.big) } }')
run "$dir" >/dev/null; [ "$?" = 1 ] || fail "a raw .font( with a token was not counted"
rm -rf "$dir"
dir=$(tree2 View.swift 'struct A: View { var body: some View { Text("x").textStyle(.caption, .secondary) } }')
run "$dir" >/dev/null; [ "$?" = 0 ] || fail "a textStyle was counted"
rm -rf "$dir"
# and what is not one: a token or a constant is the fix
for code in 'Text("x").padding(.horizontal, spacing)' 'Text("x").padding(.top, Metrics.inset2)' 'RoundedRectangle(cornerRadius: Radius.card)'; do
  dir=$(tree2 View.swift "struct A: View { var body: some View { $code } }")
  run "$dir" >/dev/null; [ "$?" = 0 ] || fail "[$code] was counted as a literal"
  rm -rf "$dir"
done

# a malformed baseline fails instead of comparing as "not greater"
for bl in 'radius 46x\nfontsize 0\ncapsule 0\npadding 0\ntextstyle 0' 'radius 1\nfontsize 0\ncapsule 0' 'radius 1\nradius 1\nfontsize 0\ncapsule 0\npadding 0\ntextstyle 0' 'radius -1\nfontsize 0\ncapsule 0\npadding 0\ntextstyle 0' 'radius 1\nfontsize 0\ncapsule 0\npadding 0\ntextstyle 0\nextra 1'; do
  dir=$(tree2 View.swift 'struct A {}')
  printf "$bl\n" > "$dir/scripts/ui-literals.baseline"
  run "$dir" >/dev/null; [ "$?" = 1 ] || fail "a malformed baseline passed: [$bl]"
  rm -rf "$dir"
done

# --against: the baseline may not be higher than the base branch's
repo=$(mktemp -d); mkdir -p "$repo/scripts" "$repo/Sources/WorkbenchApp"
printf 'radius 5\nfontsize 0\ncapsule 0\npadding 0\ntextstyle 0\n' > "$repo/scripts/ui-literals.baseline"
git -C "$repo" init -q && git -C "$repo" add -A && git -C "$repo" -c user.email=t@t -c user.name=t commit -qm base && git -C "$repo" branch -q base
printf 'radius 6\nfontsize 0\ncapsule 0\npadding 0\ntextstyle 0\n' > "$repo/scripts/ui-literals.baseline"
out=$(cd "$repo" && UI_LITERALS_ROOT="$repo" sh "$script" --against base 2>&1); rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q "went up from 5" || fail "a raised baseline passed against its base ($rc): $out"
printf 'radius 4\nfontsize 0\ncapsule 0\npadding 0\ntextstyle 0\n' > "$repo/scripts/ui-literals.baseline"
(cd "$repo" && UI_LITERALS_ROOT="$repo" sh "$script" --against base >/dev/null 2>&1); [ "$?" = 0 ] || fail "a lowered baseline was refused against its base"
# a base from before a name was added (four names against five) is compared on the names it has
printf 'radius 5\nfontsize 0\ncapsule 0\npadding 0\n' > "$repo/scripts/ui-literals.baseline"; git -C "$repo" add -A; git -C "$repo" -c user.email=t@t -c user.name=t commit -qm four; git -C "$repo" branch -q four
printf 'radius 4\nfontsize 0\ncapsule 0\npadding 0\ntextstyle 9\n' > "$repo/scripts/ui-literals.baseline"
(cd "$repo" && UI_LITERALS_ROOT="$repo" sh "$script" --against four >/dev/null 2>&1); [ "$?" = 0 ] || fail "a base with four names was refused"
(cd "$repo" && UI_LITERALS_ROOT="$repo" sh "$script" --against nosuchref >/dev/null 2>&1); [ "$?" = 1 ] || fail "a ref that is not there passed: a shallow checkout would skip the comparison"
git -C "$repo" checkout -q --orphan fresh && git -C "$repo" rm -rfq --cached scripts && git -C "$repo" -c user.email=t@t -c user.name=t commit -qm nobaseline --allow-empty && git -C "$repo" branch -q nobaseline
(cd "$repo" && UI_LITERALS_ROOT="$repo" sh "$script" --against nobaseline >/dev/null 2>&1); [ "$?" = 0 ] || fail "a base that has no baseline yet was refused"
rm -rf "$repo"

# and the real tree matches its baseline
sh "$script" >/dev/null 2>&1 || fail "the repository does not match scripts/ui-literals.baseline"
[ "$status" = 0 ] && echo "ui-literals check: ok"
exit $status
