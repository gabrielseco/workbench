#!/bin/bash
# verify-cli scenario for the thread spine and the "needs you" line of `workbench status` (P19 task 0), on this repository.
# No turn is run, so it costs nothing.
#   bash scripts/verify-cli/status-spine.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/status-spine.sh   (the same, on a branch that contains origin/main)
# A thread with an approved goal and no turn must show the seven steps with Goal done and Run current in `status --json`
# (`spine`, `attention`, still `v` 1) and in text (one line per step, then `attention:`); every thread already in this
# repository's .workbench/ must get a seven-step spine whose Review matches how it ended, and no CI-based reason (status
# never asks GitHub); after `abandon`, Review is the last step, `failed`, and nothing needs you. Exit 0 only when every
# step passed, 1 when one failed, 2 when it refused to start (nothing changed). VERIFY_CLI_SABOTAGE=1 edits the goal file
# after approval, so the steps "approved, no turn: Goal done and Run current" and "text: one line per step" must FAIL.
# The frame and the other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

GOAL_SRC="$SCRATCH/goal.md"
cat >"$GOAL_SRC" <<'GOAL'
---
id: verify-cli-status-spine
title: verify-cli status spine scenario
base: origin/main
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

This is a throwaway thread that tests the spine in `workbench status`; no turn is run and its branch never exists.

## Criteria

- [c1] Nothing changes.
  - proof: the thread is abandoned unrun

## Out of scope

- Everything.
GOAL

start_thread verify-cli-status-spine "$GOAL_SRC"
# The sabotage changes the approved goal, which sends it back to draft: the Goal step is then current, not done.
[ "$SABOTAGE" = 1 ] && printf '\n- Edited after approval.\n' >>"$THREAD_DIR/goal.md"

STEPS="Goal Run Review Accept Ship PR_review Clean"

# --- 1. an approved goal with no turn, in JSON ------------------------------------------------------------

wb "$T_WB" status "$ID" --json >"$SCRATCH/status.json"
marks=$(py "print(' '.join(s['mark'] for s in d['spine']))" <"$SCRATCH/status.json")
steps=$(py "print(' '.join(s['step'].replace(' ', '_') for s in d['spine']))" <"$SCRATCH/status.json")
check "json: seven steps in order" "steps: $steps" test "$steps" = "$STEPS"
check "approved, no turn: Goal done and Run current" "marks: $marks" \
    test "$marks" = "done current pending pending pending pending pending"
shapes=$(py "print(all(sorted(s) == ['mark', 'step', 'sublabel'] for s in d['spine']))" <"$SCRATCH/status.json")
check "json: each step is {step, mark, sublabel}" "a step has other keys" test "$shapes" = True
attention=$(py "a=d['attention']; print(a['state'], a['reason'], a['since'], sorted(a))" <"$SCRATCH/status.json")
check "json: nothing needs you before the first turn" "attention: $attention" \
    test "$attention" = "none None None ['reason', 'since', 'state']"
version=$(py "print(d['v'])" <"$SCRATCH/status.json")
check "json: the keys are added under v 1" "v is $version" test "$version" = 1

# --- 2. the same in text ----------------------------------------------------------------------------------

wb "$T_WB" status "$ID" >"$SCRATCH/status.txt"
check "text: one line per step, then the attention line" "$(sed -n '/^spine:/,$p' "$SCRATCH/status.txt")" \
    python3 -I -c "
import sys
lines = open(sys.argv[1]).read().splitlines()
at = next(i for i, l in enumerate(lines) if l.startswith('spine:'))
spine, rest = lines[at:at + 7], lines[at + 7:]
steps = ['Goal', 'Run', 'Review', 'Accept', 'Ship', 'PR review', 'Clean']
ok = all(l[11:].startswith(s) for l, s in zip(spine, steps))
ok = ok and spine[0].split()[1:3] == ['Goal', 'done'] and spine[1].split()[1:3] == ['current', 'Ready']
sys.exit(not (ok and rest[:1] == ['attention: none']))" "$SCRATCH/status.txt"

# --- 3. every thread this repository already has ----------------------------------------------------------

wb "$T_WB" status --all --json >"$SCRATCH/all.json"
bad=""; seen=0
for tid in $(py "print(' '.join(t['thread'] for t in d['threads']))" <"$SCRATCH/all.json"); do
    seen=$((seen + 1))
    wb "$T_WB" status "$tid" --json >"$SCRATCH/t.json" 2>/dev/null || { bad="$bad $tid(exit)"; continue; }
    why=$(py "
s, a, e = d['spine'], d['attention'], d['ended']
review = s[2]['mark'] if len(s) == 7 else None
problems = []
if [x['step'] for x in s] != ['Goal', 'Run', 'Review', 'Accept', 'Ship', 'PR review', 'Clean']: problems.append('steps')
if e == 'accepted' and review != 'done': problems.append('accepted, Review ' + str(review))
if e in ('discarded', 'abandoned') and (review != 'failed' or a['state'] != 'none'): problems.append(e + ' still asks')
if a['state'] not in ('none', 'working', 'needs_you'): problems.append('state ' + a['state'])
if (a['reason'] or '').startswith(('CI failed', 'Ready to merge')): problems.append('CI reason without checks')
print(','.join(problems))" <"$SCRATCH/t.json")
    [ -z "$why" ] || bad="$bad $tid($why)"
done
check "every thread here: seven steps, Review as it ended, no CI reason" "$seen threads; wrong:$bad" test -z "$bad"

# --- 4. abandoned: Review is the last step --------------------------------------------------------------

# Ends the thread (one active thread at a time); it never had a branch or a worktree.
wb "$T_WB" abandon "$ID" >/dev/null 2>&1
ended=$(wb "$T_WB" status "$ID" --json | py "print(d['ended'], d['spine'][2]['mark'], d['spine'][2]['sublabel'], d['attention']['state'])")
check "abandoned: Review failed with the decision, nothing needs you" "status says: $ended" \
    test "$ended" = "abandoned failed Abandoned none"
finish
