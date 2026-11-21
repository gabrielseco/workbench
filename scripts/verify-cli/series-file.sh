#!/bin/bash
# verify-cli scenario for the series file (P27 task 2), on this repository. No turn is run, so it costs nothing.
#   bash scripts/verify-cli/series-file.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/series-file.sh   (the same, on a branch that contains origin/main)
# A throwaway series is written under .workbench/series/ of this project (step project: this checkout) and driven with
# `series list|show|approve`: not approved, approved, STALE after a goal file changes, an invalid file refused with every
# problem listed (exit 6), no such series (exit 7). Exit 0 only when every step passed, 1 when one failed, 2 when it refused
# to start. VERIFY_CLI_SABOTAGE=1 leaves the goal file unchanged, so the "STALE" step must FAIL. The series folder is
# removed at the end. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

NAME=verify-cli-series
DIR="$ROOT/.workbench/series/$NAME"
rm -rf "$DIR"
mkdir -p "$DIR"
trap 'rm -rf "$DIR"' EXIT

cat >"$DIR/p1.md" <<'GOAL'
---
title: Series scenario goal
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

A throwaway goal file that a series names; no thread is made from it.

## Criteria

- [c1] Nothing changes.
  - proof: no thread exists

## Out of scope

- Everything.
GOAL
printf '## 1\nproject: %s\ngoal: p1.md\nbase: main\n\n## 2\nproject: %s\ngoal: p1.md\nbase: after 1\nenv: REF=step:1\n' "$ROOT" "$ROOT" >"$DIR/series.md"

RC=0
sx() { # sx <args...>: a workbench command; stdout in $SCRATCH/o, stderr in $SCRATCH/e, exit code in RC
    echo "workbench $*" >>"$SCRATCH/commands"
    with_timeout "$T_WB" "$WB" "$@" >"$SCRATCH/o" 2>"$SCRATCH/e"
    RC=$?
}
has() { grep -q -- "$1" "$SCRATCH/o"; }

sx series list
check "list: the series, 2 steps, not approved" "exit $RC: $(head -c 300 "$SCRATCH/o")" \
    bash -c '[ "$1" = 0 ] && grep -q "^'"$NAME"'  2 steps  not approved" "$2"' _ "$RC" "$SCRATCH/o"

sx series approve "$NAME"
check "approve: exit 0 and the steps shown" "exit $RC: $(head -c 400 "$SCRATCH/o") $(head -c 300 "$SCRATCH/e")" \
    bash -c '[ "$1" = 0 ] && grep -q "^approved '"$NAME"'" "$2" && grep -q "from the branch of step 1" "$2" && grep -q "env REF=<branch of step 1>" "$2"' _ "$RC" "$SCRATCH/o"
check "approve: no thread was created" "threads: $(ls "$ROOT/.workbench/threads" 2>/dev/null | head -3 | tr '\n' ' ')" \
    bash -c '! ls "$1/.workbench/threads" 2>/dev/null | grep -q "series"' _ "$ROOT"

sx series list
check "list after approve: approved" "$(head -c 300 "$SCRATCH/o")" has "2 steps  approved"

# The goal file changes (a new criterion): the approval no longer matches.
if [ "${VERIFY_CLI_SABOTAGE:-}" != 1 ]; then
    perl -0pi -e 's/## Out of scope/- [c2] Something else.\n  - proof: none\n\n## Out of scope/' "$DIR/p1.md"
fi
sx series list
check "list after a goal file changed: STALE" "$(head -c 300 "$SCRATCH/o")" has "STALE"

# Two problems in two steps are both listed, and nothing is approved.
printf '## 1\nproject: relative\ngoal: ../x.md\n## 2\nproject: %s\ngoal: missing.md\nafter: 5\n' "$ROOT" >"$DIR/series.md"
sx series approve "$NAME"
check "invalid: exit 6 and every problem listed" "exit $RC: $(head -c 500 "$SCRATCH/e")" \
    bash -c '[ "$1" = 6 ] && grep -q "step 1: .project. must be an absolute path" "$2" && grep -q "step 1: .goal. must be a file name" "$2" && grep -q "after. names step 5" "$2"' _ "$RC" "$SCRATCH/e"

sx series show no-such-series
check "no such series: exit 7" "exit $RC: $(head -c 300 "$SCRATCH/e")" test "$RC" = 7
finish
