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
open(path, "a").write(json.dumps({"seq": last["seq"] + 1, "ts": ts, "turn": 0, "kind": kind, "data": data}, separators=(",", ":")) + "\n")
PY
}

append review.decision '{"decision":"accepted"}'
append pr.opened '{"url":"https://example.test/pull/7","number":7,"branch":"x","base":"main","head_sha":"abc123"}'
status_before=$(wb "$T_WB" status "$ID" --json | py "print(d['pull_request']['number'] if d.get('pull_request') else '')" 2>/dev/null)
[ "$SABOTAGE" = 1 ] || append pr.closed '{"number":7,"head_sha":"abc123"}'

wb "$T_WB" log "$ID" >"$SCRATCH/log.out" 2>&1
check "log: names the closed pull request" "$(tail -3 "$SCRATCH/log.out")" \
    grep -q 'pull request #7 closed without merging' "$SCRATCH/log.out"
wb "$T_WB" status "$ID" >"$SCRATCH/status.out" 2>&1
check "status: says closed from the log alone" "$(head -c 400 "$SCRATCH/status.out")" grep -qi 'closed' "$SCRATCH/status.out"
check "status: the pull request is #7 (before the close was written too)" "was '$status_before'" test "$status_before" = 7

# A pull request opened afterwards is not the closed one: the close does not carry over.
append pr.opened '{"url":"https://example.test/pull/8","number":8,"branch":"x","base":"main","head_sha":"def456"}'
wb "$T_WB" log "$ID" >"$SCRATCH/log2.out" 2>&1
wb "$T_WB" status "$ID" >"$SCRATCH/status2.out" 2>&1
check "status: a later pull request is not shown as closed" "$(head -c 400 "$SCRATCH/status2.out")" \
    bash -c '! grep -qi "closed" "$1"' _ "$SCRATCH/status2.out"

wb "$T_WB" abandon "$ID" >/dev/null 2>&1
ended=$(wb "$T_WB" status "$ID" --json | py "print(d['ended'])")
check "abandon ends the thread" "status says ended: $ended" test "$ended" = abandoned
finish
