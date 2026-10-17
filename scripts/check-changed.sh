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

if ! git rev-parse --verify -q "$base^{commit}" >/dev/null; then
    echo "error: base '$base' is not a commit here (git fetch origin main, or pass a base)" >&2
    exit 1
fi
committed=$(git -c core.quotepath=off diff --name-only "$base"...HEAD) || { echo "error: git diff against $base failed" >&2; exit 1; }
uncommitted=$(git -c core.quotepath=off diff --name-only HEAD) || { echo "error: git diff HEAD failed" >&2; exit 1; }
untracked=$(git -c core.quotepath=off ls-files --others --exclude-standard) || { echo "error: git ls-files failed" >&2; exit 1; }
# Deleted files stay in `changed`: they still decide what to check (a removed type can break what remains).
changed=$(printf '%s\n%s\n%s\n' "$committed" "$uncommitted" "$untracked" | grep . | sort -u)

if [ -z "$changed" ]; then
    echo "==> Nothing changed against $base"
    exit 0
fi

# The word-splitting below cannot carry a path with whitespace: do the full check rather than skip it.
if echo "$changed" | grep -q '[[:space:]]'; then
    echo "==> A changed path contains whitespace: full check"
    [ "$plan" = 1 ] && { echo "run: scripts/check.sh"; exit 0; }
    exec scripts/check.sh
fi

# A change to the package or the check scripts can affect everything: do the full check.
if echo "$changed" | grep -Eq '^(Package\.swift|Package\.resolved|\.swiftlint\.yml|scripts/check\.sh|scripts/check-changed\.sh|scripts/check-banned-apis\.sh|\.github/workflows/)'; then
    echo "==> Package, lint config, check scripts or CI changed: full check"
    [ "$plan" = 1 ] && { echo "run: scripts/check.sh"; exit 0; }
    exec scripts/check.sh
fi

swift_changed=$(echo "$changed" | grep '\.swift$')
if [ -z "$swift_changed" ]; then
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
for f in $swift_changed; do
    case $f in
    Tests/*) [ -f "$f" ] && test_files="$test_files $f" ;;
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

# Lint only what still exists.
swift_files=$(echo "$swift_changed" | while read -r f; do [ -f "$f" ] && echo "$f"; done)
if [ -n "$swift_files" ]; then
    echo "==> Lint: $(echo "$swift_files" | wc -l | tr -d ' ') changed Swift file(s)"
else
    echo "==> Lint: nothing (the changed Swift files were deleted)"
fi
[ -n "$unmapped" ] && echo "==> No tests found for:$unmapped (built, not tested)"
if [ -n "$filter" ]; then echo "==> Test suites: $filter"; else echo "==> No test suites mapped"; fi
if [ "$plan" = 1 ]; then
    echo "run: scripts/check-banned-apis.sh"
    [ -n "$swift_files" ] && echo "run: swiftlint lint --quiet <changed files>"
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
if [ -n "$swift_files" ]; then
    if ! command -v swiftlint >/dev/null 2>&1; then
        echo "error: SwiftLint is missing (brew install swiftlint)" >&2
        exit 1
    fi
    # shellcheck disable=SC2086  # one argument per changed file; whitespace in paths took the full-check branch above
    step 'SwiftLint' swiftlint lint --quiet $swift_files
fi
if [ -n "$filter" ]; then
    step 'Test' swift test --filter "$filter"
else
    step 'Build' swift build
fi
echo "==> Changed-file checks passed (CI runs the full scripts/check.sh)"
