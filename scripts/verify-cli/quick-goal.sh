#!/bin/bash
# verify-cli scenario for quick goals: `workbench goal new <name> --quick "<text>"` and what a goal without criteria does to
# `next`, `review` and `judge`. On a clone of this repository in the temp folder. No turn is run and no agent is started, so it
# costs nothing: the clone's claude_path names no file, and the scenario writes the thread's worktree and the events of a
# finished turn itself, as a run would.
#   bash scripts/verify-cli/quick-goal.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/quick-goal.sh   (the same, on a branch that contains origin/main)
# Steps: `goal new --quick` exits 0 and writes a draft goal with `quick: true`, no criteria and the request exactly as typed (a
# blank line and an indented line kept); `goal approve` takes it; after a finished turn `next` lists only `accept` (no judge);
# `review` says `Judge      not available` and why; `judge` is refused (exit 6) saying the goal has no criteria, and writes no
# event; `--quick` with only blanks is refused (exit 6) and with `--from` is a usage error (exit 2), both making no thread.
# Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start (nothing changed).
# VERIFY_CLI_SABOTAGE=1 turns the goal into an ordinary one (no `quick`, one criterion) before it is approved, so the steps that
# expect no judge (`next`, `review`, `judge` refused) must FAIL. The frame is in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

P="$SCRATCH/project"
g clone -q "$ROOT" "$P" || die "git clone failed"
g -C "$P" checkout -q -B main "$BASE_SHA" || die "could not check out main in the clone"
echo "==> clone at $P"

RC=0
wbp() { # <out> args...: a workbench command in the clone, stdout and stderr together; sets RC
    local o=$1; shift
    echo "workbench $*   (in the clone)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    ( cd "$P" && with_timeout "$T_WB" "$WB" "$@" >"$o" 2>&1 )
    RC=$?
}
shown() { sed 's/^/    /' "$1" | head -${2:-8}; }
created() { sed -n 's/^created //p' "$1"; }
names() { sed -n -E 's/^(next|then)  workbench (review-stage [a-z-]+|[a-z-]+).*/\2/p' "$1" | tr '\n' ' '; }
threads() { ls "$P/.workbench/threads" 2>/dev/null | wc -l | tr -d ' '; }

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
# No agent can start, whatever a step does: a judge that was not refused finds no claude and spends nothing.
python3 -I - "$P/.workbench/config.toml" <<'PY' || die "could not point claude_path nowhere"
import sys
path = sys.argv[1]
open(path, "w").write('claude_path = "/nonexistent/claude-for-verify-cli"\n' + open(path).read())
PY

REQUEST=$'Make the header blue.\n\n  and keep   the logo where it is'
wbp "$SCRATCH/new.out" goal new quick-probe --quick "$REQUEST" --base main
shown "$SCRATCH/new.out"
ID=$(created "$SCRATCH/new.out")
check "goal new --quick exits 0 and makes a thread" "exit $RC: $(cat "$SCRATCH/new.out")" \
    bash -c 'test "$1" = 0 && test -n "$2"' _ "$RC" "$ID"
[ -n "$ID" ] || die "goal new made no thread: $(cat "$SCRATCH/new.out")"
GOAL="$P/.workbench/threads/$ID/goal.md"
check "the goal is a draft marked quick: true, with no criteria" "goal: $(cat "$GOAL")" \
    bash -c 'grep -qx "quick: true" "$1" && grep -qx "status: draft" "$1" && ! grep -q "^- \[c[0-9]" "$1"' _ "$GOAL"
check "the request is kept exactly as typed" "goal: $(cat "$GOAL")" \
    python3 -I -c 'import sys; sys.exit(0 if ("## Request\n\n" + sys.argv[2] + "\n\n") in open(sys.argv[1]).read() else 1)' \
    "$GOAL" "$REQUEST"

if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: the goal becomes an ordinary one with a criterion before it is approved"
    python3 -I - "$GOAL" <<'PY' || die "could not sabotage the goal"
import sys
path = sys.argv[1]
text = open(path).read().replace("quick: true\n", "")
text = text.replace("## Criteria\n", "## Criteria\n\n- [c1] The header is blue.\n  - proof: the scenario reads it\n")
open(path, "w").write(text)
PY
fi
wbp "$SCRATCH/approve.out" goal approve "$ID"
check "goal approve takes the quick goal" "exit $RC: $(cat "$SCRATCH/approve.out")" test "$RC" = 0

WTP="$P/.workbench/worktrees/$ID"
g -C "$P" worktree add -q -b "workbench/$ID" "$WTP" main || die "could not add the thread's worktree"
EVENTS="$P/.workbench/threads/$ID/events.jsonl"
append() { # <kind> <turn> <json data>: one event at the end of the thread's log, as the writer would number it
    python3 -I - "$EVENTS" "$1" "$2" "$3" <<'PY' || die "could not append $1"
import json, sys
path, kind, turn, data = sys.argv[1:5]
last = json.loads(open(path).read().splitlines()[-1])
event = {"v": 1, "seq": last["seq"] + 1, "ts": last["ts"], "turn": int(turn), "kind": kind, "data": json.loads(data)}
open(path, "a").write(json.dumps(event, separators=(",", ":")) + "\n")
PY
}
append worktree.created 0 "{\"path\":\"$WTP\",\"branch\":\"workbench/$ID\",\"base_commit\":\"$BASE_SHA\"}"
append turn.started 1 '{"session_id":"s1"}'
append turn.ended 1 '{"result":"succeeded","cost_usd":0.1}'
echo blue >"$WTP/header.txt"
LINES_BEFORE=$(wc -l <"$EVENTS" | tr -d ' ')

# --- after a finished turn: no judge is due, and it says why ------------------------------------------------------------

wbp "$SCRATCH/next.out" next "$ID"
shown "$SCRATCH/next.out"
check "next lists only accept: no judge for a goal without criteria" "exit $RC, steps: $(names "$SCRATCH/next.out")" \
    bash -c 'test "$1" = 0 && test "$2" = "accept "' _ "$RC" "$(names "$SCRATCH/next.out")"
wbp "$SCRATCH/review.out" review "$ID"
check "review says the judge is not available and why" "review: $(grep -E '^(Judge|Criteria|  \()' "$SCRATCH/review.out")" \
    grep -q "^Judge      not available: the goal has no criteria" "$SCRATCH/review.out"
wbp "$SCRATCH/judge.out" judge "$ID"
shown "$SCRATCH/judge.out"
check "judge is refused (exit 6), saying the goal has no criteria" "exit $RC: $(cat "$SCRATCH/judge.out")" \
    bash -c 'test "$1" = 6 && grep -q "has no criteria" "$2"' _ "$RC" "$SCRATCH/judge.out"
check "next, review and judge wrote no event" "the log grew" test "$(wc -l <"$EVENTS" | tr -d ' ')" = "$LINES_BEFORE"

# --- what --quick refuses ----------------------------------------------------------------------------------------------

BEFORE=$(threads)
wbp "$SCRATCH/blank.out" goal new blank-probe --quick "   " --base main
check "a blank --quick is refused (exit 6) and makes no thread" "exit $RC: $(cat "$SCRATCH/blank.out")" \
    bash -c 'test "$1" = 6 && grep -q "request is empty" "$2" && test "$3" = "$4"' _ "$RC" "$SCRATCH/blank.out" "$(threads)" "$BEFORE"
echo "---" >"$SCRATCH/other.md"
wbp "$SCRATCH/both.out" goal new both-probe --quick "x" --from "$SCRATCH/other.md"
check "--quick with --from is a usage error (exit 2)" "exit $RC: $(cat "$SCRATCH/both.out")" \
    bash -c 'test "$1" = 2 && test "$2" = "$3"' _ "$RC" "$(threads)" "$BEFORE"

finish
