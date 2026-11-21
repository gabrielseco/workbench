#!/bin/bash
# verify-cli scenario for `goal new --after <thread>` (P27 task 1), on this repository. No turn is run, so it costs nothing.
#   bash scripts/verify-cli/goal-after.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/goal-after.sh   (the same, on a branch that contains origin/main)
# A goal stacked on another thread needs that thread's pull request, so the success path (the base is the parent's branch
# on origin, the worktree is cut from its tip) is checked by GoalAfterTests with a local origin; opening a real pull request
# here would leave one on GitHub. This scenario checks what the binary refuses, and that a refusal creates nothing: a
# parent that never opened a pull request, a name that is not a thread, --after with --base, --after with --update, and a
# name that could reach a path. Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start.
# VERIFY_CLI_SABOTAGE=1 drops --after from the first command, so a thread is created and "refused" must FAIL.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

GOAL_SRC="$SCRATCH/goal.md"
cat >"$GOAL_SRC" <<'GOAL'
---
id: verify-cli-goal-after
title: verify-cli goal-after scenario
base: origin/main
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

A throwaway parent thread that never opens a pull request; no turn is run and its branch never exists.

## Criteria

- [c1] Nothing changes.
  - proof: no thread is created by a refused `goal new --after`

## Out of scope

- Everything.
GOAL

start_thread verify-cli-goal-after "$GOAL_SRC"
PARENT=$ID

RC=0
threads() { ls "$ROOT/.workbench/threads" | sort; }
refused() { # refused <name> <arguments...>: the command, its stderr in $SCRATCH/e, its exit code in RC
    local o="$SCRATCH/o"
    echo "workbench $*" >>"$SCRATCH/commands"
    with_timeout "$T_WB" "$WB" "$@" >"$o" 2>"$SCRATCH/e"
    RC=$?
}

before=$(threads)
if [ "${VERIFY_CLI_SABOTAGE:-}" = 1 ]; then refused goal new stacked; else refused goal new stacked --after "$PARENT"; fi
check "a parent with no pull request is refused" "exit $RC: $(head -c 300 "$SCRATCH/e")" \
    bash -c '[ "$1" != 0 ] && grep -q "has opened a pull request" "$2"' _ "$RC" "$SCRATCH/e"
check "the refusal created no thread" "threads changed: $(diff <(echo "$before") <(threads) | head -5)" \
    test "$(threads)" = "$before"
wb "$T_WB" abandon --thread "$(threads | grep -v "^$PARENT$" | head -1)" >/dev/null 2>&1 || true

before=$(threads)
refused goal new stacked --after g-2020-01-01-nothing
check "a name that is no thread is refused" "exit $RC: $(head -c 300 "$SCRATCH/e")" \
    bash -c '[ "$1" != 0 ] && grep -q "has opened a pull request" "$2"' _ "$RC" "$SCRATCH/e"
refused goal new stacked --after "$PARENT" --base main
check "--after with --base is refused" "exit $RC: $(head -c 300 "$SCRATCH/e")" \
    bash -c '[ "$1" != 0 ] && grep -q -- "--after already sets the base" "$2"' _ "$RC" "$SCRATCH/e"
refused goal new stacked --after "$PARENT" --update feature/x
check "--after with --update is refused" "exit $RC: $(head -c 300 "$SCRATCH/e")" \
    bash -c '[ "$1" != 0 ] && grep -q -- "--after already sets the base" "$2"' _ "$RC" "$SCRATCH/e"
refused goal new stacked --after ../x
check "a name that could reach a path is refused" "exit $RC: $(head -c 300 "$SCRATCH/e")" \
    bash -c '[ "$1" != 0 ] && grep -q "is not a usable name" "$2"' _ "$RC" "$SCRATCH/e"
check "none of them created a thread" "threads changed: $(diff <(echo "$before") <(threads) | head -5)" \
    test "$(threads)" = "$before"

wb "$T_WB" abandon "$PARENT" >/dev/null 2>&1
ended=$(wb "$T_WB" status "$PARENT" --json | py "print(d['ended'])")
check "abandon ends the parent" "status says ended: $ended" test "$ended" = abandoned
finish
