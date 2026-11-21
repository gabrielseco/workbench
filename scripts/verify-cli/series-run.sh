#!/bin/bash
# verify-cli scenario for `series run` (P27 task 3b), on a clone of this repository. The clone's claude is /usr/bin/false, so no
# real turn runs, nothing is pushed and no pull request is opened: it costs nothing.
#   bash scripts/verify-cli/series-run.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/series-run.sh   (the same, on a branch that contains origin/main)
# A two-step series (step 2 stacks on step 1) in the clone: `series run` before `series approve` is refused (exit 6) and starts
# nothing; after approving it runs step 1 with the real binary (goal new --from, goal approve, run --thread), the run fails because
# claude is /usr/bin/false, and the series stops at step 1 (exit 1) with the command named, steps.jsonl recording the thread and
# why, `series status` showing STOPPED, and no thread for step 2. The accept and ship commands are not reached here: their
# argument shapes are covered by SeriesDriverTests, and a real ship would open a pull request. Exit 0 only when every step passed,
# 1 when one failed, 2 when it refused to start. VERIFY_CLI_SABOTAGE=1 skips `series approve`, so the second `series run` is
# refused and no step starts: the steps that expect step 1 to run and stop must FAIL. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

P="$SCRATCH/project"
g clone -q "$ROOT" "$P" || die "git clone failed"
echo "==> clone at $P"

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
agent=/usr/bin/false
# A series runs nothing unattended in a project with no check_command: this one has a check that passes.
grep -v -e '^claude_path = ' -e '^check_command = ' "$cfg" >"$SCRATCH/config.rest"
{ echo "claude_path = \"$agent\""; echo 'check_command = "true"'; cat "$SCRATCH/config.rest"; } >"$cfg"

SD="$P/.workbench/series/two"
mkdir -p "$SD"
for f in p1.md p2.md; do
cat >"$SD/$f" <<'GOAL'
---
title: Series run scenario goal
budget_usd: 0.50
turn_timeout_min: 5
---

## Request

A throwaway goal that a series step starts; claude here does nothing.

## Criteria

- [c1] Nothing changes.
  - proof: no run

## Out of scope

- Everything.
GOAL
done
printf '## 1\nproject: %s\ngoal: p1.md\n\n## 2\nproject: %s\ngoal: p2.md\nbase: after 1\n' "$P" "$P" >"$SD/series.md"
threads() { ls "$P/.workbench/threads" 2>/dev/null | sort; }

wbp "$SCRATCH/run0.out" series run two
check "run before approve: exit 6, nothing started" "exit $RC: $(head -c 300 "$SCRATCH/run0.out")" \
    bash -c '[ "$1" = 6 ] && grep -q "not approved" "$2" && [ -z "$(ls "$3/.workbench/threads" 2>/dev/null)" ]' _ "$RC" "$SCRATCH/run0.out" "$P"

if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: the series is not approved"
else
    wbp "$SCRATCH/approve.out" series approve two
    check "approve" "exit $RC" test "$RC" = 0
fi

wbp "$SCRATCH/run1.out" series run two
shown "$SCRATCH/run1.out" 14
check "the series stops at step 1 and names the command that failed" "exit $RC: $(head -c 500 "$SCRATCH/run1.out")" \
    bash -c '[ "$1" = 1 ] && grep -q "stopped at step 1: .run. exited" "$2"' _ "$RC" "$SCRATCH/run1.out"
check "exactly one thread was created, for step 1" "threads: $(threads | tr '\n' ' ')" \
    bash -c '[ "$(ls "$1/.workbench/threads" | wc -l | tr -d " ")" = 1 ] && ls "$1/.workbench/threads" | grep -q -- "-two-1$"' _ "$P"
check "steps.jsonl records that thread and why it stopped" "$(cat "$SD/steps.jsonl" 2>/dev/null | head -c 400)" \
    bash -c 'grep -q "\"step\":1" "$1" && grep -q "stopped\":\".run. exited" "$1"' _ "$SD/steps.jsonl"

wbp "$SCRATCH/status.out" series status two
check "status: STOPPED at step 1, nothing ready" "exit $RC: $(head -c 400 "$SCRATCH/status.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "^1. STOPPED" "$2" && grep -q "stopped at step 1" "$2" && ! grep -q "ready to start" "$2"' _ "$RC" "$SCRATCH/status.out"

wbp "$SCRATCH/run2.out" series run two
check "running again does not start step 2" "exit $RC; threads: $(threads | tr '\n' ' ')" \
    bash -c '[ "$1" = 1 ] && [ "$(ls "$2/.workbench/threads" | wc -l | tr -d " ")" = 1 ]' _ "$RC" "$P"
finish
