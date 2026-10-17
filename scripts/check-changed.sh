#!/bin/sh
# check.sh for a thread: the same steps, on what the branch changed. Lints the changed Swift files and runs the
# test suites that cover them (AGENTS.md, "Shipping a change"). CI still runs the full scripts/check.sh.
#   scripts/check-changed.sh [--plan] [<base>]    base defaults to origin/main
# --plan prints what would run and runs nothing.
# Changed = committed since <base>, plus uncommitted and untracked, so it works before and after a commit.
set -u
cd "$(dirname "$0")/.." || exit 1

plan=0
if [ "${1:-}" = "--plan" ]; then
    plan=1
    shift
fi
base=${1:-origin/main}

changed=$({
    git diff --name-only "$base"...HEAD
    git diff --name-only HEAD
    git ls-files --others --exclude-standard
} 2>/dev/null | sort -u | while read -r f; do [ -f "$f" ] && echo "$f"; done)

if [ -z "$changed" ]; then
    echo "==> Nothing changed against $base"
    exit 0
fi

# A change to the package or the check scripts can affect everything: do the full check.
if echo "$changed" | grep -Eq '^(Package\.swift|Package\.resolved|\.swiftlint\.yml|scripts/check\.sh|scripts/check-banned-apis\.sh|\.github/workflows/)'; then
    echo "==> Package, lint config, check scripts or CI changed: full check"
    [ "$plan" = 1 ] && { echo "run: scripts/check.sh"; exit 0; }
    exec scripts/check.sh
fi

swift_files=$(echo "$changed" | grep '\.swift$')
if [ -z "$swift_files" ]; then
    echo "==> No Swift files changed against $base: nothing to lint or test"
    exit 0
fi

# Suites named in a test file: `@Suite struct Foo` on one line or the attribute on the line above.
suites_in() {
    awk '
        /@Suite/ { want = 1 }
        match($0, /(struct|class|actor) [A-Za-z0-9_]+/) {
            if (want) { split(substr($0, RSTART, RLENGTH), p, " "); print p[2]; want = 0 }
        }
    ' "$1"
}

test_files=""
unmapped=""
for f in $swift_files; do
    case $f in
    Tests/*) test_files="$test_files $f" ;;
    Sources/*)
        base_name=$(basename "$f" .swift)
        # Foo.swift, Foo+Bar.swift (Bar), CommandsBar.swift (Bar): tests are named after the part that says what it is.
        found=""
        for name in "$base_name" "${base_name#*+}" "${base_name#Commands}"; do
            [ -z "$name" ] && continue
            found=$(ls Tests/*/"$name"*.swift 2>/dev/null)
            [ -z "$found" ] && found=$(grep -rlw --include='*.swift' "$name" Tests 2>/dev/null)
            [ -n "$found" ] && break
        done
        if [ -n "$found" ]; then test_files="$test_files $found"; else unmapped="$unmapped $f"; fi
        ;;
    esac
done

suites=""
for t in $(echo $test_files | tr ' ' '\n' | sort -u); do
    suites="$suites $(suites_in "$t")"
done
filter=$(echo $suites | tr ' ' '\n' | sort -u | grep . | paste -sd '|' -)

echo "==> Lint: $(echo "$swift_files" | wc -l | tr -d ' ') changed Swift file(s)"
[ -n "$unmapped" ] && echo "==> No tests found for:$unmapped (built, not tested)"
if [ -n "$filter" ]; then echo "==> Test suites: $filter"; else echo "==> No test suites mapped"; fi
if [ "$plan" = 1 ]; then
    echo "run: swiftlint lint --quiet <changed files>"
    if [ -n "$filter" ]; then echo "run: swift test --filter \"$filter\""; else echo "run: swift build"; fi
    exit 0
fi

step() {
    name=$1
    shift
    echo "==> $name"
    "$@"
    code=$?
    if [ $code -ne 0 ]; then
        echo "error: step '$name' failed (exit $code)" >&2
        exit 1
    fi
}

step 'Banned process APIs' scripts/check-banned-apis.sh
if ! command -v swiftlint >/dev/null 2>&1; then
    echo "error: SwiftLint is missing (brew install swiftlint)" >&2
    exit 1
fi
# shellcheck disable=SC2086  # one argument per changed file; Swift paths here have no spaces
step 'SwiftLint' swiftlint lint --quiet $swift_files
if [ -n "$filter" ]; then
    step 'Test' swift test --filter "$filter"
else
    step 'Build' swift build
fi
echo "==> Changed-file checks passed (CI runs the full scripts/check.sh)"
