#!/bin/bash
# verify-cli scenario for `pr.closed` (a pull request GitHub said was closed without merging, written to the thread's log by the app's
# reads), on this repository. No turn is run, so it costs nothing: the events the app writes are appended by hand, the way the app's
# writer would, to a throwaway thread's log, and `workbench log` and `status` must say it from the log alone.
#   bash scripts/verify-cli/pr-closed.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/pr-closed.sh   (the same, on a branch that contains origin/main)
# Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start (nothing changed). VERIFY_CLI_SABOTAGE=1 leaves
# `pr.closed` out of the log, so the steps that expect "closed without merging" must FAIL. The frame and the other switches are in
# lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

GOAL_SRC="$SCRATCH/goal.md"
cat >"$GOAL_SRC" <<'GOAL'
---
id: verify-cli-pr-closed
title: verify-cli pr.closed scenario
base: origin/main
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

This is a throwaway thread that tests how `pr.closed` is shown; no turn is run and its branch never exists.

## Criteria

- [c1] The log says the pull request was closed.
  - proof: `workbench log` names it

## Out of scope

- Everything.
GOAL

start_thread verify-cli-pr-closed "$GOAL_SRC"
LOG="$THREAD_DIR/events.jsonl"

# Appends one event the way the writer does: the next seq, turn 0.
append() {
    python3 -I - "$LOG" "$1" "$2" <<'PY'
import json, sys, datetime
path, kind, data = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
last = [json.loads(l) for l in open(path) if l.strip()][-1]
ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
open(path, "a").write(json.dumps({"v": 1, "seq": last["seq"] + 1, "ts": ts, "turn": 0, "kind": kind, "data": data}, separators=(",", ":")) + "\n")
PY
}

# Accepting ends the thread (it is no longer active, so it holds no slot), and a thread that shipped has a pull request in its log.
append review.decision '{"decision":"accepted"}'
append pr.opened '{"url":"https://example.test/pull/7","number":7,"branch":"x","base":"main","head_sha":"abc123"}'
ship_step() { wb "$T_WB" status "$ID" --json | py "print(next(s['sublabel'] for s in d['spine'] if s['step'] == 'ship'))"; }
before=$(ship_step)
check "status: a shipped pull request nobody has read is open" "ship says '$before'" test "$before" = "PR #7 open"
[ "$SABOTAGE" = 1 ] || append pr.closed '{"number":7,"head_sha":"abc123"}'

wb "$T_WB" log "$ID" >"$SCRATCH/log.out" 2>&1
check "log: names the closed pull request" "$(tail -3 "$SCRATCH/log.out")" \
    grep -q 'pull request #7 closed without merging' "$SCRATCH/log.out"
after=$(ship_step)
check "status: the ship step says closed, from the log alone" "ship says '$after'" test "$after" = "PR #7 closed"

# A pull request opened afterwards is not the closed one: the close does not carry over.
append pr.opened '{"url":"https://example.test/pull/8","number":8,"branch":"x","base":"main","head_sha":"def456"}'
later=$(ship_step)
check "status: a later pull request is not shown as closed" "ship says '$later'" test "$later" = "PR #8 open"

ended=$(wb "$T_WB" status "$ID" --json | py "print(d['ended'])")
check "the thread is over, so it holds no slot" "status says ended: $ended" test "$ended" = accepted
finish
