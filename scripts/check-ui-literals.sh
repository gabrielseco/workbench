#!/bin/sh
# The UI ratchet: hand-written styling in a view is a component that was not made. A view takes its radius, type, fill and spacing from a
# component or a Theme token; the literals counted below are what is still written out by hand (docs/UI-AUDIT.md lists them).
# The count of each may not go up: a PR that adds one fails, and a PR that removes some lowers scripts/ui-literals.baseline in the same
# change (`scripts/check-ui-literals.sh --update`), so it cannot creep back. Files that ARE the components are not counted.
# Known limit: it reads text, not Swift, so a string literal holding ` //` hides what follows it on that line from the count. Rare in view
# code; a real fix is a parser, and not worth one for a ratchet.
# A new component file is added to COMPONENTS below, in the PR that adds it.
set -u
cd "${UI_LITERALS_ROOT:-$(dirname "$0")/..}"
baseline=${UI_LITERALS_BASELINE:-scripts/ui-literals.baseline}
COMPONENTS='Theme.swift ButtonStyles.swift PlaceholderTextEditor.swift Card.swift Callout.swift Pill.swift SectionLabel.swift IconRow.swift'

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
    echo "padding $(count padding '\.padding\([[:space:]]*(\.[a-z]+,[[:space:]]*)?-?[[:space:]]*[0-9][0-9.]*[[:space:]]*\)')"
}

# A baseline is the four names, each once, with a whole number. A comparison on anything else errors out and reads as "not greater", which
# would pass: so a malformed one fails here first.
valid() { # text
    printf '%s\n' "$1" | awk '
        NF != 2 || $2 !~ /^[0-9]+$/ || !($1 in want) || ($1 in seen) { bad = 1 }
        { seen[$1] = 1 }
        BEGIN { want["radius"]; want["fontsize"]; want["capsule"]; want["padding"] }
        END { for (k in want) if (!(k in seen)) bad = 1; exit bad }'
}

# --against <ref>: the baseline may not be higher than the one on that ref (the PR's base). Without it a PR could add a literal and
# raise the baseline in the same change, which is the one way past the count.
if [ "${1:-}" = "--against" ]; then
    ref=${2:?usage: check-ui-literals.sh --against <ref>}
    # A ref that does not exist is an error, not "no baseline": a shallow checkout without the base branch must not pass this.
    git rev-parse --verify -q "$ref^{commit}" >/dev/null || { echo "error: $ref is not a commit here; fetch the base branch first" >&2; exit 1; }
    old=$(git show "$ref:scripts/ui-literals.baseline" 2>/dev/null) || { echo "note: $ref has no UI-literals baseline yet; nothing to compare"; exit 0; }
    valid "$(cat "$baseline")" || { echo "error: $baseline is malformed (four names, each with a whole number)" >&2; exit 1; }
    valid "$old" || { echo "error: the baseline on $ref is malformed" >&2; exit 1; }
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

valid "$(cat "$baseline")" || { echo "error: $baseline is malformed (four names, each with a whole number)" >&2; exit 1; }
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
