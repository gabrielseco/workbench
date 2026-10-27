#!/bin/bash
# verify-cli scenario for provider, model and approval shown by `status`, `review` and `doctor` (P9 PR 11), on a clone of this
# repository. The clone's claude_path is /usr/bin/false and its codex does not exist, so no real agent is started and it costs nothing.
#   bash scripts/verify-cli/agent-visibility.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/agent-visibility.sh   (the same, on a branch that contains origin/main)
# A goal is approved with `[agents.run] model = "opus"` and `[agents.judge] model = "haiku"`. Before any turn, `status` must say what it was
# approved for and show no agent that ran; `doctor` (text and --json) must name each responsibility's provider and model, report the
# missing codex as a problem and its unconfined reads as a note, and still pass. Then `run` is started (it ends at once, the
# "claude" being /usr/bin/false) and `status` and `review`, text and --json, must show the run's provider and model from the log. Exit 0 only when every
# step passed, 1 when one failed, 2 when it refused to start. VERIFY_CLI_SABOTAGE=1 skips the `run`, so the steps that expect the run's
# agent in `status` and `review` (text and --json) must FAIL. The frame and the other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: no turn is run, so no log record says which agent ran"

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
{ echo 'claude_path = "/usr/bin/false"'; cat "$SCRATCH/config.rest"
  printf '\n[agents.run]\nmodel = "opus"\n\n[agents.judge]\nmodel = "haiku"\n\n[providers.codex]\nexecutable = "/nonexistent/codex"\n'; } >"$cfg"

cat >"$SCRATCH/goal.md" <<'GOAL'
---
id: verify-cli-visibility
title: verify-cli agent visibility scenario
base: verify-cli-base
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

A throwaway thread for the provider and model each command shows; nothing real is run.

## Criteria

- [c1] Nothing runs.
  - proof: the log

## Out of scope

- Everything else.
GOAL
wbp "$SCRATCH/new.out" goal new verify-cli-visibility --base "$BASE" --from "$SCRATCH/goal.md"
ID=$(sed -n 's/^created //p' "$SCRATCH/new.out")
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id ($(head -3 "$SCRATCH/new.out"))"
wbp "$SCRATCH/approve.out" goal approve "$ID"

# --- before any turn --------------------------------------------------------------------------------------

wbp "$SCRATCH/status0.out" status "$ID"
shown "$SCRATCH/status0.out" 14
check "status says what the goal was approved for" "no 'approved for: claude, model opus' line" \
    grep -q "^approved for: claude, model opus" "$SCRATCH/status0.out"
check "status shows no agent before a turn" "an 'agent run:' line before any turn" \
    bash -c '! grep -q "^agent run:" "$1"' _ "$SCRATCH/status0.out"
wbp "$SCRATCH/status0.json" status "$ID" --json
check "status --json: approved_for, and no agent has run" "approved_for is not {claude, opus, recorded} or an agent is set" \
    py "a=d['approved_for']; assert a=={'provider':'claude','model':'opus','recorded':True,'spend_policy':'hard_cap'}, a; assert d['agents']=={'run':None,'judge':None,'review':None}, d['agents']" <"$SCRATCH/status0.json"

wbp "$SCRATCH/doctor.out" doctor
shown "$SCRATCH/doctor.out" 22
check "doctor passes with problems reported (they are warnings)" "doctor exited $RC" test "$RC" = 0
check "doctor shows run and judge with their models" "no 'agent run:' claude opus or 'agent judge:' claude haiku" \
    bash -c 'grep -q "^agent run: .*claude, model opus" "$1" && grep -q "^agent judge: .*claude, model haiku" "$1"' _ "$SCRATCH/doctor.out"
check "doctor reports the missing codex as a problem" "no 'problem: codex is not installed' line" \
    grep -q "problem: codex is not installed" "$SCRATCH/doctor.out"
check "doctor states Codex's unconfined reads" "no 'note: a read-only review on codex can read files outside the checkout' line" \
    grep -q "note: a read-only review on codex can read files outside the checkout" "$SCRATCH/doctor.out"
check "doctor shows what the goal was approved for" "no 'approved: <thread> for claude, model opus' line" \
    grep -q "^approved: $ID for claude, model opus" "$SCRATCH/doctor.out"
wbp "$SCRATCH/doctor.json" doctor --json
check "doctor --json: one object with the agents and the problem" "agents or problems are not as expected" \
    py "assert d['v']==1 and d['passed'] is True, d
a={x['role']:x for x in d['agents']}
assert (a['run']['provider'],a['run']['model'])==('claude','opus') and (a['judge']['provider'],a['judge']['model'])==('claude','haiku'), a
assert a['goal']['provider'] is None and a['review']['provider']=='codex' and a['review']['model'] is None, a
assert any(p['role']=='review' and p['kind']=='missing_executable' for p in d['problems']), d['problems']
assert any(i['kind']=='unconfined_reads' and i['severity']=='note' for i in a['review']['issues']), a['review']
assert d['thread']=='$ID' and d['approved_for']['model']=='opus', d" <"$SCRATCH/doctor.json"

# --- after a turn -----------------------------------------------------------------------------------------

if [ "$SABOTAGE" != 1 ]; then
    wbp "$SCRATCH/run.out" run "$ID"
    shown "$SCRATCH/run.out" 4
fi
wbp "$SCRATCH/status1.out" status "$ID"
shown "$SCRATCH/status1.out" 14
check "status shows the run's provider and model" "no 'agent run: claude, model opus' line" \
    grep -q "^agent run: .*claude, model opus" "$SCRATCH/status1.out"
wbp "$SCRATCH/status1.json" status "$ID" --json
check "status --json: agents.run from the log" "agents.run is not {claude, opus, recorded}" \
    py "r=d['agents']['run']; assert (r['provider'],r['model'],r['recorded'])==('claude','opus',True), r" <"$SCRATCH/status1.json"
wbp "$SCRATCH/review.out" review "$ID"
check "review shows the run's provider and model" "no 'agent run: claude, model opus' line" \
    grep -q "^agent run: .*claude, model opus" "$SCRATCH/review.out"
wbp "$SCRATCH/review.json" review "$ID" --json
check "review --json: agents.run and approved_for" "agents.run or approved_for is not claude, opus" \
    py "r=d['agents']['run']; assert (r['provider'],r['model'])==('claude','opus'), r; assert d['approved_for']['model']=='opus', d['approved_for']" <"$SCRATCH/review.json"
finish
