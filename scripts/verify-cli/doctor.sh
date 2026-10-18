#!/bin/bash
# verify-cli scenario for `workbench doctor` after approve (P15 task 1), with the real `claude`, on this repository.
#   bash scripts/verify-cli/doctor.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/doctor.sh   (the same, on a branch that contains origin/main)
# Runs one throwaway thread. Doctor must pass with the goal approved and no turn run, and leave the thread alone
# (log, worktree, branch). Then a real turn is started in the background: doctor must be refused (exit 6, naming the
# thread) while it is live, and the turn is stopped; doctor must pass again after it. Costs at most the turn cap
# ($VERIFY_CLI_BUDGET_USD, default 0.50) and usually a few cents, because the turn is stopped early. Exit 0 only when
# every step passed, 1 when one failed, 2 when it refused to start (nothing changed). VERIFY_CLI_SABOTAGE=1 stops the
# turn before the live-runner doctor, so that step must FAIL. The frame and the other switches are in lib.sh. Run by
# hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

GOAL_SRC="$SCRATCH/goal.md"
cat >"$GOAL_SRC" <<'GOAL'
---
id: verify-cli-doctor
title: verify-cli doctor scenario
base: origin/main
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

This is a throwaway thread that tests `workbench doctor`; its branch is deleted afterwards. First read `README.md`,
`AGENTS.md` and `docs/plan/README.md` in full. Then create one new file, `scratch/doctor-probe.txt`, holding the
single line `doctor-probe`. Do not commit.

## Criteria

- [c1] `scratch/doctor-probe.txt` exists in the worktree with the line `doctor-probe`.
  - proof: the diff shows that one new file and nothing else

## Out of scope

- Any other file, and committing.
GOAL

start_thread verify-cli-doctor "$GOAL_SRC"

# What doctor must not touch: the thread's log, and its worktree and branch (none before the first run).
log_lines() { wb "$T_WB" log "$ID" --json | py "print(len(lines))"; }
no_doctor_leftovers() { ! branch_exists workbench/doctor && [ ! -e "$ROOT/.workbench/worktrees/doctor" ]; }
doctor_to() { # <file>: doctor's output into <file>, its exit code on stdout
    wb "$T_RUN" doctor >"$1" 2>&1
    echo $?
}

# --- 1. approved, no turn run ---------------------------------------------------------------------------

before=$(log_lines)
code=$(doctor_to "$SCRATCH/doctor1.out")
sed 's/^/    /' "$SCRATCH/doctor1.out" | head -12
check "doctor after approve: exit 0" "workbench doctor exited $code (it refused the approved goal?)" test "$code" = 0
check "doctor after approve: reports the check" "no 'check:' line in the output" grep -q '^check:' "$SCRATCH/doctor1.out"
check "doctor leaves the thread's log alone" "the log had $before lines, now $(log_lines)" test "$(log_lines)" = "$before"
check "doctor leaves no worktree or branch of its own" "doctor's worktree or branch is still there" no_doctor_leftovers
check "doctor creates no worktree or branch for the thread" "branch $BRANCH exists before any run" \
    bash -c '! git rev-parse -q --verify "refs/heads/$1" >/dev/null' _ "$BRANCH"

# --- 2. while a turn is live ----------------------------------------------------------------------------

echo "\$ workbench run $ID   (in the background)"
"$WB" run "$ID" >"$SCRATCH/run.out" 2>&1 &
RUN_PID=$!
CHILD=$RUN_PID
live=0
for _ in $(seq 1 60); do
    running=$("$WB" status "$ID" --json 2>/dev/null | py "print(d['running'])")
    [ "$running" = True ] && { live=1; break; }
    kill -0 "$RUN_PID" 2>/dev/null || break
    sleep 1
done
check "run: the turn is live" "status never showed running (run output: $(head -c 300 "$SCRATCH/run.out"))" test "$live" = 1

stop_run() {
    wb "$T_WB" stop >/dev/null 2>&1
    wait "$RUN_PID" 2>/dev/null
    CHILD=""
}
# Sabotage: the turn is gone before doctor asks, so the refusal this step expects cannot come.
[ "$SABOTAGE" = 1 ] && { echo "    VERIFY_CLI_SABOTAGE=1: stopping the turn before doctor"; stop_run; }

code=$(doctor_to "$SCRATCH/doctor2.out")
sed 's/^/    /' "$SCRATCH/doctor2.out" | head -6
check "doctor while a turn is live: refused (exit 6)" "workbench doctor exited $code" test "$code" = 6
check "doctor while a turn is live: names the thread" "the refusal does not mention $ID" grep -q "$ID" "$SCRATCH/doctor2.out"

# --- 3. after the turn ----------------------------------------------------------------------------------

[ "$SABOTAGE" = 1 ] || stop_run
ended=$(wb "$T_WB" log "$ID" --json | py "print(sum(1 for e in lines if e['kind']=='turn.ended'), sum(1 for e in lines if e['kind']=='turn.started'))")
check "run: one turn.ended per turn.started" "turn.ended / turn.started: $ended" bash -c 'set -- $1; [ "$1" = "$2" ] && [ "$1" -ge 1 ]' _ "$ended"

code=$(doctor_to "$SCRATCH/doctor3.out")
check "doctor after the turn: exit 0" "workbench doctor exited $code" test "$code" = 0
check "doctor after the turn: no worktree or branch of its own" "doctor's are still there" no_doctor_leftovers

# Ends the thread (one active thread at a time) and removes its worktree; the branch is kept, so it goes after.
wb "$T_WB" abandon "$ID" >/dev/null 2>&1
ended=$(wb "$T_WB" status "$ID" --json | py "print(d['ended'])")
check "abandon ends the thread" "status says ended: $ended" test "$ended" = abandoned
remove_on_pass branch "$BRANCH"
finish
