#!/bin/bash
# verify-cli scenario for the agent attempt records and the recovery of a killed judge or review (P9 PR 8), on a clone
# of this repository. No `claude` or `codex` is started, so it costs nothing.
#   bash scripts/verify-cli/agent-recovery.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/agent-recovery.sh   (the same, on a branch that contains origin/main)
# A thread whose log ends with a judge, a review round and two attempts that never ended (a killed process) is made by
# appending those events. `workbench log` must show the attempts as one line each, `abandon` (which recovers the log
# before anything else) must close the attempts, the judge and the round with an `interrupted` end that `log` marks as
# recovered, the round must still be in the log (it still counts toward the cap), and recovery must add those ends and the
# abandon decision and nothing else (a second recovery adding nothing is tested in AgentRecoveryTests).
# Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start (nothing changed).
# VERIFY_CLI_SABOTAGE=1 appends nothing that is open (every start is followed by its end), so the steps that expect a
# recovery (the synthetic ends, the recovered marks) must FAIL. The frame and the other switches are in lib.sh. Run by hand,
# not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the appended judge, round and attempts all end"

# A clone, so the project's own .workbench/config.toml and threads are never touched.
P="$SCRATCH/project"
g clone -q "$ROOT" "$P" || die "git clone failed"
BASE=verify-cli-base
git -C "$P" checkout -q -b "$BASE" || die "could not make the base branch in the clone"
echo "==> clone at $P, base $BASE"

RC=0
wbp() { # <out> args...: a workbench command in the clone, stdout and stderr together; sets RC
    local o=$1; shift
    echo "workbench $*   (in the clone)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    ( cd "$P" && with_timeout "$T_WB" "$WB" "$@" >"$o" 2>&1 )
    RC=$?
}
shown() { sed 's/^/    /' "$1" | head -${2:-12}; }

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0

cat >"$SCRATCH/goal.md" <<'GOAL'
---
id: verify-cli-recovery
title: verify-cli agent recovery scenario
base: verify-cli-base
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

A throwaway thread for the recovery of a killed judge and review round; nothing is run.

## Criteria

- [c1] Nothing runs.
  - proof: the log

## Out of scope

- Everything else.
GOAL
wbp "$SCRATCH/new.out" goal new verify-cli-recovery --base "$BASE" --from "$SCRATCH/goal.md"
ID=$(sed -n 's/^created //p' "$SCRATCH/new.out")
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id ($(head -3 "$SCRATCH/new.out"))"
wbp "$SCRATCH/approve.out" goal approve "$ID"
check "goal approved in the clone" "workbench goal approve exited $RC" test "$RC" = 0
LOG="$P/.workbench/threads/$ID/events.jsonl"

# --- 1. a log with a killed judge and round ---------------------------------------------------------------

python3 -I - "$LOG" "$SABOTAGE" <<'PY'
import json, sys, datetime
path, sabotage = sys.argv[1], sys.argv[2] == "1"
rows = [json.loads(l) for l in open(path) if l.strip()]
seq = rows[-1]["seq"]
def add(kind, turn, data):
    global seq
    seq += 1
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    with open(path, "a") as f:
        f.write(json.dumps({"v": 1, "seq": seq, "ts": ts, "turn": turn, "kind": kind, "data": data}) + "\n")
    return seq
add("judge.started", 0, {"argv": ["claude"], "provider": "claude", "model": None})
add("agent.attempt.started", 0, {"attempt": "a%d" % (seq + 1), "role": "judge", "provider": "claude", "model": None})
judge_attempt = "a%d" % seq
if sabotage:
    add("agent.attempt.ended", 0, {"attempt": judge_attempt, "outcome": "succeeded"})
    add("judge.ran", 0, {"ok": False, "reason": "done", "argv": ["claude"]})
add("pr_review.started", 0, {"round": 1, "pr": 0, "head_sha": "0" * 40, "argv": ["codex"], "provider": "codex", "model": None})
add("agent.attempt.started", 0, {"attempt": "a%d" % (seq + 1), "role": "review", "round": 1, "provider": "codex", "model": None})
review_attempt = "a%d" % seq
if sabotage:
    add("agent.attempt.ended", 0, {"attempt": review_attempt, "outcome": "succeeded"})
    add("pr_review.finished", 0, {"round": 1, "pr": 0, "head_sha": "0" * 40, "ok": False, "verdict": None, "reason": "done"})
PY
wbp "$SCRATCH/log1.out" log "$ID"
shown "$SCRATCH/log1.out" 12
check "log shows the attempts, one line each, with provider and model" "no attempt lines" bash -c \
    'grep -q "attempt a[0-9]*: judge on claude, default model" "$1" && grep -q "attempt a[0-9]*: review round 1 on codex, default model" "$1"' _ "$SCRATCH/log1.out"
before=$(grep -c . "$LOG")

# --- 2. recovery ------------------------------------------------------------------------------------------

wbp "$SCRATCH/abandon.out" abandon "$ID"
shown "$SCRATCH/abandon.out" 4
check "abandon recovers and ends the thread" "workbench abandon exited $RC" test "$RC" = 0
wbp "$SCRATCH/log2.out" log "$ID"
shown "$SCRATCH/log2.out" 40 | tail -12
check "the killed attempts end as recovered" "no 'interrupted (recovered)' lines" \
    bash -c '[ "$(grep -c "ended: interrupted (recovered)" "$1")" = 2 ]' _ "$SCRATCH/log2.out"
synth=$(python3 -I - "$LOG" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
j = [r for r in rows if r["kind"] == "judge.ran" and r["data"].get("synthetic")]
p = [r for r in rows if r["kind"] == "pr_review.finished" and r["data"].get("synthetic")]
ok = (len(j) == 1 and j[0]["data"]["reason"] == "interrupted" and j[0]["data"]["ok"] is False
      and len(p) == 1 and p[0]["data"]["reason"] == "interrupted" and p[0]["data"]["verdict"] is None
      and p[0]["data"]["round"] == 1)
print("yes" if ok else "no")
PY
)
check "the judge and the round get a synthetic interrupted end" "the log has no such judge.ran and pr_review.finished" test "$synth" = yes
check "the round is still in the log (it counts toward the cap)" "the pr_review.started is gone" \
    bash -c '[ "$(grep -c "\"pr_review.started\"" "$1")" = 1 ]' _ "$LOG"

# --- 3. recovery is idempotent and the log stays valid ----------------------------------------------------

after=$(grep -c . "$LOG")
wbp "$SCRATCH/log3.out" log "$ID" --json
check "the log is valid after recovery" "workbench log exited $RC" test "$RC" = 0
added=$(python3 -I - "$LOG" "$before" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()][int(sys.argv[2]):]
print(" ".join(sorted(r["kind"] for r in rows)))
PY
)
want="agent.attempt.ended agent.attempt.ended judge.ran pr_review.finished review.decision"
check "recovery wrote the ends and the decision, nothing else" "added: '$added'" test "$added" = "$want"
wbp "$SCRATCH/status.out" status "$ID"
check "status still works on the recovered thread" "workbench status exited $RC" test "$RC" = 0
finish
