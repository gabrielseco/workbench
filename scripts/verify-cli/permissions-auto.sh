#!/bin/bash
# verify-cli scenario for `permissions = "auto"` (P24), with the real `claude`, on this repository.
#   bash scripts/verify-cli/permissions-auto.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/permissions-auto.sh   (the same, on a branch that contains origin/main)
# Adds `permissions = "auto"` to .workbench/config.toml (restored on exit) and runs one throwaway thread. The goal asks the turn to
# run a compound command that the allowlist can never match, then `git push --dry-run` (under `[tools] denied`, and a dry run so a
# failure of the deny cannot publish anything). The steps: `workbench config` says auto, the turn was started with
# `--permission-mode auto`, `--restricted` and `--permission-prompts none`, the compound command ran (its file exists, no denial
# names it), and the push was denied and its command is in the log. Costs at most the turn cap ($VERIFY_CLI_BUDGET_USD, default
# 0.50). Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start (nothing changed). VERIFY_CLI_SABOTAGE=1
# leaves `permissions` out: the config, argv and compound-command steps must FAIL. The frame and the other switches are in
# lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

CONFIG="$ROOT/.workbench/config.toml"
[ -f "$CONFIG" ] || die "no $CONFIG; this scenario edits it (and puts it back)"
grep -Eq '^permissions[[:space:]]*=' "$CONFIG" && die "$CONFIG already sets permissions; this scenario will not overwrite it"
grep -q 'Bash(git push:\*)' "$CONFIG" || die "$CONFIG does not deny git push; the deny step needs it"
# The backup lives outside $SCRATCH, which finish removes before the EXIT trap runs.
ORIG=$(mktemp "${TMPDIR:-/tmp}/verify-cli-permissions-auto-config.XXXXXX") || die "mktemp failed"
cp "$CONFIG" "$ORIG"
restore() { cp "$ORIG" "$CONFIG" && rm -f "$ORIG"; }
trap restore EXIT

if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: permissions is left out of the config"
else
    { printf 'permissions = "auto"\n'; cat "$ORIG"; } >"$CONFIG"
fi

GOAL_SRC="$SCRATCH/goal.md"
cat >"$GOAL_SRC" <<'GOAL'
---
id: verify-cli-permissions-auto
title: verify-cli permissions auto scenario
base: origin/main
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

This is a throwaway thread that tests `permissions = "auto"`; its branch is deleted afterwards. Do these two steps in order, each
as its own tool call:

1. With the Bash tool, run exactly `mkdir -p scratch/auto-compound && printf auto > scratch/auto-compound/f && git add scratch/auto-compound`
   as one command.
2. With the Bash tool, run exactly `git push --dry-run origin HEAD`.

If the Bash tool refuses a command, do not retry it, do not look for another way to do the same and do not change any setting: go on to
the next step, and finish by saying which commands were refused. Do not commit.

## Criteria

- [c1] `scratch/auto-compound/f` exists in the worktree.
  - proof: the diff shows that one new file and nothing else

## Out of scope

- Any other file, and committing.
GOAL

start_thread verify-cli-permissions-auto "$GOAL_SRC"
remove_on_pass branch "$BRANCH"

cfg=$(wb "$T_WB" config 2>&1 | grep '^perms:' || true)
echo "    config says: ${cfg:-<no perms line>}"
check "workbench config says the mode" "no 'perms:    auto' line, got '${cfg:-<none>}'" bash -c '[ "$1" = "perms:    auto" ]' _ "$cfg"

run_thread

argv=$(wb "$T_WB" log "$ID" --json | py "s=[e for e in lines if e['kind']=='turn.started']; print(' '.join(s[-1]['data']['argv']) if s else '')")
check "the turn was started with --permission-mode auto" "argv has no --permission-mode auto" \
    bash -c '[[ $1 == *"--permission-mode auto"* ]]' _ "$argv"
check "and still restricted, with no prompt path" "argv lacks --restricted or --permission-prompts none" \
    bash -c '[[ $1 == *"--restricted"* && $1 == *"--permission-prompts none"* && $1 != *bypassPermissions* ]]' _ "$argv"

refused=$(wb "$T_WB" log "$ID" --json | py "r=[x['data'].get('input') or '' for x in lines if x['kind']=='agent.activity'
    and x['data'].get('type')=='permission_denied']
print('|'.join(r))")
echo "    refused: ${refused:-<nothing>}"
made=$(cat "$WT/scratch/auto-compound/f" 2>/dev/null)
echo "    the file says: ${made:-<missing>}"
check "the compound command ran: its file is there" "file says '${made:-<missing>}'" bash -c '[ "$1" = auto ]' _ "$made"
check "and no denial names it" "denied: $refused" bash -c '[[ $1 != *auto-compound* ]]' _ "$refused"
check "git push was denied and the log names it" "refusals: ${refused:-<nothing>}" bash -c '[[ $1 == *"git push"* ]]' _ "$refused"

wb "$T_WB" abandon "$ID" >/dev/null 2>&1
ended=$(wb "$T_WB" status "$ID" --json | py "print(d['ended'])")
check "abandon ends the thread" "status says ended: $ended" test "$ended" = abandoned
finish
