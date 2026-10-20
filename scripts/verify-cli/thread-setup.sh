#!/bin/bash
# verify-cli scenario for how a thread is set up and shipped: the default base, `goal new --from` front matter, and
# `ship` refusing a base that is not on origin. On a clone of this repository whose origin is a bare copy in the temp
# folder, so nothing is pushed anywhere real. No turn is run, so it costs nothing.
#   bash scripts/verify-cli/thread-setup.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/thread-setup.sh   (the same, on a branch that contains origin/main)
# With a feature branch checked out in the clone, `goal new` without --base must base the thread on main (origin/HEAD)
# and print `base: main`; `goal new --from` a file with `budget_usd: 7`, `base` and `status` must report 7 in
# `status --json` and name base and status as ignored; `ship` of an accepted thread whose base exists only in the clone
# must exit 6 (refused), name the base, and push nothing. Exit 0 only when every step passed, 1 when one failed, 2 when
# it refused to start (nothing changed). VERIFY_CLI_SABOTAGE=1 pushes the local base to the origin before `ship`, so the
# steps that expect the refusal (exit 6, the base named, nothing pushed) must FAIL. The frame is in lib.sh.
# Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

# A bare origin in the temp folder and a clone of it: origin/HEAD is main, and a push lands only in the temp folder.
ORIGIN="$SCRATCH/origin.git"
P="$SCRATCH/project"
g clone -q --bare "$ROOT" "$ORIGIN" || die "git clone --bare failed"
# Run from a branch, the copy's HEAD would be that branch: its main is origin's main and its HEAD points there.
g -C "$ORIGIN" update-ref refs/heads/main "$BASE_SHA" || die "could not set main in the bare copy"
g -C "$ORIGIN" symbolic-ref HEAD refs/heads/main || die "could not point the bare copy's HEAD at main"
g clone -q "$ORIGIN" "$P" || die "git clone failed"
g -C "$P" checkout -q -B main origin/main || die "could not check out main in the clone"
FEATURE=verify-cli-feature
LOCAL_BASE=verify-cli-local-base
g -C "$P" checkout -q -b "$FEATURE" || die "could not make $FEATURE in the clone"
g -C "$P" branch -q "$LOCAL_BASE" main || die "could not make $LOCAL_BASE in the clone"
echo "==> clone at $P on $FEATURE, origin $ORIGIN"

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

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0

# --- 1. the default base ------------------------------------------------------------------------------------

wbp "$SCRATCH/new1.out" goal new default-base
shown "$SCRATCH/new1.out" 4
check "goal new without --base: exit 0" "workbench goal new exited $RC" test "$RC" = 0
check "goal new prints the base it resolved: main" "no 'base:    main' line" grep -q "^base: *main$" "$SCRATCH/new1.out"
ID1=$(created "$SCRATCH/new1.out")
wbp "$SCRATCH/st1.json" status "$ID1" --json
base1=$(py "print(d['goal']['base'])" <"$SCRATCH/st1.json" 2>/dev/null)
check "the thread's base is main, not the checked-out $FEATURE" "status --json says base '$base1'" test "$base1" = main
wbp "$SCRATCH/ab1.out" abandon
check "abandon ends the first thread" "workbench abandon exited $RC" test "$RC" = 0

# --- 2. goal new --from carries the budget ------------------------------------------------------------------

cat >"$SCRATCH/goal.md" <<'GOAL'
---
id: g-2026-01-01-elsewhere
title: From another repo
status: approved
base: release
budget_usd: 7
turn_timeout_min: 30
---

## Request

Nothing runs: this thread only checks how it is set up and shipped.

## Criteria

- [c1] The thread is set up from this file.
  - proof: the scenario reads status --json

## Out of scope

- Any change to the code.
GOAL
wbp "$SCRATCH/new2.out" goal new from-file --from "$SCRATCH/goal.md" --base "$LOCAL_BASE"
shown "$SCRATCH/new2.out" 5
check "goal new --from: exit 0" "workbench goal new exited $RC" test "$RC" = 0
check "goal new --from names the ignored keys" "no 'ignored from the file:' line naming base and status" \
    bash -c 'grep "^ignored from the file: " "$1" | grep -q "base" && grep "^ignored from the file: " "$1" | grep -q "status"' \
    _ "$SCRATCH/new2.out"
ID2=$(created "$SCRATCH/new2.out")
wbp "$SCRATCH/st2.json" status "$ID2" --json
budget=$(py "print(d['goal']['budget_usd'])" <"$SCRATCH/st2.json" 2>/dev/null)
check "status --json reports the file's budget_usd: 7" "status --json says budget_usd '$budget'" \
    python3 -I -c "import sys; sys.exit(0 if float(sys.argv[1]) == 7 else 1)" "${budget:-0}"

# --- 3. ship refuses a base that is not on origin -----------------------------------------------------------

wbp "$SCRATCH/approve.out" goal approve "$ID2"
check "goal approve: exit 0" "workbench goal approve exited $RC" test "$RC" = 0
# No turn: the thread's worktree and branch are made here, as a run would, with one file to accept.
WTP="$P/.workbench/worktrees/$ID2"
g -C "$P" worktree add -q -b "workbench/$ID2" "$WTP" "$LOCAL_BASE" || die "could not add the thread's worktree"
echo "made by the verify-cli scenario" >"$WTP/verify-cli-setup.txt"
wbp "$SCRATCH/accept.out" accept "$ID2" -m "chore: verify-cli thread setup" --yes
check "accept: exit 0" "workbench accept exited $RC" test "$RC" = 0

if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: $LOCAL_BASE is pushed to the origin before ship"
    g -C "$P" push -q origin "$LOCAL_BASE"
fi
wbp "$SCRATCH/ship.out" ship "$ID2" --yes --no-describe
shown "$SCRATCH/ship.out" 6
check "ship with the base only in the clone: exit 6 (refused)" "workbench ship exited $RC" test "$RC" = 6
check "the refusal names the base and says to push it or change it" "no 'origin has no branch $LOCAL_BASE' message" \
    bash -c 'grep -q "origin has no branch $2" "$1" && grep -q "Push it" "$1" && grep -q "goal.s base" "$1"' \
    _ "$SCRATCH/ship.out" "$LOCAL_BASE"
# This thread's branch only: a copy made from a thread's own branch already holds that one.
pushed=$(g -C "$ORIGIN" for-each-ref --format='%(refname)' "refs/heads/workbench/$ID2")
check "nothing was pushed: the origin has no branch for this thread" "the origin has: $pushed" test -z "$pushed"
finish
