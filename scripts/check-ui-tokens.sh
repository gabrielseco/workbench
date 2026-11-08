#!/bin/sh
# UI tokens: a view takes its radius, type, spacing and shapes from a component or a token, never from a number or a font written in the view.
# Any of the literals below in Sources/WorkbenchApp outside the component files fails (AGENTS.md, Conventions; docs/UI-AUDIT.md):
#   radius    cornerRadius: <number>        -> Radius.* or a component (Card, Callout, ...)
#   fontsize  .font(.system(size: <n>       -> a TextStyle
#   textstyle any .font(                    -> .textStyle(<TextStyle>, <TextTone>) or a TextRole
#   padding   .padding(<number>) and spacing: <number> -> Space.*
#   capsule   Capsule()                     -> Pill
#   spacer    Spacer(minLength: <number>)   -> Space.*
#   frame     .frame(width: <n>) and .frame(height: <n>), in any position of the call -> a named size (min and max are not checked)
# The component files (COMPONENTS) are where the scales and the components hold the numbers. A new component file is added there, in the PR
# that adds it. The text is read, not parsed: a `//` that starts a comment is dropped, and each file's lines are joined, so a literal split
# across lines is found. Known limit: a string literal holding ` //` hides what follows it on that line.
set -u
cd "${UI_TOKENS_ROOT:-$(dirname "$0")/..}"
COMPONENTS='FocusRing.swift SegmentedSwitch.swift InboxRowView.swift CountBadge.swift ProjectTile.swift ProjectRail.swift Theme.swift ButtonStyles.swift PlaceholderTextEditor.swift Card.swift Callout.swift Pill.swift SectionLabel.swift IconRow.swift Thumbnail.swift TextRole.swift TextStyle.swift ActionButton.swift Space.swift Modal.swift Outcome.swift Busy.swift IconButton.swift FormControls.swift Marks.swift CodeBox.swift EmptyNote.swift'
exempt=$(echo "$COMPONENTS" | sed 's/ /|/g; s/\./\\./g')
status=0

check() { # name pattern what-to-use
    hits=$(find Sources/WorkbenchApp -name '*.swift' 2>/dev/null | sort | grep -Ev "/($exempt)\$" | while read -r f; do
        found=$(sed -E 's#(^|[[:space:]])//.*$#\1#' "$f" | tr '\n' ' ' | grep -oE "$2" | head -3)
        [ -n "$found" ] && printf '%s\n' "$found" | sed "s#^#$f: #"
    done)
    if [ -n "$hits" ]; then
        echo "$hits"
        echo "error: $1 literal in Sources/WorkbenchApp: use $3. A value the scale lacks is a new case in the component file, decided once" >&2
        echo "       (AGENTS.md, Conventions; docs/UI-AUDIT.md)." >&2
        status=1
    fi
}

check radius 'cornerRadius:[[:space:]]*[0-9]' 'a Radius token or a component (Card, Callout, Pill, ...)'
check fontsize '\.font\([[:space:]]*\.system\([[:space:]]*size:[[:space:]]*[0-9]' 'a TextStyle'
check textstyle '\.font\(' '.textStyle(<TextStyle>, <TextTone>) or a TextRole, never .font('
check padding '(^|[^A-Za-z])padding\([^)]*[0-9]|[^a-zA-Z]spacing:[^,)]*[1-9]' 'a step of Space (.padding(.horizontal, Space.m), VStack(spacing: Space.s))'
check capsule 'Capsule\(\)' 'a Pill'
check spacer 'Spacer\(minLength:[[:space:]]*[0-9]' 'a step of Space (Spacer(minLength: Space.s))'
check frame '\.frame\([^)]*(width|height):[[:space:]]*[0-9]' 'a named size (a component, a static let, ModalSize, ModalBodyHeight, SymbolColumn, DotSize)'
exit $status
