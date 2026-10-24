#!/bin/bash
# verify-cli scenario for judge and review on either provider and the `allow_unpriced` opt-in (P9 PR 13), on a clone of this
# repository. The clone's claude is /usr/bin/false and its codex does not exist, so no real agent is started and it costs nothing.
#   bash scripts/verify-cli/judge-review-providers.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/judge-review-providers.sh   (the same, on a branch that contains origin/main)
# With `[agents.judge] provider = "codex"` and `[agents.review] provider = "claude"`: doctor must name both, report the Codex judge
# without `allow_unpriced` as a problem that names the key, and `judge` must be refused before it starts (recorded, exit 1) with the
# same message; `judge --budget` on it is a usage error
# (exit 2). `[agents.review]` on Codex takes a `model` and a `reasoning_effort` (doctor names both); an effort that is no level is
# refused when the config loads. SABOTAGE also writes that bad effort in the config that must be accepted.
# With `allow_unpriced = true` the problem goes, and `judge` gets as far as looking for `codex` (not installed: that is the failure).
# Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start. VERIFY_CLI_SABOTAGE=1 writes `allow_unpriced =
# true` already in the first config and leaves the review on codex, so the steps that expect the refusal and the Claude review
# must FAIL. The frame and the other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the opt-in is already given and the review stays on codex"

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
cfg="$P/.workbench/config.toml"
setagents() { # <allow_unpriced line, may be empty> <review table body>: rewrites the agents tables of the clone's config
    grep -v -e '^model = ' -e '^claude_path = ' "$SCRATCH/config.base" >"$SCRATCH/config.rest"
    { echo 'claude_path = "/usr/bin/false"'; cat "$SCRATCH/config.rest"
      printf '\n[providers.codex]\nexecutable = "/nonexistent/codex"\n\n[agents.judge]\nprovider = "codex"\n%s\n\n[agents.review]\n%s\n' "$1" "$2"; } >"$cfg"
}

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
cp "$cfg" "$SCRATCH/config.base"

REVIEW='provider = "claude"'
OPTIN=""
[ "$SABOTAGE" = 1 ] && { REVIEW='provider = "codex"'; OPTIN='allow_unpriced = true'; }
setagents "$OPTIN" "$REVIEW"

cat >"$SCRATCH/goal.md" <<'GOAL'
---
id: verify-cli-providers
title: verify-cli judge and review providers scenario
base: verify-cli-base
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

A throwaway thread for the judge and review providers; nothing real is run.

## Criteria

- [c1] Nothing runs.
  - proof: the log

## Out of scope

- Everything else.
GOAL
wbp "$SCRATCH/new.out" goal new verify-cli-providers --base "$BASE" --from "$SCRATCH/goal.md"
ID=$(sed -n 's/^created //p' "$SCRATCH/new.out")
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id ($(head -3 "$SCRATCH/new.out"))"
wbp "$SCRATCH/approve.out" goal approve "$ID"
wbp "$SCRATCH/run.out" run "$ID"   # ends at once: the claude is /usr/bin/false; it leaves a turn to judge

# --- 1. a Codex judge without the opt-in -------------------------------------------------------------------

wbp "$SCRATCH/doctor1.out" doctor
shown "$SCRATCH/doctor1.out" 22
check "doctor names the Codex judge and the Claude review" "no 'agent judge: codex' or 'agent review: claude' line" \
    bash -c 'grep -q "^agent judge: *codex" "$1" && grep -q "^agent review: *claude" "$1"' _ "$SCRATCH/doctor1.out"
check "doctor reports the Codex judge without allow_unpriced as a problem" "no problem naming allow_unpriced in [agents.judge]" \
    bash -c 'grep -q "problem: .*allow_unpriced.*\[agents.judge\]" "$1"' _ "$SCRATCH/doctor1.out"
wbp "$SCRATCH/doctor1.json" doctor --json
check "doctor --json: an unpriced_not_allowed problem for the judge" "no such problem in problems" \
    py "assert any(p['role']=='judge' and p['kind']=='unpriced_not_allowed' for p in d['problems']), d['problems']" <"$SCRATCH/doctor1.json"

wbp "$SCRATCH/judge1.out" judge "$ID"
shown "$SCRATCH/judge1.out" 4
check "judge is refused before it starts: exit 1" "workbench judge exited $RC" test "$RC" = 1
check "the refusal names allow_unpriced and [agents.judge]" "no such message" \
    bash -c 'grep -q "allow_unpriced" "$1" && grep -q "\[agents.judge\]" "$1"' _ "$SCRATCH/judge1.out"
wbp "$SCRATCH/judge1.json" review "$ID" --json
check "the refusal is recorded as a judge with no verdict, on codex" "judge in review --json is not a codex failure naming allow_unpriced" \
    py "j=d['judge']; assert j['ok'] is False and 'allow_unpriced' in j['failure'], j; assert d['agents']['judge']['provider']=='codex', d['agents']" <"$SCRATCH/judge1.json"

wbp "$SCRATCH/budget.out" judge "$ID" --budget 1 --again
shown "$SCRATCH/budget.out" 3
check "judge --budget on a Codex judge is a usage error: exit 2" "workbench judge --budget exited $RC" test "$RC" = 2
check "the usage error says --budget has no effect on codex" "no such message" grep -q -- "--budget has no effect on codex" "$SCRATCH/budget.out"

# --- 2. a model and an effort on a Codex review are accepted, a bad effort is refused when the config loads -------

setagents "allow_unpriced = true" 'provider = "codex"
model = "gpt-6-astra"
reasoning_effort = "high"'
[ "$SABOTAGE" = 1 ] && setagents "allow_unpriced = true" 'provider = "codex"
reasoning_effort = "ultra"'
wbp "$SCRATCH/doctor2.out" doctor
shown "$SCRATCH/doctor2.out" 6
check "a model and an effort on a Codex review: doctor accepts the config" "workbench doctor exited $RC" test "$RC" = 0
check "doctor names the model and the effort" "agent review line lacks gpt-6-astra and effort high" \
    bash -c 'grep "^agent review:" "$1" | grep -q "gpt-6-astra" && grep "^agent review:" "$1" | grep -q "effort high"' _ "$SCRATCH/doctor2.out"
setagents "allow_unpriced = true" 'provider = "codex"
reasoning_effort = "ultra"'
wbp "$SCRATCH/doctor2b.out" doctor
check "an effort Workbench has no level for is refused when the config loads" "workbench doctor exited $RC" test "$RC" != 0
check "the message names reasoning_effort" "no 'reasoning_effort' message" grep -q "reasoning_effort" "$SCRATCH/doctor2b.out"

# --- 3. with the opt-in the judge goes as far as looking for codex ------------------------------------------

setagents "allow_unpriced = true" 'provider = "claude"'
wbp "$SCRATCH/doctor3.out" doctor
check "with allow_unpriced the doctor problem is gone" "an unpriced_not_allowed problem is still reported" \
    bash -c '! grep -q "allow_unpriced" "$1" || grep -q "lets the judge run on codex with only a timeout" "$1"' _ "$SCRATCH/doctor3.out"
wbp "$SCRATCH/judge3.out" judge "$ID" --again
shown "$SCRATCH/judge3.out" 3
check "judge is not refused for the spend: it fails on the missing codex" "the message is not about the missing codex" \
    bash -c 'grep -q "was not found" "$1" && ! grep -q "cannot enforce a dollar limit" "$1"' _ "$SCRATCH/judge3.out"
finish
