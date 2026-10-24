#!/usr/bin/env bash
# What each test costs: a serial `swift test` (a parallel run's times include the wait for a ProcessGate permit),
# then the slowest suites and tests. Takes about 16 minutes, so run it by hand or from the manual CI job.
#
#   scripts/test-profile.sh [out-dir] [-- <swift test args>]
#
# Writes test.log, timings.json and timings.md to out-dir (default .workbench/profile) and prints timings.md.
# Exit status: the tests' if they failed, else 1 when the report could not be made, else 0.
set -uo pipefail

cd "$(dirname "$0")/.."
out=.workbench/profile
if [ $# -gt 0 ] && [ "$1" != "--" ]; then out=$1; shift; fi
[ "${1:-}" = "--" ] && shift
mkdir -p "$out"
# A report left by an earlier run must never be shown as this run's.
rm -f "$out/test.log" "$out/timings.json" "$out/timings.md"

swift test --no-parallel "$@" 2>&1 | tee "$out/test.log"
tests=${PIPESTATUS[0]}

report=0
python3 scripts/test-timings.py "$out/test.log" --serial --json "$out/timings.json" --markdown "$out/timings.md" || report=$?
[ "$report" -eq 0 ] && cat "$out/timings.md"

if [ "$tests" -ne 0 ]; then exit "$tests"; fi
exit "$report"
