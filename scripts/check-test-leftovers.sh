#!/usr/bin/env bash
# Run after `swift test` has exited: fails when the tests left a scratch root behind.
# Each test process makes $TMPDIR/wb-scratch-<pid>-<uuid> (Tests/WorkbenchCoreTests/Scratch.swift) and removes
# it at exit, so a root whose process is gone is a leak, from a test that bypassed Scratch's exit cleanup or from
# a run that was killed (the next run's first use sweeps those).
set -euo pipefail

tmp=${TMPDIR:-/tmp}
found=0
for dir in "$tmp"/wb-scratch-*; do
  [ -d "$dir" ] || continue
  pid=${dir##*/wb-scratch-}
  pid=${pid%%-*}
  if kill -0 "$pid" 2>/dev/null; then continue; fi # another test run is still going
  echo "leftover: $dir" >&2
  found=1
done
if [ "$found" -ne 0 ]; then
  echo "the tests left scratch directories behind: remove them, and find the test that made one outside Scratch" >&2
  exit 1
fi
echo "no scratch directories left behind"
