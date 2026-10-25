#!/bin/bash
# verify-cli scenario for what `goal new` writes for spending by default, on two clones of this repository. No agent is started, so it
# costs nothing.
#   bash scripts/verify-cli/goal-default-spend.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/goal-default-spend.sh   (the same, on a branch that contains origin/main)
# In a clone whose config has no `default_budget_usd` (what `init` writes), a goal drafted without --from carries
# `spend_policy: timeout_only` and no `budget_usd`. In a clone whose config sets `default_budget_usd = 2`, the draft carries
# `budget_usd: 2` and no spend_policy. Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start.
# VERIFY_CLI_SABOTAGE=1 sets `default_budget_usd` in the first clone too, so the steps "no budget_usd and spend_policy:
# timeout_only by default" must FAIL. The frame and the other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the first clone's config sets default_budget_usd"

RC=0
wbc() { # <clone> <out> args...: a workbench command in a clone, stdout and stderr together; sets RC
    local dir=$1 o=$2; shift 2
    echo "workbench $*   (in $dir)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in $dir)" >&2
    ( cd "$dir" && with_timeout "$T_WB" "$WB" "$@" >"$o" 2>&1 )
    RC=$?
}
BASE=verify-cli-base
mkclone() { # <name> <default_budget_usd line or empty>: a clone with a config, claude_path /usr/bin/false
    local dir="$SCRATCH/$1"
    g clone -q "$ROOT" "$dir" || die "git clone failed"
    git -C "$dir" checkout -q -b "$BASE" || die "could not make the base branch in the clone"
    wbc "$dir" "$SCRATCH/$1-init.out" init
    check "init writes a config in $1" "workbench init exited $RC" test "$RC" = 0
    local cfg="$dir/.workbench/config.toml"
    grep -v -e '^claude_path = ' -e '^# *default_budget_usd' "$cfg" >"$SCRATCH/$1.rest"
    { echo 'claude_path = "/usr/bin/false"'; [ -n "$2" ] && echo "$2"; cat "$SCRATCH/$1.rest"; } >"$cfg"
}
draft() { # <clone> <name>: the goal file of a fresh draft
    wbc "$1" "$SCRATCH/$2-new.out" goal new "$2" --base "$BASE"
    local id; id=$(sed -n 's/^created //p' "$SCRATCH/$2-new.out")
    [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id ($(head -3 "$SCRATCH/$2-new.out"))"
    echo "$1/.workbench/threads/$id/goal.md"
}

FIRST=""; [ "$SABOTAGE" = 1 ] && FIRST='default_budget_usd = 2'
mkclone plain "$FIRST"
G1=$(draft "$SCRATCH/plain" plain)
check "no budget_usd and spend_policy: timeout_only by default" "the draft has a budget_usd or no spend_policy line" \
    bash -c 'grep -q "^spend_policy: timeout_only" "$1" && ! grep -q "^budget_usd:" "$1"' _ "$G1"

mkclone capped 'default_budget_usd = 2'
G2=$(draft "$SCRATCH/capped" capped)
check "default_budget_usd = 2 in the config gives budget_usd: 2" "the draft has no 'budget_usd: 2' line or has spend_policy" \
    bash -c 'grep -q "^budget_usd: 2$" "$1" && ! grep -q "^spend_policy:" "$1"' _ "$G2"
finish
