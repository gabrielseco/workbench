#!/bin/bash
# verify-cli scenario for approval bound to the coding settings (P9 PR 9), on a clone of this repository. `claude` is never
# started (the clone's claude_path names nothing), so it costs nothing.
#   bash scripts/verify-cli/approval-binding.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/approval-binding.sh   (the same, on a branch that contains origin/main)
# A goal is approved with `[agents.run] model = "opus"` in the config, then the config is changed to "haiku". `run` must refuse before
# starting anything and say what the goal was approved for; `goal approve` must bind the new model without touching the goal
# file, and `log` must show both approvals. Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start.
# VERIFY_CLI_SABOTAGE=1 leaves the config unchanged, so `run` is not refused for its settings (it gets as far as the missing
# claude) and the steps that expect the refusal, the second approval, its log line and the count of approvals must FAIL. The frame and the other
# switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the config keeps the model the goal was approved with"

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
setconfig() { # <model>: the clone's config with this [agents.run] model and no claude to start
    local cfg="$P/.workbench/config.toml"
    grep -v -e '^model = ' -e '^\[agents\.run\]$' -e '^claude_path = ' "$cfg" >"$SCRATCH/config.rest"
    { echo 'claude_path = "/nonexistent/claude"'; cat "$SCRATCH/config.rest"; printf '\n[agents.run]\nmodel = "%s"\n' "$1"; } >"$cfg"
}

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
setconfig opus

cat >"$SCRATCH/goal.md" <<'GOAL'
---
id: verify-cli-binding
title: verify-cli approval binding scenario
base: verify-cli-base
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

A throwaway thread for approval bound to the coding model; nothing is run.

## Criteria

- [c1] Nothing runs.
  - proof: the log

## Out of scope

- Everything else.
GOAL
wbp "$SCRATCH/new.out" goal new verify-cli-binding --base "$BASE" --from "$SCRATCH/goal.md"
ID=$(sed -n 's/^created //p' "$SCRATCH/new.out")
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id ($(head -3 "$SCRATCH/new.out"))"
GOALFILE="$P/.workbench/threads/$ID/goal.md"
LOG="$P/.workbench/threads/$ID/events.jsonl"

wbp "$SCRATCH/approve1.out" goal approve "$ID"
shown "$SCRATCH/approve1.out" 6
check "approve names the coding settings" "no 'coding:  claude, opus' line" grep -q "coding:  claude, opus" "$SCRATCH/approve1.out"
sum=$(shasum "$GOALFILE" | cut -d' ' -f1)

# --- the config changes ------------------------------------------------------------------------------------

[ "$SABOTAGE" = 1 ] || setconfig haiku
wbp "$SCRATCH/run.out" run "$ID"
shown "$SCRATCH/run.out" 4
check "run is refused for the changed model" "the refusal does not say what the goal was approved for" \
    grep -q "approved for claude, opus.*claude, haiku" "$SCRATCH/run.out"
check "nothing started" "the log has a turn.started" bash -c '! grep -q "\"turn.started\"" "$1"' _ "$LOG"

wbp "$SCRATCH/approve2.out" goal approve "$ID"
shown "$SCRATCH/approve2.out" 4
check "approving again binds the new model" "no 'coding:  claude, haiku' line" grep -q "coding:  claude, haiku" "$SCRATCH/approve2.out"
check "the goal file is untouched" "the goal file changed" test "$(shasum "$GOALFILE" | cut -d' ' -f1)" = "$sum"

wbp "$SCRATCH/log.out" log "$ID"
check "log shows both approvals" "expected 'goal approved for coding on claude, opus' and '... haiku'" bash -c \
    'grep -q "goal approved for coding on claude, opus" "$1" && grep -q "goal approved for coding on claude, haiku" "$1"' _ "$SCRATCH/log.out"

wbp "$SCRATCH/approve3.out" goal approve "$ID"
check "approving a third time writes nothing" "a third goal.approved was written" \
    bash -c '[ "$(grep -c "\"goal.approved\"" "$1")" = 2 ]' _ "$LOG"
finish
