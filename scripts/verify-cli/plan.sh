#!/bin/bash
# verify-cli scenario for `workbench plan` (P14 task 5), with the real `claude`, on this repository.
#   bash scripts/verify-cli/plan.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/plan.sh   (the same, on a branch that contains origin/main)
# Runs one throwaway thread: a read-only plan turn, `plan show`, `plan edit` (a marker line is added to the draft and
# applied), then one coding turn whose first prompt must carry the edited plan. Costs at most the plan cap plus the
# turn cap ($VERIFY_CLI_BUDGET_USD each, default 0.50) on the cheap model. Exit 0 only when every step passed, 1 when
# one failed, 2 when it refused to start (nothing changed). VERIFY_CLI_SABOTAGE=1 changes the stored edited plan on
# disk before `run`, so the plan is left out and the run steps must FAIL. The frame and the other switches are in
# lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

GOAL_SRC="$SCRATCH/goal.md"
cat >"$GOAL_SRC" <<'GOAL'
---
id: verify-cli-plan
title: verify-cli plan scenario
base: origin/main
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

This is a throwaway thread that tests `workbench plan`; its branch is deleted afterwards. Create one new file,
`scratch/plan-probe.txt`, holding the single line `plan-probe`. Do not commit.

## Criteria

- [c1] `scratch/plan-probe.txt` exists in the worktree with the line `plan-probe`.
  - proof: the diff shows that one new file and nothing else

## Out of scope

- Any other file, and committing.
GOAL

start_thread verify-cli-plan "$GOAL_SRC"
remove_on_pass branch "$BRANCH"
PLANS="$THREAD_DIR/plans"
MARKER="verify-cli-plan-marker-$$"

# --- the plan turn ---------------------------------------------------------------------------------------
# (preflight already refused a claude_path that is fake-claude, so this is the real claude.)

wb "$T_RUN" plan "$ID" --model "$MODEL" --budget "$BUDGET_USD" 2>&1 | sed 's/^/    /' | head -12
plan_exit=${PIPESTATUS[0]}
check "plan: exit 0" "workbench plan exited $plan_exit" test "$plan_exit" = 0

LOG1=$(wb "$T_WB" log "$ID" --json)
plan_events() {
    echo "$LOG1" | py "
s=[e for e in lines if e['kind']=='plan.started']; n=[e for e in lines if e['kind']=='plan.ended']
if len(s)!=1 or len(n)!=1 or s[0]['seq']>n[0]['seq']: sys.exit('    expected one plan.started, then one plan.ended')
e=n[0]['data']
miss=[k for k in ('plan_ref','sha256','goal_hash','base_commit') if not e.get(k)]
if e.get('ok') is not True or miss: sys.exit('    plan.ended: ok=%s, missing %s, reason %s' % (e.get('ok'), miss, e.get('reason')))
print('    plan.ended ok: %s, %s bytes, cost %s' % (e['plan_ref'], e.get('bytes'), e.get('cost_usd')))"
}
check "plan.started then plan.ended ok, with ref, sha256, goal_hash and base_commit" "see above" plan_events

plan_argv() {
    echo "$LOG1" | py "
a=next(e['data']['argv'] for e in lines if e['kind']=='plan.started')
i=a.index('--tools') if '--tools' in a else -1
t=[]
if i>=0:
    for v in a[i+1:]:
        if v.startswith('--'): break
        t.append(v)
print('    --tools %s; safe-mode %s; restricted %s' % (' '.join(t), '--safe-mode' in a, '--restricted' in a))
bad=[v for v in a if v in ('Bash','Edit','Write','--resume','--permission-mode')]
sys.exit(0 if t==['Read','Grep','Glob'] and not bad and '--safe-mode' in a and '--restricted' in a else 1)"
}
check "the plan turn is read-only: tools Read Grep Glob, safe mode, restricted, no Bash/Edit/Write" "see above" plan_argv

turns=$(echo "$LOG1" | py "print(len([e for e in lines if e['kind']=='turn.started']))")
check "the plan opened no numbered turn" "$turns turn.started event(s)" test "$turns" = 0

PLAN1="$PLANS/plan-1.md"
plan_file_ok() {
    [ -s "$PLAN1" ] || { echo "    $PLAN1 is missing or empty"; return 1; }
    echo "    plan-1.md: $(wc -c <"$PLAN1" | tr -d ' ') bytes, first line: $(grep -m1 . "$PLAN1" | cut -c1-70)"
    ! grep -qE '/Users/|/home/' "$PLAN1"
}
check "plans/plan-1.md is non-empty and holds no machine path" "see above" plan_file_ok

checkout_gone() {
    [ ! -e "$THREAD_DIR/plan/checkout" ] || return 1
    local list
    list=$(g worktree list --porcelain) && ! grep -q 'plan/checkout' <<<"$list"
}
check "the base-commit checkout is removed and not registered" "$THREAD_DIR/plan/checkout is still there or listed" checkout_gone

# --- show and status -------------------------------------------------------------------------------------

SHOWN=$(wb "$T_WB" plan show "$ID")
FIRST_LINE=$(grep -m1 . "$PLAN1")
check "plan show says generated and prints the plan" "see the output above" \
    bash -c '[[ $1 == *"plan:      generated"* ]] && [[ $1 == *"$2"* ]]' _ "$SHOWN" "$FIRST_LINE"

plan_status() { # <source>: status --json has that plan.source, not stale, and a plan cost for a generated plan
    wb "$T_WB" status "$ID" --json | py "
p=d.get('plan')
print('    plan: %s; plan_cost_usd %s' % (json.dumps(p) if p is None else '%s stale=%s' % (p['source'], p['stale']), d.get('plan_cost_usd')))
ok=p is not None and p['source']=='$1' and p['stale'] is False
if '$1'=='generated': ok=ok and (d.get('plan_cost_usd') or 0) > 0
sys.exit(0 if ok else 1)"
}
check "status --json: plan generated, not stale, plan_cost_usd above 0" "see above" plan_status generated

# --- edit ------------------------------------------------------------------------------------------------

DRAFT_OUT=$(wb "$T_WB" plan edit "$ID")
echo "$DRAFT_OUT" | sed 's/^/    /'
check "plan edit wrote plans/draft.md with the plan" "no draft, or it differs from plan-1.md" \
    bash -c '[ -f "$1/draft.md" ] && cmp -s "$1/draft.md" "$1/plan-1.md"' _ "$PLANS"
printf '\n%s\n' "$MARKER" >>"$PLANS/draft.md"
wb "$T_WB" plan edit --apply "$ID" 2>&1 | sed 's/^/    /'
apply_exit=${PIPESTATUS[0]}
check "plan edit --apply exits 0" "exit $apply_exit" test "$apply_exit" = 0
check "the draft is used up and plans/plan-2.md holds the marker" "see $PLANS" \
    bash -c '[ ! -e "$1/draft.md" ] && grep -qF -- "$2" "$1/plan-2.md"' _ "$PLANS" "$MARKER"

SHOWN2=$(wb "$T_WB" plan show "$ID")
check "plan show says edited and prints the marker" "see the output above" \
    bash -c '[[ $1 == *"plan:      edited"* ]] && [[ $1 == *"$2"* ]]' _ "$SHOWN2" "$MARKER"
check "status --json: plan edited, not stale" "see above" plan_status edited

edited_event() {
    wb "$T_WB" log "$ID" --json | py "
n=[e['data'] for e in lines if e['kind']=='plan.ended' and e['data'].get('ok')]
w=[e['data'] for e in lines if e['kind']=='plan.edited']
if not n or not w: sys.exit('    no plan.edited, or no plan.ended')
print('    plan.edited: %s, from %s' % (w[-1].get('plan_ref'), (w[-1].get('from_sha256') or '')[:12]))
sys.exit(0 if w[-1].get('from_sha256')==n[-1].get('sha256') and w[-1].get('plan_ref')=='plans/plan-2.md' and w[-1].get('base_commit') and w[-1].get('goal_hash')==n[-1].get('goal_hash') else 1)"
}
check "plan.edited names plans/plan-2.md, the plan it came from, the base and the goal hash" "see above" edited_event

# --- the run ---------------------------------------------------------------------------------------------

if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: changing plans/plan-2.md on disk, so the log no longer matches it"
    printf 'changed outside plan edit\n' >>"$PLANS/plan-2.md"
fi
run_thread

PROMPT="$THREAD_DIR/prompts/turn-1.md"
check "the first prompt has a ## Plan section with the marker" "see $PROMPT" \
    bash -c 'grep -qF -- "## Plan" "$1" && grep -qF -- "$2" "$1"' _ "$PROMPT" "$MARKER"

started_plan() {
    local want
    want=$(shasum -a 256 "$PLANS/plan-2.md" | cut -d' ' -f1)
    wb "$T_WB" log "$ID" --json | WANT="$want" py "
import os
s=[e['data'] for e in lines if e['kind']=='turn.started']
p=s[0].get('plan') if s else None
print('    turn.started plan: %s' % json.dumps(p))
sys.exit(0 if p and p.get('source')=='edited' and p.get('sha256')==os.environ['WANT'] else 1)"
}
check "turn.started records plan source edited and the stored file's sha256" "see above" started_plan

# --- the cost, and the end of the thread -----------------------------------------------------------------

plan_cost=$(wb "$T_WB" log "$ID" --json | py "e=[x['data'] for x in lines if x['kind']=='plan.ended']
print('%.4f USD over %d plan turn(s)' % (sum(x.get('cost_usd') or 0 for x in e), len(e)))")
echo "cost of the plan turn: $plan_cost (cap $BUDGET_USD USD, model $MODEL)"

left=$( [ -n "$WT" ] && pgrep -fl "$WT")
check "no process of the worktree left" "$left" test -z "$left"

# The thread is ended here, not left active: abandon keeps the branch and saves the changes.
wb "$T_WB" abandon "$ID" >/dev/null
ended=$(wb "$T_WB" status "$ID" --json | py "print(d['ended'] or '')")
check "thread ended (abandon)" "thread $ID is still active" test -n "$ended"

finish
