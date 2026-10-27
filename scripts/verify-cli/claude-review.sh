#!/bin/bash
# verify-cli scenario for the automated review on Claude (P9 PR 13), on a clone of this repository. The coding agent and the
# reviewer are both the `fake-claude` test double, so nothing real is started and it costs nothing. It exists because a review on
# Claude was refused ("claude cannot enforce a dollar limit") by a RELEASE build of the same source that a debug build ran: the unit
# tests only run in debug, so only this can see it.
#   bash scripts/verify-cli/claude-review.sh                          (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_BUILD=release bash scripts/verify-cli/claude-review.sh  (the same on the optimized binary)
#   VERIFY_CLI_FROM_BRANCH=1 ...                                       (on a branch that contains origin/main)
# With `[agents.review] provider = "claude"`: a thread whose fake coding turn edited a file and was accepted is reviewed
# (`workbench pr-review`, the thread's own branch, no pull request needed). The review must be started, not refused for a dollar
# limit; its argv on record must name claude and a `--max-budget-usd` cap; a CLEAN verdict must be recorded and exit 0.
# Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start. VERIFY_CLI_SABOTAGE=1 chooses Codex for the
# review (not installed, forbidden by allow_unpriced = false), so the steps that expect a Claude review must FAIL. The frame and the other switches are in
# lib.sh. Run by hand and in CI (release), never with a real agent.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the review is configured for codex (absent, allow_unpriced = false)"

echo "==> building fake-claude ($BUILD)"
with_timeout "$T_BUILD" swift build ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} --product fake-claude || die "swift build of fake-claude failed"
FAKE_CLAUDE_BIN="$ROOT/.build/$BUILD/fake-claude"
[ -x "$FAKE_CLAUDE_BIN" ] || die "no $FAKE_CLAUDE_BIN after the build"

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

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
grep -v -e '^model = ' -e '^claude_path = ' -e '^env_pass = ' "$cfg" >"$SCRATCH/config.rest"
REVIEW='provider = "claude"'
[ "$SABOTAGE" = 1 ] && REVIEW='provider = "codex"
allow_unpriced = false'
{ printf 'claude_path = "%s"\nenv_pass = ["FAKE_CLAUDE"]\n' "$FAKE_CLAUDE_BIN"; cat "$SCRATCH/config.rest"
  printf '\n[providers.codex]\nexecutable = "/nonexistent/codex"\n\n[agents.review]\n%s\n' "$REVIEW"; } >"$cfg"

cat >"$SCRATCH/goal.md" <<'GOAL'
---
id: verify-cli-claude-review
title: verify-cli review on claude scenario
base: verify-cli-base
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

A throwaway thread for a review on Claude; both agents are the test double.

## Criteria

- [c1] A file is added.
  - proof: the log

## Out of scope

- Everything else.
GOAL
wbp "$SCRATCH/new.out" goal new verify-cli-claude-review --base "$BASE" --from "$SCRATCH/goal.md"
ID=$(sed -n 's/^created //p' "$SCRATCH/new.out")
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id ($(head -3 "$SCRATCH/new.out"))"
wbp "$SCRATCH/approve.out" goal approve "$ID"

# The fake coding turn adds a line to notes.txt in the worktree; accept commits it.
export FAKE_CLAUDE="write=notes.txt"
wbp "$SCRATCH/run.out" run "$ID"
shown "$SCRATCH/run.out" 4
check "the fake coding turn succeeds" "workbench run exited $RC" test "$RC" = 0
wbp "$SCRATCH/accept.out" accept "$ID" --yes -m "verify-cli: claude review scenario"
check "the work is accepted" "workbench accept exited $RC" test "$RC" = 0

# The reviewer: the same double, answering with a clean verdict.
printf 'Nothing to fix.\nVERDICT: CLEAN\n' >"$SCRATCH/answer.txt"
export FAKE_CLAUDE="answer=$SCRATCH/answer.txt"
wbp "$SCRATCH/review.out" pr-review "$ID"
shown "$SCRATCH/review.out" 6
check "the review is not refused for a dollar limit" "the review was refused: $(grep -m1 'dollar limit' "$SCRATCH/review.out")" \
    bash -c '! grep -q "cannot enforce a dollar limit" "$1"' _ "$SCRATCH/review.out"
check "the review ends with a clean verdict: exit 0" "workbench pr-review exited $RC" test "$RC" = 0
EVENTS="$P/.workbench/threads/$ID/events.jsonl"
check "the review's argv on record names claude's cap" "pr_review.started has no --max-budget-usd" \
    bash -c 'grep "\"kind\":\"pr_review.started\"" "$1" | grep -q "\"--max-budget-usd\""' _ "$EVENTS"
check "the round was recorded as claude and finished ok" "pr_review.finished is not ok on claude" \
    bash -c 'grep "\"kind\":\"pr_review.finished\"" "$1" | tail -1 | grep -q "\"ok\":true" && grep "\"kind\":\"pr_review.finished\"" "$1" | tail -1 | grep -q "\"provider\":\"claude\""' _ "$EVENTS"
check "the recorded attempt is a spawned claude attempt" "no spawned review attempt on claude" \
    bash -c 'grep "\"kind\":\"agent.attempt.started\"" "$1" | grep "\"role\":\"review\"" | grep "\"provider\":\"claude\"" | grep -vq "\"spawned\":false"' _ "$EVENTS"
finish
