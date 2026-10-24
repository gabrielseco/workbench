#!/usr/bin/env bash
# Checks scripts/test-timings.py on a small log: the run summary line is not a test, the heavy share is right,
# a log without results is an error. Quick; no swift involved.
set -euo pipefail
cd "$(dirname "$0")/.."
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

cat > "$dir/log" <<'L'
✔ Test fast() passed after 0.100 seconds.
✔ Test slow() passed after 3.000 seconds.
✘ Test broken() failed after 1.000 seconds.
✔ Suite S passed after 4.100 seconds.
✔ Test run with 3 tests in 1 suite passed after 4.100 seconds.
L
python3 scripts/test-timings.py "$dir/log" --serial --json "$dir/j.json" > "$dir/out.md"
grep -q "3 tests in 1 suites, 1 failed" "$dir/out.md" || { echo "FAIL: the run summary line was counted"; exit 1; }
grep -q "1 tests over 1 s hold 73% of the 4 s" "$dir/out.md" || { echo "FAIL: heavy share"; cat "$dir/out.md"; exit 1; }
grep -q "cost of that test alone" "$dir/out.md" || { echo "FAIL: --serial note"; exit 1; }
python3 scripts/test-timings.py "$dir/log" > "$dir/par.md"
grep -q "ProcessGate permit" "$dir/par.md" || { echo "FAIL: parallel note"; exit 1; }
echo "nothing" > "$dir/empty"
if python3 scripts/test-timings.py "$dir/empty" >/dev/null 2>&1; then echo "FAIL: a log without results must fail"; exit 1; fi
echo "test-timings: ok"
