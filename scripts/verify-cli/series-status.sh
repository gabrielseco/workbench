#!/bin/bash
# verify-cli scenario for `series status` (P27 task 3a), on this repository. No turn is run, so it costs nothing.
#   bash scripts/verify-cli/series-status.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/series-status.sh   (the same, on a branch that contains origin/main)
# A throwaway series of two steps (step 2 waits for step 1) is written under .workbench/series/ and read with `series status`:
# step 1 is ready and step 2 waits for it; once the log says step 1 started a thread that does not exist, step 1 is running and
# nothing is ready; once that thread is a discarded one (its log ends without a pull request), the series is STOPPED at step 1 and
# nothing starts. The thread folder is a hand-written log (no run, no cost). Exit 0 only when every step passed, 1 when one failed,
# 2 when it refused to start. VERIFY_CLI_SABOTAGE=1 leaves the log without the discard, so the "STOPPED" step must FAIL.
# The series folder and the thread folder are removed at the end. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

NAME=verify-cli-series-status
DIR="$ROOT/.workbench/series/$NAME"
THREAD=g-2026-01-01-verify-series-status
TDIR="$ROOT/.workbench/threads/$THREAD"
rm -rf "$DIR" "$TDIR"
mkdir -p "$DIR"
trap 'rm -rf "$DIR" "$TDIR"' EXIT

cat >"$DIR/p1.md" <<'GOAL'
---
title: Series status scenario goal
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

A throwaway goal file; no thread is made from it.

## Criteria

- [c1] Nothing changes.
  - proof: no run

## Out of scope

- Everything.
GOAL
printf '## 1\nproject: %s\ngoal: p1.md\n\n## 2\nproject: %s\ngoal: p1.md\nafter: 1\n' "$ROOT" "$ROOT" >"$DIR/series.md"

RC=0
sx() {
    echo "workbench $*" >>"$SCRATCH/commands"
    with_timeout "$T_WB" "$WB" "$@" >"$SCRATCH/o" 2>"$SCRATCH/e"
    RC=$?
}
has() { grep -q -- "$1" "$SCRATCH/o"; }

sx series status "$NAME"
check "nothing started: step 1 pending, step 2 waits, step 1 ready" "exit $RC: $(head -c 400 "$SCRATCH/o")" \
    bash -c '[ "$1" = 0 ] && grep -q "^1. pending" "$2" && grep -q "^2. pending, waits for step 1" "$2" && grep -q "ready to start: step 1$" "$2"' _ "$RC" "$SCRATCH/o"

# The driver's record of step 1, and a thread whose log has only its creation: the thread is working.
printf '{"at":"2026-01-01T00:00:00Z","step":1,"thread":"%s"}\n' "$THREAD" >"$DIR/steps.jsonl"
mkdir -p "$TDIR"
printf '{"v":1,"seq":1,"ts":"2026-01-01T00:00:00.000Z","turn":0,"kind":"thread.created","data":{"base":"main"}}\n' >"$TDIR/events.jsonl"
sx series status "$NAME"
check "step 1 running: nothing ready" "exit $RC: $(head -c 400 "$SCRATCH/o")" \
    bash -c '[ "$1" = 0 ] && grep -q "^1. running  '"$THREAD"'" "$2" && grep -q "nothing to start now" "$2"' _ "$RC" "$SCRATCH/o"

# The thread ends without a pull request: the series stops and says where.
if [ "${VERIFY_CLI_SABOTAGE:-}" != 1 ]; then
    printf '{"v":1,"seq":2,"ts":"2026-01-01T00:00:01.000Z","turn":0,"kind":"review.decision","data":{"decision":"discarded","by":"user"}}\n' >>"$TDIR/events.jsonl"
fi
sx series status "$NAME"
check "step 1 discarded: STOPPED, nothing starts" "exit $RC: $(head -c 400 "$SCRATCH/o")" \
    bash -c '[ "$1" = 0 ] && grep -q "^1. STOPPED" "$2" && grep -q "stopped at step 1" "$2" && ! grep -q "ready to start" "$2"' _ "$RC" "$SCRATCH/o"

sx series status no-such-series
check "no such series: exit 7" "exit $RC: $(head -c 300 "$SCRATCH/e")" test "$RC" = 7
finish
