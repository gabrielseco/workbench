#!/bin/bash
# verify-cli scenario for `spend_policy: timeout_only` and the "no dollar cap" wording (P9 PR 12), on a clone of this repository.
# The clone's claude_path is /usr/bin/false, so no real agent is started and it costs nothing.
#   bash scripts/verify-cli/spend-policy.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/spend-policy.sh   (the same, on a branch that contains origin/main)
# A source goal with `spend_policy: timeout_only` and no budget is copied with `goal new --from`: the draft must carry the key
# and no `budget_usd`. `goal approve`, `status`, `review` and `doctor` (text and --json) must then print "no dollar cap: bounded
# by 10 min per turn" and the spend policy; `run` is started (it ends at once, the "claude" being /usr/bin/false): the turn is
# started without --max-budget-usd, ends with no cost on record, and `status` says the cost is `unknown`, never $0. Exit 0 only
# when every step passed, 1 when one failed, 2 when it refused to start. VERIFY_CLI_SABOTAGE=1 makes the source goal a budget_usd
# goal, so every step that expects the no-cap wording, the key, or the missing --max-budget-usd must FAIL. The frame and the other
# switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the source goal has budget_usd, not spend_policy"

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
cfg="$P/.workbench/config.toml"
grep -v -e '^claude_path = ' "$cfg" >"$SCRATCH/config.rest"
{ echo 'claude_path = "/usr/bin/false"'; cat "$SCRATCH/config.rest"; } >"$cfg"

SPEND='spend_policy: timeout_only'
[ "$SABOTAGE" = 1 ] && SPEND='budget_usd: 0.50'
cat >"$SCRATCH/goal.md" <<GOAL
---
id: verify-cli-source
title: source for the spend policy scenario
base: verify-cli-base
$SPEND
turn_timeout_min: 10
---

## Request

A throwaway thread for the spend policy each command shows; nothing real is run.

## Criteria

- [c1] Nothing runs.
  - proof: the log

## Out of scope

- Everything else.
GOAL
wbp "$SCRATCH/new.out" goal new verify-cli-spend --base "$BASE" --from "$SCRATCH/goal.md"
ID=$(sed -n 's/^created //p' "$SCRATCH/new.out")
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id ($(head -3 "$SCRATCH/new.out"))"
GOALFILE="$P/.workbench/threads/$ID/goal.md"
check "goal new --from copies spend_policy and writes no budget_usd" "the draft has no 'spend_policy: timeout_only' line or has budget_usd" \
    bash -c 'grep -q "^spend_policy: timeout_only" "$1" && ! grep -q "^budget_usd:" "$1"' _ "$GOALFILE"

wbp "$SCRATCH/approve.out" goal approve "$ID"
shown "$SCRATCH/approve.out" 8
check "goal approve prints the no-cap line instead of a budget" "no 'no dollar cap: bounded by 10 min per turn' line, or a budget line" \
    bash -c 'grep -q "no dollar cap: bounded by 10 min per turn" "$1" && ! grep -q "^budget:" "$1"' _ "$SCRATCH/approve.out"
check "goal approve says what the coding approval covers" "no 'coding: ... no dollar cap' line" \
    grep -q "^coding: .*no dollar cap" "$SCRATCH/approve.out"

# --- before any turn --------------------------------------------------------------------------------------

wbp "$SCRATCH/status0.out" status "$ID"
shown "$SCRATCH/status0.out" 14
check "status prints the no-cap line, not a budget" "no 'spend: no dollar cap: bounded by 10 min per turn' line, or a budget" \
    bash -c 'grep -q "^spend: *no dollar cap: bounded by 10 min per turn" "$1" && ! grep -q "budget \$" "$1"' _ "$SCRATCH/status0.out"
check "status says the approval is for no dollar cap" "no 'approved for: ... no dollar cap' line" \
    grep -q "^approved for: .*no dollar cap" "$SCRATCH/status0.out"
wbp "$SCRATCH/status0.json" status "$ID" --json
check "status --json: goal.spend_policy timeout_only and a null budget" "goal.spend_policy / budget_usd are not timeout_only / null" \
    py "g=d['goal']; assert g['spend_policy']=='timeout_only' and g['budget_usd'] is None, g; assert d['approved_for']['spend_policy']=='timeout_only', d['approved_for']" <"$SCRATCH/status0.json"

wbp "$SCRATCH/review0.out" review "$ID"
check "review prints the no-cap line" "no 'spend: no dollar cap: bounded by 10 min per turn' line" \
    grep -q "^spend: *no dollar cap: bounded by 10 min per turn" "$SCRATCH/review0.out"
wbp "$SCRATCH/review0.json" review "$ID" --json
check "review --json: spend_policy timeout_only" "spend_policy is not timeout_only" \
    py "assert d['spend_policy']=='timeout_only' and d['approved_for']['spend_policy']=='timeout_only', d" <"$SCRATCH/review0.json"

wbp "$SCRATCH/doctor.out" doctor
shown "$SCRATCH/doctor.out" 22
check "doctor prints the no-cap line" "no 'spend: no dollar cap: bounded by 10 min per turn' line" \
    grep -q "^spend: *no dollar cap: bounded by 10 min per turn" "$SCRATCH/doctor.out"
wbp "$SCRATCH/doctor.json" doctor --json
check "doctor --json: spend_policy timeout_only and no budget problem" "spend_policy is not timeout_only or budget_without_cap is reported" \
    py "assert d['spend_policy']=='timeout_only', d['spend_policy']; assert not any(p['kind']=='budget_without_cap' for p in d['problems']), d['problems']" <"$SCRATCH/doctor.json"

# --- after a turn -----------------------------------------------------------------------------------------

wbp "$SCRATCH/run.out" run "$ID"
shown "$SCRATCH/run.out" 4
LOG="$P/.workbench/threads/$ID/events.jsonl"
check "the turn started without --max-budget-usd" "turn.started carries --max-budget-usd (or there is no turn.started)" \
    bash -c 'grep -q "\"turn.started\"" "$1" && ! grep "\"turn.started\"" "$1" | grep -q -e "--max-budget-usd"' _ "$LOG"
check "turn.ended records no cost_usd" "turn.ended has a cost_usd, or there is no turn.ended" \
    bash -c 'grep "\"turn.ended\"" "$1" | grep -q . && ! grep "\"turn.ended\"" "$1" | grep -q "cost_usd"' _ "$LOG"
wbp "$SCRATCH/status1.out" status "$ID"
shown "$SCRATCH/status1.out" 14
check "status says the cost is unknown, never 0" "no 'cost: unknown' line, or a \$0 total" \
    bash -c 'grep -q "^cost: *unknown" "$1" && ! grep "^cost:" "$1" | grep -q "\$0"' _ "$SCRATCH/status1.out"
wbp "$SCRATCH/status1.json" status "$ID" --json
check "status --json: cost_usd is null" "cost_usd is not null" py "assert d['cost_usd'] is None, d['cost_usd']" <"$SCRATCH/status1.json"
finish
