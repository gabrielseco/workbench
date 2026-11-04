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

count() { # name pattern
    grep -rnE --include='*.swift' "$2" Sources/WorkbenchApp 2>/dev/null | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*//' \
        | grep -Ev "^Sources/WorkbenchApp/($(echo "$COMPONENTS" | sed 's/ /|/g' | sed 's/\./\\./g')):" | wc -l | tr -d ' '
}
current() {
    echo "radius $(count radius 'cornerRadius: [0-9]')"
    echo "fontsize $(count fontsize '\.font\(\.system\(size:')"
    echo "capsule $(count capsule 'Capsule\(\)')"
    echo "padding $(count padding '\.padding\([^)]*[0-9]')"
}

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
