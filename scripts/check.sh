#!/bin/sh
# One command to tell whether the repository is healthy: the same steps as CI's "Banned process APIs",
# "Build" and "Test", in the same order, stopping at the first failure. The soak test is not part of it;
# CI runs that as its own step.
set -u
cd "$(dirname "$0")/.." || exit 1

step() {
    name=$1
    shift
    echo "==> $name"
    if ! "$@"; then
        echo "check failed: $name" >&2
        exit 1
    fi
}

step "Banned process APIs" scripts/check-banned-apis.sh
step "Build" swift build
step "Test" swift test
echo "check passed"
