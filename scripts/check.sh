#!/bin/sh
# The single command that says whether the repository is healthy: the CI "Banned process APIs", "SwiftLint",
# "Build" and "Test" steps (plus the leftover check) (.github/workflows/ci.yml), in that order. Stops at the first step that fails.
# The soak test is not run here; CI keeps it as its own step.
set -u
cd "$(dirname "$0")/.." || exit 1

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
step 'SwiftLint' swiftlint lint --quiet
step 'Build' swift build
step 'Test' swift test
step 'Test leftovers' scripts/check-test-leftovers.sh
echo "==> All checks passed"
