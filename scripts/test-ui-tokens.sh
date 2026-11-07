#!/usr/bin/env bash
# Checks scripts/check-ui-tokens.sh on small trees of its own (UI_TOKENS_ROOT): each literal it bans is found in each spelling, the tokens,
# the component files, comments and URLs are not, and the offender is named. Needs no build and no screen, so the Linux lint job runs it.
set -u
cd "$(dirname "$0")/.."
script="$PWD/scripts/check-ui-tokens.sh"
status=0
fail() { echo "FAIL: $*" >&2; status=1; }
tree() { # file-name content
  local dir; dir=$(mktemp -d); mkdir -p "$dir/Sources/WorkbenchApp"
  printf '%s\n' "$2" > "$dir/Sources/WorkbenchApp/$1"
  echo "$dir"
}
run() { UI_TOKENS_ROOT="$1" sh "$script" 2>&1; }
view() { echo "struct A: View { var body: some View { $1 } }"; }

# each banned literal, in the spellings that are still a literal: exit 1, and the message names the file and what to use
banned=(
  'radius|RoundedRectangle(cornerRadius: 12)' 'radius|RoundedRectangle(cornerRadius:12)' 'radius|RoundedRectangle(cornerRadius:   12)'
  'font|Text("x").font(.system(size: 11))' 'font|Text("x").font(.system(
    size: 11))' 'font|Text("x").font(.caption)' 'font|Text("x").font(Theme.big)'
  'Space|Text("x").padding(8)' 'Space|Text("x").padding(.horizontal, 8)' 'Space|Text("x").padding(.top, -2)' 'Space|Text("x").padding(-4)'
  'Space|Text("x").padding([.vertical, .trailing], 8)' 'Space|Text("x").padding(
    .horizontal,
    8
)' 'Space|Text("x").padding(.top, wide ? 8 : 4)' 'Space|padding(.horizontal, 28)'
  'Space|VStack(spacing: 6) { Text("x") }' 'Space|HStack(alignment: .top, spacing: 10) { Text("x") }'
  'Space|VStack(spacing: wide ? 8 : 4) { Text("x") }'
  'Pill|Color.red.clipShape(Capsule())'
  'Space|Spacer(minLength: 8)' 'Space|Spacer(minLength:0)' 'Space|HStack { Text("x"); Spacer(minLength: 12) }'
  'named size|Color.red.frame(width: 22, height: 22)' 'named size|Color.red.frame(height: 440)' 'named size|Color.red.frame(width:16)'
)
for case in "${banned[@]}"; do
  want=${case%%|*}; code=${case#*|}
  dir=$(tree View.swift "$(view "$code")")
  out=$(run "$dir"); rc=$?
  [ "$rc" = 1 ] || fail "[$code] was not refused ($rc)"
  echo "$out" | grep -q "View.swift: " || fail "[$code]: the offender is not named: $out"
  echo "$out" | grep -qi "$want" || fail "[$code]: the message does not say what to use ($want): $out"
  rm -rf "$dir"
done

# and what is not a literal
allowed=(
  'Text("x").textStyle(.caption, .secondary)' 'Text("x").role(.error)' 'RoundedRectangle(cornerRadius: Radius.card)'
  'Text("x").padding(.horizontal, Space.m)' 'Text("x").padding(Spacing.inset)' 'VStack(spacing: Space.s) { Text("x") }'
  'VStack(spacing: 0) { Text("x") }' 'Text("x").lineSpacing(6)' 'Text("x").pill()'
  'Spacer(minLength: Space.s)' 'Color.red.frame(width: Self.width, height: ModalBodyHeight.page.points)' 'Color.red.frame(maxWidth: 220, minHeight: 56)'
)
for code in "${allowed[@]}"; do
  dir=$(tree View.swift "$(view "$code")")
  run "$dir" >/dev/null; [ "$?" = 0 ] || fail "[$code] was refused"
  rm -rf "$dir"
done

# a component file holds the numbers; a comment and a URL's // are read as they should be
dir=$(tree Space.swift 'enum Space { static let s: CGFloat = 8; static let a = Text("x").font(.caption).padding(8) }')
run "$dir" >/dev/null; [ "$?" = 0 ] || fail "a component file was refused"
rm -rf "$dir"
dir=$(tree View.swift 'struct A {} // RoundedRectangle(cornerRadius: 12) .font(.caption) was here')
run "$dir" >/dev/null; [ "$?" = 0 ] || fail "a trailing comment was read as code"
rm -rf "$dir"
dir=$(tree View.swift 'struct A: View { var body: some View { Link("https://example.test", destination: u).clipShape(RoundedRectangle(cornerRadius: 12)) } }')
run "$dir" >/dev/null; [ "$?" = 1 ] || fail "a literal after a URL on the same line was hidden by its //"
rm -rf "$dir"

# several offenders are all named
dir=$(tree View.swift "$(view 'Text("x").font(.caption).padding(8)')")
out=$(run "$dir"); n=$(echo "$out" | grep -c "^error:")
[ "$n" -ge 2 ] || fail "two kinds of offender were not both reported: $out"
rm -rf "$dir"

# and the real tree is clean
sh "$script" >/dev/null 2>&1 || fail "the repository has a UI literal outside the component files: $(sh "$script" 2>&1 | head -5)"
[ "$status" = 0 ] && echo "ui-tokens check: ok"
exit $status
