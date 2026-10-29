#!/bin/bash
# verify-cli scenario for `workbench goal draft` with the REAL `codex` as the goal agent, on a clone of this repository.
#   bash scripts/verify-cli/goal-draft-codex.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/goal-draft-codex.sh   (the same, on a branch that contains origin/main)
# goal-draft.sh runs a stand-in `codex`, which proves what Workbench does with an answer; it cannot prove the real CLI starts. This
# one does: one real draft (read-only, no dollar cap, bounded at 300 s, a few seconds on a working login). It must exit 0, say it
# drafted, and leave a draft thread (never approved, Workbench's own front matter, a title and at least one criterion, the log with
# a goal.draft pair on codex and no coding turn). A Codex that will not start where the drafter runs it, is not on PATH, or has no
# login shows here and not in the stand-in. Uses Codex usage, not Claude's. Exit 0 only when every step passed, 1 when one failed, 2
# when it refused to start. VERIFY_CLI_SABOTAGE=1 points `[providers.codex]` at an executable that does not exist, so the steps that
# expect a draft must FAIL. The frame and the other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight
command -v codex >/dev/null 2>&1 || [ "$SABOTAGE" = 1 ] || die "no codex on PATH: this scenario drafts with the real one"

P="$SCRATCH/project"
g clone -q "$ROOT" "$P" || die "git clone failed"
BASE=verify-cli-base
git -C "$P" checkout -q -b "$BASE" || die "could not make the base branch in the clone"
echo "==> clone at $P, base $BASE"
[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: codex is an executable that does not exist"

RC=0
wbp() { # <out> args...: a workbench command in the clone, stdout and stderr together; sets RC
    local o=$1 secs=$2; shift 2
    echo "workbench $*   (in the clone)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    ( cd "$P" && with_timeout "$secs" "$WB" "$@" >"$o" 2>&1 )
    RC=$?
}
shown() { sed 's/^/    /' "$1" | head -${2:-12}; }
threads() { ls "$P/.workbench/threads" 2>/dev/null | wc -l | tr -d ' '; }
cfg="$P/.workbench/config.toml"

wbp "$SCRATCH/init.out" "$T_WB" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
grep -v -e '^model = ' "$cfg" >"$SCRATCH/config.rest"
{ cat "$SCRATCH/config.rest"
  [ "$SABOTAGE" = 1 ] && printf '\n[providers.codex]\nexecutable = "/no/such/codex"\n'
  printf '\n[agents.goal]\nprovider = "codex"\n'; } >"$cfg"

# --- a real draft -------------------------------------------------------------------------------------------

wbp "$SCRATCH/ok.out" "$T_RUN" goal draft real-codex --request "Add a short Troubleshooting section to the README that tells a reader to run workbench doctor first." --base "$BASE"
shown "$SCRATCH/ok.out" 8
check "the real codex drafts: exit 0" "workbench goal draft exited $RC; $(tail -1 "$SCRATCH/ok.out")" test "$RC" = 0
ID=$(sed -n 's/^drafted \([^ ]*\) .*/\1/p' "$SCRATCH/ok.out")
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { ID=""; fail "a draft thread was made" "goal draft printed no thread id ($(head -2 "$SCRATCH/ok.out" | tr '\n' ' '))"; finish; }
GOAL="$P/.workbench/threads/$ID/goal.md"
check "the goal is a draft with Workbench's own front matter" "front matter is not Workbench's" \
    bash -c 'grep -q "^status: draft" "$1" && grep -q "^base: $2" "$1" && grep -q "^id: $3" "$1" && ! grep -q -e "^approved" -e "^model:" "$1"' _ "$GOAL" "$BASE" "$ID"
check "it has a title and at least one criterion with a proof" "the goal has none" \
    bash -c 'grep -q "^title: ." "$1" && grep -q "\[c1\]" "$1" && grep -q "proof:" "$1"' _ "$GOAL"
wbp "$SCRATCH/log.out" "$T_WB" log "$ID"
check "the log has the draft pair on codex and no turn or approval" "log is not as expected" \
    bash -c 'grep -q "goal draft started on codex" "$1" && grep -q "goal draft finished" "$1" && ! grep -q -e "turn 1" -e "approved" "$1"' _ "$SCRATCH/log.out"
check "exactly one thread was made" "threads exist: $(threads)" test "$(threads)" = 1
finish
