#!/usr/bin/env bash
# Checks scripts/check-banned-apis.sh on small trees of its own (BANNED_APIS_ROOT): a bare TextEditor( in the app fails, the shared
# component, a comment and any other name that ends in TextEditor do not; a bare .borderedProminent fails likewise. Needs no build and no screen, so the Linux lint job runs it.
set -u
cd "$(dirname "$0")/.."
script="$PWD/scripts/check-banned-apis.sh"
status=0
fail() { echo "FAIL: $*" >&2; status=1; }
tree() { # name file-name content
  local dir; dir=$(mktemp -d); mkdir -p "$dir/Sources/WorkbenchApp"
  printf '%s\n' "$3" > "$dir/Sources/WorkbenchApp/$2"
  echo "$dir"
}
run() { BANNED_APIS_ROOT="$1" sh "$script" 2>&1; }

dir=$(tree bad Bad.swift 'struct A: View { var body: some View { TextEditor(text: $x) } }')
out=$(run "$dir"); code=$?
[ "$code" = 1 ] || fail "a bare TextEditor( passed ($code)"
echo "$out" | grep -q "use PlaceholderTextEditor" || fail "the message does not say what to use: $out"
rm -rf "$dir"

dir=$(tree good Good.swift 'struct A: View { var body: some View { PlaceholderTextEditor(text: $x) } }')
run "$dir" >/dev/null; [ "$?" = 0 ] || fail "PlaceholderTextEditor( was refused"
rm -rf "$dir"

dir=$(tree shared PlaceholderTextEditor.swift 'struct P: View { var body: some View { TextEditor(text: $x) } }')
run "$dir" >/dev/null; [ "$?" = 0 ] || fail "the component's own TextEditor( was refused"
rm -rf "$dir"

dir=$(tree comment Note.swift '// a TextEditor(text:) has no placeholder')
run "$dir" >/dev/null; [ "$?" = 0 ] || fail "a comment naming TextEditor( was refused"
rm -rf "$dir"

dir=$(tree other Other.swift 'struct A: View { var body: some View { MarkdownTextEditor(text: $x) } }')
run "$dir" >/dev/null; [ "$?" = 0 ] || fail "another name ending in TextEditor( was refused"
rm -rf "$dir"

dir=$(tree prominent Bad.swift 'struct A: View { var body: some View { Button("x") {}.buttonStyle(.borderedProminent) } }')
out=$(run "$dir"); code=$?
[ "$code" = 1 ] || fail "a bare .borderedProminent passed ($code)"
echo "$out" | grep -q "use .primaryButton()" || fail "the message does not say what to use: $out"
rm -rf "$dir"

dir=$(tree styles ButtonStyles.swift 'func f() { buttonStyle(.borderedProminent) }')
run "$dir" >/dev/null; [ "$?" = 0 ] || fail "the style file's own .borderedProminent was refused"
rm -rf "$dir"

dir=$(tree primary Good.swift '// .borderedProminent is the system accent
struct A: View { var body: some View { Button("x") {}.primaryButton() } }')
run "$dir" >/dev/null; [ "$?" = 0 ] || fail ".primaryButton() or a comment was refused"
rm -rf "$dir"

dir=$(tree bordered Bad.swift 'struct A: View { var body: some View { Button("x") {}.buttonStyle(.bordered) } }')
out=$(run "$dir"); code=$?
[ "$code" = 1 ] || fail "a bare .bordered passed ($code)"
echo "$out" | grep -q "use .primaryButton(size:) or .plainButton(size:)" || fail "the message does not say what to use: $out"
rm -rf "$dir"

dir=$(tree ownstyle Bad.swift 'struct Mine: ButtonStyle { func makeBody(configuration: Configuration) -> some View { configuration.label } }')
run "$dir" >/dev/null; [ "$?" = 1 ] || fail "a ButtonStyle declared in a view file passed"
rm -rf "$dir"

dir=$(tree ownstylefile ButtonStyles.swift 'struct WorkbenchButtonStyle: ButtonStyle { func makeBody(configuration: Configuration) -> some View { configuration.label } }')
run "$dir" >/dev/null; [ "$?" = 0 ] || fail "the style file's own ButtonStyle was refused"
rm -rf "$dir"

dir=$(tree iconlink Good.swift 'struct A: View { var body: some View { Button("x") {}.buttonStyle(.plain); Button("y") {}.buttonStyle(.link) } }')
run "$dir" >/dev/null; [ "$?" = 0 ] || fail ".plain or .link was refused"
rm -rf "$dir"

dir=$(tree sheet Bad.swift 'struct A: View { var body: some View { Text("x").sheet(isPresented: $on) { Text("y") } } }')
out=$(run "$dir"); code=$?
[ "$code" = 1 ] || fail "a .sheet( in a view passed ($code)"
echo "$out" | grep -q 'use .modal(' || fail "the message does not say what to use: $out"
rm -rf "$dir"

for call in '.popover(isPresented: $on) { Text("y") }' '.alert("x", isPresented: $on) { }' '.confirmationDialog("x", isPresented: $on) { }' \
    '.fullScreenCover(isPresented: $on) { Text("y") }' '.overlay { Color.black.opacity(0.1) }' '.accessibilityAddTraits(.isModal)' '.card(.popover)'; do
  dir=$(tree call Bad.swift "struct A: View { var body: some View { Text(\"x\")$call } }")
  run "$dir" >/dev/null; [ "$?" = 1 ] || fail "$call in a view passed"
  rm -rf "$dir"
done

dir=$(tree modalfile Modal.swift 'struct A: View { var body: some View { Text("x").card(.popover).accessibilityAddTraits(.isModal) } }')
run "$dir" >/dev/null; [ "$?" = 0 ] || fail "the component's own overlay pieces were refused"
rm -rf "$dir"

dir=$(tree legacy FeedScreen.swift 'struct A: View { var body: some View { Text("x").sheet(isPresented: $on) { Text("y") } } }')
run "$dir" >/dev/null; [ "$?" = 0 ] || fail "a file on the legacy list was refused"
rm -rf "$dir"

dir=$(tree usemodal Good.swift '// .sheet( is the old way
struct A: View { var body: some View { Text("x").modal("T", isPresented: $on, size: .small) { Text("y") } } }')
run "$dir" >/dev/null; [ "$?" = 0 ] || fail ".modal( or a comment was refused"
rm -rf "$dir"

# and the real tree is clean
sh "$script" >/dev/null 2>&1 || fail "the repository itself fails the check"
[ "$status" = 0 ] && echo "banned-apis check: ok"
exit $status
