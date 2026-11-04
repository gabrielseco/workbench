#!/bin/sh
# The UI ratchet: hand-written styling in a view is a component that was not made. A view takes its radius, type, fill and spacing from a
# component or a Theme token; the literals counted below are what is still written out by hand (docs/UI-AUDIT.md lists them).
# The count of each may not go up: a PR that adds one fails, and a PR that removes some lowers scripts/ui-literals.baseline in the same
# change (`scripts/check-ui-literals.sh --update`), so it cannot creep back. Files that ARE the components are not counted.
# A new component file is added to COMPONENTS below, in the PR that adds it.
set -u
cd "${UI_LITERALS_ROOT:-$(dirname "$0")/..}"
baseline=${UI_LITERALS_BASELINE:-scripts/ui-literals.baseline}
COMPONENTS='Theme.swift ButtonStyles.swift PlaceholderTextEditor.swift'

# Counted per occurrence on the whole file with its // comments dropped (a `//` that starts one, not the one in `https://`) and its lines joined, so `cornerRadius:12` and a `.padding(`
# whose number is on the next line count like the usual spelling. Only a number counts: a Theme token or a constant is the fix.
count() { # name pattern
    find Sources/WorkbenchApp -name '*.swift' 2>/dev/null | sort | grep -Ev "/($(echo "$COMPONENTS" | sed 's/ /|/g; s/\./\\./g'))\$" \
        | while read -r f; do sed -E 's#(^|[[:space:]])//.*$#\1#' "$f" | tr '\n' ' '; echo; done | grep -oE "$2" | wc -l | tr -d ' '
}
current() {
    echo "radius $(count radius 'cornerRadius:[[:space:]]*[0-9]')"
    echo "fontsize $(count fontsize '\.font\([[:space:]]*\.system\([[:space:]]*size:[[:space:]]*[0-9]')"
    echo "capsule $(count capsule 'Capsule\(\)')"
    echo "padding $(count padding '\.padding\([[:space:]]*(\.[a-z]+,[[:space:]]*)?[0-9][0-9.]*[[:space:]]*\)')"
}

if [ "${1:-}" = "--against" ]; then
    ref=${2:?usage: check-ui-literals.sh --against <ref>}
    old=$(git show "$ref:scripts/ui-literals.baseline" 2>/dev/null) || { echo "note: $ref has no UI-literals baseline yet; nothing to compare"; exit 0; }
    bad=0
    while read -r name was; do
        now=$(awk -v n="$name" '$1==n {print $2}' "$baseline"); now=${now:-0}
        if [ "$now" -gt "$was" ]; then
            echo "error: the baseline for $name went up from $was ($ref) to $now: a PR lowers it, never raises it" >&2
            bad=1
        fi
    done <<EOB
$old
EOB
    exit $bad
fi

if [ "${1:-}" = "--update" ]; then current > "$baseline"; echo "wrote $baseline"; exit 0; fi
[ -f "$baseline" ] || { echo "error: $baseline is missing; run scripts/check-ui-literals.sh --update" >&2; exit 1; }

status=0
current | while read -r name now; do
    was=$(awk -v n="$name" '$1==n {print $2}' "$baseline"); was=${was:-0}
    if [ "$now" -gt "$was" ]; then
        echo "error: $name literals in Sources/WorkbenchApp went from $was to $now. Take it from a component or a Theme token" >&2
        echo "       (Card, Callout, Pill, ButtonStyles…); a look that does not exist yet is a new component or a new case, not a copy." >&2
        echo "       See AGENTS.md, Conventions, and docs/UI-AUDIT.md." >&2
        echo fail > "${TMPDIR:-/tmp}/ui-literals.$$"
    elif [ "$now" -lt "$was" ]; then
        echo "error: $name literals went down from $was to $now: lower the baseline (scripts/check-ui-literals.sh --update) so it stays down" >&2
        echo fail > "${TMPDIR:-/tmp}/ui-literals.$$"
    fi
done
if [ -f "${TMPDIR:-/tmp}/ui-literals.$$" ]; then rm -f "${TMPDIR:-/tmp}/ui-literals.$$"; status=1; fi
exit $status
