#!/bin/sh
# Process-layer lessons (docs/plan/P1-runner.md): these calls caused the hangs we are not repeating.
# Foundation's Process is banned too: children start through Spawner only (rule 8).
# Fails if any appear in code under Sources/. Comments may name them. A deliberate use needs a design
# discussion, not an exception here.
set -u
cd "$(dirname "$0")/.."
status=0
for pattern in 'waitUntilExit' 'readDataToEndOfFile' 'Process()'; do
    hits=$(grep -rnF --include='*.swift' "$pattern" Sources | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*//')
    if [ -n "$hits" ]; then
        echo "$hits"
        echo "error: banned API '$pattern' used in Sources/" >&2
        status=1
    fi
done
exit $status
