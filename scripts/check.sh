#!/bin/sh
# The single command that says whether the repository is healthy: the CI "Banned process APIs", "Build"
# and "Test" steps (.github/workflows/ci.yml), in that order. Stops at the first step that fails.
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
step 'Build' swift build
step 'Test' swift test
echo "==> All checks passed"
