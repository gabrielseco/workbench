#!/bin/bash
# verify-cli scenario for the spine and attention in `workbench status` (P19 task 0), on this repository. No turn is run, so it
# costs nothing.
#   bash scripts/verify-cli/status-spine.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/status-spine.sh   (the same, on a branch that contains origin/main)
# On a throwaway thread: after approval, `status` must print the seven steps and an attention line, and `status --json` must carry
# `spine` (seven {step, mark, sublabel} in order: goal done, run current, the rest pending) and `attention` (state none); editing
# the approved goal must turn the goal step back to current ("Changed since approval") and say so in the text; abandoning must end
# the spine at review ("Abandoned") with attention none. Exit 0 only when every step passed, 1 when one failed, 2 when it refused
# to start. VERIFY_CLI_SABOTAGE=1 leaves the goal unedited, so the steps that expect the stale goal must FAIL. The frame and the
# other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the approved goal is not edited"

GOAL_SRC="$SCRATCH/goal.md"
cat >"$GOAL_SRC" <<'GOAL'
---
id: verify-cli-spine
title: verify-cli spine scenario
base: origin/main
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

This is a throwaway thread that tests the spine in `workbench status`; no turn is run and its branch never exists.

## Criteria

- [c1] Nothing changes.
  - proof: the thread's log is the same before and after status

## Out of scope

- Everything.
GOAL

start_thread verify-cli-spine "$GOAL_SRC"

# --- 1. an approved goal, no turn --------------------------------------------------------------------------

text=$(wb "$T_WB" status "$ID")
check "text status prints the seven steps" "$(echo "$text" | grep -c '^  [A-Z]') step lines" \
    bash -c 'for s in "Goal" "Run" "Review" "Accept" "Ship" "PR review" "Clean"; do grep -q "^  $s " <<<"$1" || exit 1; done' _ "$text"
check "text status prints the attention line" "no 'attention:' line" grep -q '^attention: none$' <<<"$text"

json=$(wb "$T_WB" status "$ID" --json)
shape=$(echo "$json" | py "print(','.join(e['step']+'='+e['mark'] for e in d['spine']))")
check "json spine: seven steps in order, goal done, run current, rest pending" "got $shape" \
    test "$shape" = "goal=done,run=current,review=pending,accept=pending,ship=pending,pr review=pending,clean=pending"
att=$(echo "$json" | py "a=d['attention']; print(a['state'], a['reason'], a['since'], a['commit'])")
check "json attention: none, with no reason" "got '$att'" test "$att" = "none None None None"

# --- 2. the goal changes after approval --------------------------------------------------------------------

if [ "$SABOTAGE" != 1 ]; then
    echo "An extra line, added after approval." >>"$THREAD_DIR/goal.md"
fi
stale=$(wb "$T_WB" status "$ID" --json | py "e=d['spine'][0]; print(e['mark'], e['sublabel'])")
check "an edited approved goal puts the goal step back to current" "got '$stale'" test "$stale" = "current Changed since approval"
check "text status says the goal changed" "goal step line: $(wb "$T_WB" status "$ID" | grep '^  Goal')" \
    bash -c 'wb_out=$("$1" status "$2") && grep -q "^  Goal .*current  Changed since approval" <<<"$wb_out"' _ "$WB" "$ID"

# --- 3. abandoned ------------------------------------------------------------------------------------------

wb "$T_WB" abandon "$ID" >/dev/null 2>&1
ended=$(wb "$T_WB" status "$ID" --json | py "print(d['ended'])")
check "abandon ends the thread" "status says ended: $ended" test "$ended" = abandoned
last=$(wb "$T_WB" status "$ID" --json | py "r=d['spine'][2]; print(r['mark'], r['sublabel'], d['attention']['state'])")
check "an abandoned thread ends at review with attention none" "got '$last'" test "$last" = "done Abandoned none"
finish
