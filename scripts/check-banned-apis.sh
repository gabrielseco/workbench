#!/bin/sh
# Process-layer lessons (docs/plan/P1-runner.md): these calls caused the hangs we are not repeating.
# Fails if any appear in Sources/. A deliberate use needs a design discussion, not an exception here.
set -u
cd "$(dirname "$0")/.."
status=0
for pattern in 'waitUntilExit' 'readDataToEndOfFile'; do
    if grep -rn --include='*.swift' "$pattern" Sources; then
        echo "error: banned API '$pattern' used in Sources/" >&2
        status=1
    fi
done
exit $status
