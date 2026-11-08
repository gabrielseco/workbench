#!/bin/bash
# verify-cli scenario for `workbench sync --run` (P23 slice 6, part 2), with the real `claude`, on a clone of this repository with an
# origin of its own in the scratch folder. It starts TWO real turns, each capped at VERIFY_CLI_BUDGET_USD (default 0.50) on
# VERIFY_CLI_MODEL (default haiku), so it costs up to about twice that. Run by hand, never in CI.
#   bash scripts/verify-cli/sync-run.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/sync-run.sh   (the same, on a branch that contains origin/main)
# A thread's first turn writes story.txt (`mine`). Another clone pushes a story.txt (`theirs`) to the base: the two add the same file,
# a conflict. `sync --run` merges, stops on the conflict, and starts a second turn from Workbench's note; the turn must end well,
# story.txt must hold no conflict markers, the log must show base.synced (conflicts) and exactly one turn.ended per turn.started, and
# a `sync --run` with nothing to bring in must start no turn (exit 0).
# Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start (nothing changed).
# VERIFY_CLI_SABOTAGE=1 does not push the other clone's file, so the base never moves: the steps that need the conflict must FAIL.
# The frame and the other switches are in lib.sh.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the other clone's file is not pushed"

P="$SCRATCH/project"
O="$SCRATCH/origin.git"
Q="$SCRATCH/other"
g clone -q "$ROOT" "$P" || die "git clone failed"
BASE=verify-cli-base
git -C "$P" checkout -q -b "$BASE" || die "could not make the base branch in the clone"
git init -q --bare "$O" || die "could not make the origin"
git -C "$P" remote set-url origin "$O" && git -C "$P" push -q origin "$BASE" || die "could not push the base to the origin"
# The project's own config (the real claude, its tools) comes from the main checkout, as from-branch.sh copies it.
[ -f "$ROOT/.workbench/config.toml" ] && mkdir -p "$P/.workbench" && cp "$ROOT/.workbench/config.toml" "$P/.workbench/config.toml"
echo "==> clone at $P, origin $O, base $BASE"

RC=0
wbp() { # <timeout> <out> args...: a workbench command in the clone, stdout and stderr together; sets RC
    local t=$1 o=$2; shift 2
    echo "workbench $*   (in the clone)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    ( cd "$P" && with_timeout "$t" "$WB" "$@" >"$o" 2>&1 )
    RC=$?
}
shown() { sed 's/^/    /' "$1" | head -${2:-10}; }
IDENT=(-c user.name=verify-cli -c user.email=verify-cli@localhost)

[ -f "$P/.workbench/config.toml" ] || { wbp "$T_WB" "$SCRATCH/init.out" init; }
GOAL="$SCRATCH/goal.md"
cat >"$GOAL" <<'GOALEOF'
---
id: verify-cli-sync-run
title: verify-cli sync --run scenario
base: verify-cli-base
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

Create the file `story.txt` in the repository root holding the single line `mine`. This is a throwaway thread that tests
`workbench sync --run`; its branch is deleted afterwards.

## Criteria

- [c1] `story.txt` exists and, apart from any change that brings in newer work from the base, holds the line `mine`.
  - proof: the diff shows story.txt

## Out of scope

- Any other file.
GOALEOF

wbp "$T_WB" "$SCRATCH/new.out" goal new verify-sync-run --base "$BASE" --from "$GOAL"
ID=$(sed -n 's/^created //p' "$SCRATCH/new.out")
check "a thread is started" "exit $RC, id '$ID'" test "$RC" = 0 -a -n "$ID"
perl -pi -e "s/^budget_usd: .*/budget_usd: $BUDGET_USD/; s/^turn_timeout_min: .*/turn_timeout_min: $TURN_TIMEOUT_MIN/; s/^# model: .*/model: $MODEL/" \
    "$P/.workbench/threads/$ID/goal.md"
wbp "$T_WB" "$SCRATCH/approve.out" goal approve "$ID"
check "the goal is approved" "exit $RC: $(head -c 200 "$SCRATCH/approve.out")" test "$RC" = 0
wbp "$T_RUN" "$SCRATCH/run1.out" run "$ID"
shown "$SCRATCH/run1.out" 6
check "turn 1 succeeds" "exit $RC" test "$RC" = 0
WT="$P/.workbench/worktrees/$ID"
check "turn 1 wrote story.txt" "no story.txt in $WT" test -f "$WT/story.txt"

# --- nothing to bring in: no turn is started ---------------------------------------------------------------

wbp "$T_WB" "$SCRATCH/n0.out" sync --run "$ID"
check "sync --run with nothing to bring in: exit 0 and no turn" "exit $RC: $(head -c 200 "$SCRATCH/n0.out")" \
    bash -c 'test "$1" = 0 && ! grep -q "starting a turn" "$2"' _ "$RC" "$SCRATCH/n0.out"

# --- the conflict, resolved by a turn -----------------------------------------------------------------------

git clone -q "$O" "$Q" && git -C "$Q" checkout -q "$BASE" || die "the other clone could not start"
printf 'theirs\n' >"$Q/story.txt"
git -C "$Q" add story.txt && git -C "$Q" "${IDENT[@]}" commit -q --no-verify -m "land story.txt" || die "the other clone could not commit"
[ "$SABOTAGE" = 1 ] || git -C "$Q" push -q origin "$BASE" || die "the other clone could not push"

wbp "$T_RUN" "$SCRATCH/y1.out" sync --run "$ID"
shown "$SCRATCH/y1.out" 14
check "sync --run: stopped on the conflict, then started a turn" "$(head -c 300 "$SCRATCH/y1.out")" \
    bash -c 'grep -q "story.txt" "$1" && grep -q "starting a turn" "$1"' _ "$SCRATCH/y1.out"
check "sync --run: the turn ended well (exit 0)" "exit $RC" test "$RC" = 0
check "story.txt holds no conflict markers" "$(cat "$WT/story.txt" 2>/dev/null | head -5)" \
    bash -c 'test -s "$1" && ! grep -qE "^(<<<<<<<|=======|>>>>>>>)" "$1"' _ "$WT/story.txt"
EVENTS="$P/.workbench/threads/$ID/events.jsonl"
check "the log has base.synced as conflicts" "no such event" \
    bash -c 'grep "\"base.synced\"" "$1" | grep -q "\"result\":\"conflicts\""' _ "$EVENTS"
check "the second turn's prompt carries the sync note" "no turn-2 prompt naming story.txt" \
    bash -c 'grep -q "story.txt" "$1"' _ "$P/.workbench/threads/$ID/prompts/turn-2.md"
check "one turn.ended per turn.started" "$(grep -c '"turn.started"' "$EVENTS") started, $(grep -c '"turn.ended"' "$EVENTS") ended" \
    bash -c 'test "$(grep -c "\"turn.started\"" "$1")" = "$(grep -c "\"turn.ended\"" "$1")"' _ "$EVENTS"

git -C "$P" worktree remove --force "$WT" >/dev/null 2>&1
git -C "$P" branch -D "workbench/$ID" >/dev/null 2>&1
finish
