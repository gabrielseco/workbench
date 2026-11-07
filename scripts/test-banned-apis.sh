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

dir=$(tree everyfile FeedRow.swift 'struct A: View { var body: some View { Text("x").sheet(isPresented: $on) { Text("y") } } }')
run "$dir" >/dev/null; [ "$?" = 1 ] || fail "a .sheet( in any view file passed: no file is exempt now"
rm -rf "$dir"

dir=$(tree usemodal Good.swift '// .sheet( is the old way
struct A: View { var body: some View { Text("x").modal("T", isPresented: $on, size: .small) { Text("y") } } }')
run "$dir" >/dev/null; [ "$?" = 0 ] || fail ".modal( or a comment was refused"
rm -rf "$dir"

for symbol in checkmark.circle.fill exclamationmark.circle.fill exclamationmark.triangle.fill xmark.octagon.fill questionmark.circle minus.circle.fill; do
  dir=$(tree symbol Bad.swift "struct A: View { var body: some View { Image(systemName: \"$symbol\") } }")
  out=$(run "$dir"); code=$?
  [ "$code" = 1 ] || fail "$symbol written in a view passed ($code)"
  echo "$out" | grep -q "use an Outcome" || fail "the message does not say what to use: $out"
  rm -rf "$dir"
done

dir=$(tree outcomefile Outcome.swift 'enum Outcome { var symbol: String { "checkmark.circle.fill" } }')
run "$dir" >/dev/null; [ "$?" = 0 ] || fail "the Outcome file's own symbols were refused"
rm -rf "$dir"

dir=$(tree useoutcome Good.swift 'struct A: View { var body: some View { StatusMark(.passed); Message(.error, "x"); Image(systemName: "circle") } }')
run "$dir" >/dev/null; [ "$?" = 0 ] || fail "StatusMark, Message or a state-less symbol was refused"
rm -rf "$dir"

dir=$(tree spinner Bad.swift 'struct A: View { var body: some View { ProgressView().controlSize(.small) } }')
out=$(run "$dir"); code=$?
[ "$code" = 1 ] || fail "a ProgressView() in a view passed ($code)"
echo "$out" | grep -q "use Spinner" || fail "the message does not say what to use: $out"
rm -rf "$dir"

dir=$(tree xmark Bad.swift 'struct A: View { var body: some View { Button {} label: { Image(systemName: "xmark") } } }')
run "$dir" >/dev/null; [ "$?" = 1 ] || fail "a hand-made close cross passed"
rm -rf "$dir"

dir=$(tree iconbutton Bad.swift 'struct A: View { var body: some View { Button {} label: { Image(systemName: "plus") }.iconButton() } }')
out=$(run "$dir"); code=$?
[ "$code" = 1 ] || fail "a .iconButton( in a view passed ($code)"
echo "$out" | grep -q "use IconButton.raised" || fail "the message does not say what to use: $out"
rm -rf "$dir"

for file in Busy.swift IconButton.swift; do
  dir=$(tree own $file 'struct A: View { var body: some View { ProgressView(); Image(systemName: "xmark") } }')
  [ "$file" = Busy.swift ] && { run "$dir" >/dev/null; [ "$?" = 1 ] || fail "Busy.swift may not hold an xmark"; } || { run "$dir" >/dev/null; [ "$?" = 1 ] || fail "IconButton.swift may not hold a ProgressView()"; }
  rm -rf "$dir"
done

dir=$(tree owncomponents Busy.swift 'struct Spinner: View { var body: some View { ProgressView().controlSize(.small) } }')
run "$dir" >/dev/null; [ "$?" = 0 ] || fail "Busy.swift's own ProgressView() was refused"
rm -rf "$dir"
dir=$(tree owniconbutton IconButton.swift 'struct IconButton: View { var body: some View { Button {} label: { Image(systemName: "xmark") }.iconButton() } }')
run "$dir" >/dev/null; [ "$?" = 0 ] || fail "IconButton.swift's own cross and .iconButton( were refused"
rm -rf "$dir"

dir=$(tree determinate Good.swift 'struct A: View { var body: some View { ProgressView(value: 0.5); Spinner(); IconButton.close("x") {} } }')
run "$dir" >/dev/null; [ "$?" = 0 ] || fail "a determinate ProgressView(value:), Spinner or IconButton.close was refused"
rm -rf "$dir"

for field in 'TextField("x", text: $t)' 'TextField("x", text: $t).textFieldStyle(.roundedBorder)'; do
  dir=$(tree field Bad.swift "struct A: View { var body: some View { $field } }")
  out=$(run "$dir"); code=$?
  [ "$code" = 1 ] || fail "$field in a view passed ($code)"
  echo "$out" | grep -q "use TextInput" || fail "the message does not say what to use: $out"
  rm -rf "$dir"
done
dir=$(tree ownfield FormControls.swift 'struct TextInput: View { var body: some View { TextField("x", text: $t).textFieldStyle(.roundedBorder) } }')
run "$dir" >/dev/null; [ "$?" = 0 ] || fail "FormControls.swift's own TextField( was refused"
rm -rf "$dir"
dir=$(tree otherfields Good.swift 'struct A: View { var body: some View { TextInput("x", text: $t); MarkdownTextField(text: $t); PlaceholderTextEditor(text: $t) } }')
run "$dir" >/dev/null; [ "$?" = 0 ] || fail "TextInput or another name ending in TextField( was refused"
rm -rf "$dir"

# and the real tree is clean
sh "$script" >/dev/null 2>&1 || fail "the repository itself fails the check"
[ "$status" = 0 ] && echo "banned-apis check: ok"
exit $status
