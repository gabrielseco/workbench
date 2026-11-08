#!/bin/bash
# verify-cli scenario for `workbench sync` and the base_moved line of `status` (P23 slice 6), on a clone of this repository with an
# origin of its own in the scratch folder. No turn is run, so it costs nothing.
#   bash scripts/verify-cli/sync.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/sync.sh   (the same, on a branch that contains origin/main)
# A thread has a worktree and a change of its own. Before origin's base moves, `status --fetch` says nothing about it and `sync`
# says there is nothing to bring in (exit 0). After another clone pushes a new file to the base, `status --fetch` says the base
# moved by 1 commit and none touch the thread's files (and `--json` has base_moved.behind 1), `sync` merges it (exit 0, the file is in
# the worktree, base.synced is in the log) and a second `sync` finds nothing. After a push that conflicts with work the thread has not
# committed, `sync` keeps that work in a commit, stops on the conflict (exit 1, the file named, markers in it, the merge left in
# progress), and a further `sync` is refused (exit 6) instead of stacking a merge on it. A thread that does not exist is exit 7.
# Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start (nothing changed).
# VERIFY_CLI_SABOTAGE=1 does not push the two new commits, so the base never moves: the steps that need it to must FAIL.
# The frame and the other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the other clone's commits are not pushed"

P="$SCRATCH/project"
O="$SCRATCH/origin.git"
Q="$SCRATCH/other"
g clone -q "$ROOT" "$P" || die "git clone failed"
BASE=verify-cli-base
git -C "$P" checkout -q -b "$BASE" || die "could not make the base branch in the clone"
git init -q --bare "$O" || die "could not make the origin"
git -C "$P" remote set-url origin "$O" && git -C "$P" push -q origin "$BASE" || die "could not push the base to the origin"
echo "==> clone at $P, origin $O, base $BASE"

RC=0
wbp() { # <out> args...: a workbench command in the clone, stdout and stderr together; sets RC
    local o=$1; shift
    echo "workbench $*   (in the clone)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    ( cd "$P" && with_timeout "$T_WB" "$WB" "$@" >"$o" 2>&1 )
    RC=$?
}
shown() { sed 's/^/    /' "$1" | head -${2:-8}; }
IDENT=(-c user.name=verify-cli -c user.email=verify-cli@localhost)
land() { # <file> <text>: the other clone adds a file to the base on origin (not with VERIFY_CLI_SABOTAGE=1)
    [ -d "$Q" ] || git clone -q "$O" "$Q" || return 1
    git -C "$Q" checkout -q "$BASE" 2>/dev/null || git -C "$Q" checkout -q -b "$BASE" "origin/$BASE" || return 1
    git -C "$Q" pull -q --ff-only origin "$BASE" || return 1
    printf '%s\n' "$2" >"$Q/$1"
    git -C "$Q" add "$1" && git -C "$Q" "${IDENT[@]}" commit -q --no-verify -m "land $1" || return 1
    [ "$SABOTAGE" = 1 ] || git -C "$Q" push -q origin "$BASE"
}

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
wbp "$SCRATCH/new.out" goal new verify-sync --base "$BASE"
ID=$(sed -n 's/^created //p' "$SCRATCH/new.out")
check "a thread is started" "exit $RC, id '$ID'" test "$RC" = 0 -a -n "$ID"
WT="$P/.workbench/worktrees/$ID"
# The run makes the worktree; here it is made by hand, the way it would be, so no turn is spent.
git -C "$P" worktree add -q -b "workbench/$ID" "$WT" "$BASE" || die "could not make the thread's worktree"
printf 'mine\n' >"$WT/clash.txt"
printf 'mine\n' >"$WT/thread-note.txt"

# --- 1. the base has not moved ---------------------------------------------------------------------------

wbp "$SCRATCH/s0.out" status --fetch
check "status --fetch: nothing is said about a moved base" "a 'moved:' line: $(grep -m1 '^moved:' "$SCRATCH/s0.out")" \
    bash -c '! grep -q "^moved:" "$1"' _ "$SCRATCH/s0.out"
wbp "$SCRATCH/y0.out" sync
shown "$SCRATCH/y0.out"
check "sync with nothing to bring in: exit 0 and says so" "exit $RC: $(head -c 200 "$SCRATCH/y0.out")" \
    bash -c 'test "$1" = 0 && grep -q "has not moved" "$2"' _ "$RC" "$SCRATCH/y0.out"

# `--run` starts a turn from the sync's note, so a thread with no turn yet is refused before anything is merged (the paid half of
# `--run` is scripts/verify-cli/sync-run.sh); `--budget` belongs to that turn.
wbp "$SCRATCH/r0.out" sync --run
check "sync --run on a thread with no turn: refused (exit 6) before merging" "exit $RC: $(head -c 200 "$SCRATCH/r0.out")" \
    bash -c 'test "$1" = 6 && ! git -C "$2" rev-parse -q --verify MERGE_HEAD >/dev/null' _ "$RC" "$WT"
wbp "$SCRATCH/r2.out" sync --run --budget 101
check "sync --run --budget over the ceiling: usage error (exit 2) before merging" "exit $RC: $(head -c 200 "$SCRATCH/r2.out")" \
    bash -c 'test "$1" = 2 && ! git -C "$2" rev-parse -q --verify MERGE_HEAD >/dev/null' _ "$RC" "$WT"
wbp "$SCRATCH/r1.out" sync --budget 1
check "sync --budget without --run: usage error (exit 2)" "exit $RC: $(head -c 200 "$SCRATCH/r1.out")" test "$RC" = 2

# --- 2. a new file on the base: merges cleanly -------------------------------------------------------------

land landed.txt "theirs" || die "the other clone could not push"
wbp "$SCRATCH/s1.out" status --fetch
shown "$SCRATCH/s1.out" 30 | grep -i moved
check "status --fetch: says the base moved by 1 commit, none touching the thread's files" "$(grep -m1 '^moved:' "$SCRATCH/s1.out")" \
    grep -q "^moved:.*moved by 1 commit; none touch files this thread changed" "$SCRATCH/s1.out"
wbp "$SCRATCH/j1.out" status --fetch --json
check "status --fetch --json: base_moved.behind is 1" "$(head -c 300 "$SCRATCH/j1.out")" \
    bash -c 'python3 -I -c "import json,sys; m=json.load(open(sys.argv[1]))[\"base_moved\"]; sys.exit(not (m and m[\"behind\"]==1 and m[\"overlapping\"]==[]))" "$1"' _ "$SCRATCH/j1.out"
wbp "$SCRATCH/y1.out" sync
shown "$SCRATCH/y1.out"
check "sync: merged (exit 0)" "exit $RC: $(head -c 200 "$SCRATCH/y1.out")" \
    bash -c 'test "$1" = 0 && grep -q "merged origin/.* (1 commit)" "$2"' _ "$RC" "$SCRATCH/y1.out"
check "sync: the landed file is in the worktree, the thread's own work too" "files: $(ls "$WT" | tr '\n' ' ')" \
    bash -c 'test -f "$1/landed.txt" && test -f "$1/thread-note.txt"' _ "$WT"
check "sync: the log records base.synced as merged" "no such event" \
    bash -c 'grep "\"base.synced\"" "$1" | grep -q "\"result\":\"merged\""' _ "$P/.workbench/threads/$ID/events.jsonl"
wbp "$SCRATCH/y2.out" sync
check "a second sync finds nothing to bring in" "exit $RC: $(head -c 200 "$SCRATCH/y2.out")" \
    bash -c 'test "$1" = 0 && grep -q "has not moved" "$2"' _ "$RC" "$SCRATCH/y2.out"

# --- 3. a conflict with work that is not committed ----------------------------------------------------------

land clash.txt "theirs" || die "the other clone could not push"
wbp "$SCRATCH/y3.out" sync
shown "$SCRATCH/y3.out" 12
check "sync on a conflict: exit 1, the file named" "exit $RC: $(head -c 200 "$SCRATCH/y3.out")" \
    bash -c 'test "$1" = 1 && grep -q "clash.txt" "$2" && grep -q "left in progress" "$2"' _ "$RC" "$SCRATCH/y3.out"
check "sync on a conflict: markers are in the file and the merge is in progress" "no markers or no MERGE_HEAD" \
    bash -c 'grep -q "^<<<<<<<" "$1/clash.txt" && git -C "$1" rev-parse -q --verify MERGE_HEAD >/dev/null' _ "$WT"
check "sync on a conflict: the uncommitted work was saved in a commit first" "git log: $(git -C "$WT" log --format=%s -3 | tr '\n' '|')" \
    bash -c 'git -C "$1" log --format=%s -5 | grep -q "save work before bringing"' _ "$WT"
wbp "$SCRATCH/y4.out" sync
check "a further sync is refused (exit 6) while the merge is unfinished" "exit $RC: $(head -c 200 "$SCRATCH/y4.out")" \
    bash -c 'test "$1" = 6 && grep -q "already in progress" "$2"' _ "$RC" "$SCRATCH/y4.out"
wbp "$SCRATCH/y5.out" sync --thread no-such-thread
check "a thread that does not exist: not found (exit 7)" "exit $RC" test "$RC" = 7

git -C "$P" worktree remove --force "$WT" >/dev/null 2>&1
finish
