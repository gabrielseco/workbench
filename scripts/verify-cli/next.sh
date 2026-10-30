#!/bin/bash
# verify-cli scenario for `workbench next`: what is still due on a thread, from its log. On a clone of this repository in the
# temp folder. No turn is run, so it costs nothing: the scenario makes the thread's worktree, its `worktree.created` record and
# the events of a finished turn itself, as a run would.
#   bash scripts/verify-cli/next.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/next.sh   (the same, on a branch that contains origin/main)
# The project has a `design` review stage that applies to `Sources/**`, and the thread changed `Sources/change.txt`. Steps: after a
# finished turn `next` exits 0 and lists, in order, `workbench judge` (the first line, marked `next`), `workbench review-stage design`
# and `workbench accept`; `review` shows the same lines above its closing hint; after a `judge.ran` for the turn the first line is the design stage;
# after a `review_stage.finished` for it only `accept` is left; a thread whose change touches nothing the stage applies to does not
# list it; a goal that says `skip: judge, design` lists neither (under SABOTAGE the line is not written, so that step must FAIL); after the decision `accepted` the last step is `workbench ship`; a discarded thread says nothing is due. `next` writes no
# event. Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start (nothing changed).
# VERIFY_CLI_SABOTAGE=1 records the judge and the design stage as done before the first `next`, so the steps that expect them to be
# listed must FAIL. The frame is in lib.sh. Run by hand, not by CI.
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

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
cat >>"$P/.workbench/config.toml" <<'TOML'

[review]
stages = ["pr-review", "design"]

[review.stage.design]
skill = ".agents/skills/design-review/SKILL.md"
applies_to = ["Sources/**"]
TOML

cat >"$SCRATCH/goal.md" <<'GOAL'
---
title: Next steps
budget_usd: 1
turn_timeout_min: 30
---

## Request

Nothing runs: this thread only checks what `next` says is due.

## Criteria

- [c1] The steps are listed.
  - proof: the scenario reads the output

## Out of scope

- Any change to the code.
GOAL
wbp "$SCRATCH/new.out" goal new next-probe --from "$SCRATCH/goal.md" --base main
ID=$(created "$SCRATCH/new.out")
[ -n "$ID" ] || die "goal new made no thread: $(cat "$SCRATCH/new.out")"
wbp "$SCRATCH/approve.out" goal approve "$ID"
[ "$RC" = 0 ] || die "goal approve failed: $(cat "$SCRATCH/approve.out")"
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
mkdir -p "$WTP/Sources" && echo change >"$WTP/Sources/change.txt"
if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: the judge and the design stage are recorded as done before the first next"
    append judge.ran 1 '{"ok":true,"criteria":[{"id":"c1","met":true,"evidence":["x"]}],"concerns":[]}'
    append review_stage.finished 0 '{"stage":"design","verdict":"clean","ok":true}'
fi
LINES_BEFORE=$(wc -l <"$EVENTS" | tr -d ' ')

# --- a finished turn: judge, the design stage, then the decision ---------------------------------------------------

wbp "$SCRATCH/next1.out" next
shown "$SCRATCH/next1.out"
check "next exits 0 and lists judge, design and accept in that order" "exit $RC, steps: $(names "$SCRATCH/next1.out")" \
    bash -c 'test "$1" = 0 && test "$2" = "judge review-stage design accept "' _ "$RC" "$(names "$SCRATCH/next1.out")"
check "the first line is marked next and names the judge" "first line: $(head -1 "$SCRATCH/next1.out")" \
    bash -c 'head -1 "$1" | grep -q "^next  workbench judge "' _ "$SCRATCH/next1.out"
check "every printed command names the thread" "output: $(cat "$SCRATCH/next1.out")" \
    bash -c 'test "$(grep -c "workbench .* $2" "$1")" = 3' _ "$SCRATCH/next1.out" "$ID"
check "the design stage line names its command" "output: $(cat "$SCRATCH/next1.out")" \
    grep -q "workbench review-stage design" "$SCRATCH/next1.out"
wbp "$SCRATCH/review.out" review
check "review shows the same next lines above its closing hint" "review tail: $(tail -6 "$SCRATCH/review.out")" \
    bash -c 'grep -q "^next  workbench judge " "$1" && grep -q "^then  workbench accept" "$1" && tail -1 "$1" | grep -q "^accept | send-back"' _ "$SCRATCH/review.out"
check "next wrote no event" "the log grew" test "$(wc -l <"$EVENTS" | tr -d ' ')" = "$LINES_BEFORE"

# --- a judge for the turn, then the stage -----------------------------------------------------------------------------

if [ "$SABOTAGE" != 1 ]; then
    append judge.ran 1 '{"ok":true,"criteria":[{"id":"c1","met":true,"evidence":["x"]}],"concerns":[]}'
fi
wbp "$SCRATCH/next2.out" next
check "after the judge ran, the design stage is next" "first line: $(head -1 "$SCRATCH/next2.out")" \
    bash -c 'head -1 "$1" | grep -q "^next  workbench review-stage design "' _ "$SCRATCH/next2.out"
if [ "$SABOTAGE" != 1 ]; then
    append review_stage.finished 0 '{"stage":"design","verdict":"clean","ok":true}'
fi
wbp "$SCRATCH/next3.out" next
check "after the stage ran, only accept is left" "steps: $(names "$SCRATCH/next3.out")" \
    bash -c 'test "$1" = "accept "' _ "$(names "$SCRATCH/next3.out")"

# --- a change the stage does not apply to ---------------------------------------------------------------------------------

rm -f "$WTP/Sources/change.txt" && mkdir -p "$WTP/docs" && echo note >"$WTP/docs/note.md"
append turn.started 2 '{"session_id":"s2"}'
append turn.ended 2 '{"result":"succeeded","cost_usd":0.1}'
wbp "$SCRATCH/next4.out" next
check "a change that touches nothing under Sources lists no design stage" "steps: $(names "$SCRATCH/next4.out")" \
    bash -c 'test "$1" = "judge accept "' _ "$(names "$SCRATCH/next4.out")"

# --- a goal that skips the judge and the stage -------------------------------------------------------------------------

if [ "$SABOTAGE" != 1 ]; then
    python3 -I - "$P/.workbench/threads/$ID/goal.md" <<'PY' || die "could not add skip to the goal"
import sys
path = sys.argv[1]
lines = open(path).read().split("\n")
close = [i for i, l in enumerate(lines) if l == "---"][1]
lines.insert(close, "skip: judge, design")
open(path, "w").write("\n".join(lines))
PY
fi
rm -f "$WTP/docs/note.md" && mkdir -p "$WTP/Sources" && echo change >"$WTP/Sources/change.txt"
wbp "$SCRATCH/next4b.out" next
check "a goal that skips the judge and the design stage lists only accept" "steps: $(names "$SCRATCH/next4b.out")" \
    bash -c 'test "$1" = "accept "' _ "$(names "$SCRATCH/next4b.out")"

# --- after the decision ---------------------------------------------------------------------------------------------------

append review.decision 2 '{"decision":"accepted","by":"user","commit":"0000000"}'
wbp "$SCRATCH/next5.out" next
check "an accepted thread ends with ship" "steps: $(names "$SCRATCH/next5.out")" \
    bash -c 'tail -1 "$1" | grep -q "^then  workbench ship "' _ "$SCRATCH/next5.out"
append review.decision 2 '{"decision":"discarded","by":"user"}'
wbp "$SCRATCH/next6.out" next
check "a discarded thread says nothing is due" "output: $(cat "$SCRATCH/next6.out")" \
    bash -c 'test "$1" = 0 && grep -q "^nothing is due" "$2"' _ "$RC" "$SCRATCH/next6.out"
wbp "$SCRATCH/next7.out" next g-2000-01-01-nope
check "an unknown thread exits 7" "exit $RC" test "$RC" = 7
wbp "$SCRATCH/next8.out" next one two
check "two ids are a usage error" "exit $RC" test "$RC" = 2

finish
