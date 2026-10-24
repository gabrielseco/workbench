#!/usr/bin/env bash
# What each test costs: a serial `swift test` (a parallel run's times include the wait for a ProcessGate permit),
# then the slowest suites and tests. Takes about 16 minutes, so run it by hand or from the manual CI job.
#
#   scripts/test-profile.sh [out-dir] [-- <swift test args>]
#
# Writes test.log, timings.json and timings.md to out-dir (default .workbench/profile) and prints timings.md.
set -euo pipefail

cd "$(dirname "$0")/.."
out=.workbench/profile
if [ $# -gt 0 ] && [ "$1" != "--" ]; then out=$1; shift; fi
[ "${1:-}" = "--" ] && shift
mkdir -p "$out"

status=0
swift test --no-parallel "$@" 2>&1 | tee "$out/test.log" || status=$?
python3 scripts/test-timings.py "$out/test.log" --serial --json "$out/timings.json" --markdown "$out/timings.md" || true
[ -f "$out/timings.md" ] && cat "$out/timings.md"
exit "$status"
