#!/bin/sh
# check.sh for a thread: the same steps, on what the branch changed. Lints the changed Swift files and runs the
# test suites that cover them (AGENTS.md, "Shipping a change"). CI still runs the full scripts/check.sh.
#   scripts/check-changed.sh [--plan] [--quick] [<base>]    base defaults to origin/main
# --plan prints what would run and runs nothing.
# --quick runs only the suites named after the changed files (no match by mention).
# More than CHECK_CHANGED_MAX_SUITES (default 15) suites would run: only the named ones do, CI runs the rest.
# Changed = committed since <base>, plus uncommitted and untracked, so it works before and after a commit.
set -u
cd "$(dirname "$0")/.." || exit 1

plan=0
quick=0
while [ "${1:-}" = "--plan" ] || [ "${1:-}" = "--quick" ]; do
    [ "$1" = "--plan" ] && plan=1
    [ "$1" = "--quick" ] && quick=1
    shift
done
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
# Git quotes paths with a tab, newline or quote even with quotepath off, so a leading quote counts too.
if echo "$changed" | grep -Eq '^"|[[:space:]]'; then
    echo "==> A changed path contains whitespace or needs quoting: full check"
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

# A source file maps to the tests named after it. Only when none is named after it, the tests that mention its name
# are used (a "grep match"), and not for the core folders everything uses: there that would select nearly every suite.
wide_core='^Sources/WorkbenchCore/(Git|EventLog|Config|Process)/'
max_suites=${CHECK_CHANGED_MAX_SUITES:-15}
test_files=""     # changed test files and tests named after a changed source: always run
grep_files=""     # tests that only mention a changed source: run unless there are too many or --quick
grep_report=""
unmapped=""
for f in $swift_changed; do
    case $f in
    Tests/*) [ -f "$f" ] && test_files="$test_files $f" ;;
    Sources/*)
        base_name=$(basename "$f" .swift)
        # Foo.swift, Foo+Bar.swift (Bar), CommandsBar.swift (Bar): tests are named after the part that says what it is.
        names="$base_name ${base_name#*+} ${base_name#Commands}"
        found=""
        for name in $names; do
            found=$(ls Tests/*/"$name"*.swift 2>/dev/null)
            [ -n "$found" ] && break
        done
        if [ -n "$found" ]; then test_files="$test_files $found"; continue; fi
        if [ "$quick" = 0 ] && ! echo "$f" | grep -Eq "$wide_core"; then
            for name in $names; do
                found=$(grep -rlw --include='*.swift' "$name" Tests 2>/dev/null)
                [ -n "$found" ] && break
            done
        fi
        if [ -n "$found" ]; then
            grep_files="$grep_files $found"
            grep_report="$grep_report $f($(echo "$found" | wc -l | tr -d ' ') files)"
        else
            unmapped="$unmapped $f"
        fi
        ;;
    esac
done

suites_of() {
    for t in $(echo "$@" | tr ' ' '\n' | sort -u); do suites_in "$t"; done | sort -u | grep . | paste -sd '|' -
}
count_of() { echo "$1" | tr '|' '\n' | grep -c .; }

filter=$(suites_of $test_files $grep_files)
if [ "$(count_of "$filter")" -gt "$max_suites" ]; then
    # Too wide to be fast feedback: keep the tests named after the change, say what was left out, leave the rest to CI.
    echo "==> $(count_of "$filter") suites match, over the limit of $max_suites; running the named ones only." \
        "Left to CI, matched through:$grep_report"
    filter=$(suites_of $test_files)
fi

# With no suite to filter on, still compile the test targets when a test file changed (a helper has no @Suite).
build="swift build"
if echo "$swift_changed" | grep -q '^Tests/'; then build="swift build --build-tests"; fi

# Lint only what still exists.
swift_files=$(echo "$swift_changed" | while read -r f; do [ -f "$f" ] && echo "$f"; done)
if [ -n "$swift_files" ]; then
    echo "==> Lint: $(echo "$swift_files" | wc -l | tr -d ' ') changed Swift file(s)"
else
    echo "==> Lint: nothing (the changed Swift files were deleted)"
fi
[ -n "$unmapped" ] && echo "==> No tests found for:$unmapped (built, not tested)"
suite_count=$(echo "$filter" | tr '|' '\n' | grep -c .)
if [ -n "$filter" ]; then echo "==> Test suites ($suite_count): $filter"; else echo "==> No test suites mapped"; fi
if [ "$plan" = 1 ]; then
    echo "run: scripts/check-banned-apis.sh"
    [ -n "$swift_files" ] && echo "run: swiftlint lint --quiet <changed files>"
    if [ -n "$filter" ]; then
        echo "run: swift build --build-tests"
        echo "run: swift test --skip-build --filter \"$filter\""
    else
        echo "run: $build"
    fi
    exit 0
fi

step() {
    name=$1
    shift
    echo "==> $name"
    started=$(date +%s)
    "$@"
    code=$?
    took=$(($(date +%s) - started))
    timings="$timings
    $name: ${took}s"
    if [ $code -ne 0 ]; then
        echo "error: step '$name' failed (exit $code) after ${took}s" >&2
        echo "==> Timing, $(($(date +%s) - total_started))s so far (suites: $suite_count):$timings" >&2
        exit 1
    fi
}

timings=""
total_started=$(date +%s)

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
    # Built apart from the run, so the timing says what a build costs and what the tests cost.
    step 'Build tests' swift build --build-tests
    step 'Test' swift test --skip-build --filter "$filter"
else
    # shellcheck disable=SC2086  # "$build" is a fixed command with flags
    step 'Build' $build
fi
echo "==> Timing, $(($(date +%s) - total_started))s in all (suites: $suite_count):$timings"
echo "==> Changed-file checks passed (CI runs the full scripts/check.sh)"
