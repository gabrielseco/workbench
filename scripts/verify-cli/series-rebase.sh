#!/bin/bash
# verify-cli scenario for `series rebase` (P27 task 5), on a clone of this repository whose origin is a local bare repository, with a
# stand-in `gh` that answers from files. Nothing reaches GitHub and it costs nothing.
#   bash scripts/verify-cli/series-rebase.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/series-rebase.sh   (the same, on a branch that contains origin/main)
# Step 2 of a two-step series was cut from step 1's branch; step 1 is then squash-merged into the base (a new commit). `series
# rebase` must replay step 2's own commit onto the base, push it with a lease, and retarget its pull request: afterwards the branch
# holds exactly one commit over the base and the stand-in gh was told `pr edit 2 --base <base>`; a second run changes nothing. The
# threads are hand-written logs (no run, no cost). Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start.
# VERIFY_CLI_SABOTAGE=1 leaves step 1 unmerged (the stand-in says OPEN), so the rebase waits and the steps that expect it done must
# FAIL. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

P="$SCRATCH/project"
BARE="$SCRATCH/origin.git"
GHD="$SCRATCH/gh"
g clone -q "$ROOT" "$P" || die "git clone failed"
git init -q --bare "$BARE" || die "git init failed"
git -C "$P" remote set-url origin "$BARE"
BASE=$(git -C "$P" symbolic-ref --short HEAD)
git -C "$P" push -q origin "$BASE" || die "push to the local origin failed"
echo "==> clone at $P, base $BASE"

gitp() { git -C "$P" -c user.name=verify -c user.email=verify@example.test "$@"; }
PARENT=g-2026-01-01-r-1
CHILD=g-2026-01-01-r-2
gitp checkout -q -b "workbench/$PARENT"
echo "from step one" >"$P/rebase-a.txt"; gitp add rebase-a.txt; gitp commit -q -m "step one"
gitp push -q origin "workbench/$PARENT"
TIPA=$(gitp rev-parse HEAD)
gitp checkout -q -b "workbench/$CHILD"
echo "from step two" >"$P/rebase-b.txt"; gitp add rebase-b.txt; gitp commit -q -m "step two"
gitp push -q origin "workbench/$CHILD"
TIPB=$(gitp rev-parse HEAD)
gitp checkout -q "$BASE"
if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: step 1 is not merged"
else
    echo "from step one" >"$P/rebase-a.txt"; gitp add rebase-a.txt; gitp commit -q -m "squash of step one"
    gitp push -q origin "$BASE"
fi
gitp fetch -q origin

# A stand-in gh: `pr view N` prints $GHD/view_N, `pr edit N --base B` writes B to $GHD/edit_N.
mkdir -p "$GHD"
cat >"$GHD/gh" <<'SH'
#!/bin/sh
d="$GH_FAKE_DIR"
echo "$@" >> "$d/calls"
case "$1 $2" in
"pr view") cat "$d/view_$3"; exit 0 ;;
"pr edit") echo "$5" > "$d/edit_$3"; exit 0 ;;
esac
exit 2
SH
chmod +x "$GHD/gh"
PARENT_STATE=MERGED; [ "$SABOTAGE" = 1 ] && PARENT_STATE=OPEN
printf '{"state":"%s","baseRefName":"%s","headRefOid":"%s"}' "$PARENT_STATE" "$BASE" "$TIPA" >"$GHD/view_1"
printf '{"state":"OPEN","baseRefName":"workbench/%s","headRefOid":"%s"}' "$PARENT" "$TIPB" >"$GHD/view_2"

# The threads' logs: step 1 opened PR 1; step 2 was cut from step 1's tip and opened PR 2.
for t in $PARENT $CHILD; do mkdir -p "$P/.workbench/threads/$t"; done
printf '{"v":1,"seq":1,"ts":"2026-01-01T00:00:00.000Z","turn":0,"kind":"pr.opened","data":{"number":1,"url":"https://example.test/pull/1"}}\n' \
    >"$P/.workbench/threads/$PARENT/events.jsonl"
printf '{"v":1,"seq":1,"ts":"2026-01-01T00:00:00.000Z","turn":0,"kind":"worktree.created","data":{"base_commit":"%s"}}\n' "$TIPA" \
    >"$P/.workbench/threads/$CHILD/events.jsonl"
printf '{"v":1,"seq":2,"ts":"2026-01-01T00:00:01.000Z","turn":0,"kind":"pr.opened","data":{"number":2,"url":"https://example.test/pull/2"}}\n' \
    >>"$P/.workbench/threads/$CHILD/events.jsonl"

wbp() { # <out> args...: a workbench command in the clone with the stand-in gh first on PATH; sets RC
    local o=$1; shift
    echo "workbench $*   (in the clone)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    ( cd "$P" && PATH="$GHD:$PATH" GH_FAKE_DIR="$GHD" with_timeout "$T_WB" "$WB" "$@" >"$o" 2>&1 )
    RC=$?
}
RC=0
wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "exit $RC" test "$RC" = 0
SD="$P/.workbench/series/r"
mkdir -p "$SD"
cat >"$SD/g.md" <<'GOAL'
---
title: Series rebase scenario goal
budget_usd: 0.50
turn_timeout_min: 5
---

## Request

A throwaway goal file; no thread is made from it.

## Criteria

- [c1] Nothing changes.
  - proof: no run

## Out of scope

- Everything.
GOAL
printf '## 1\nproject: %s\ngoal: g.md\n\n## 2\nproject: %s\ngoal: g.md\nbase: after 1\n' "$P" "$P" >"$SD/series.md"
printf '{"at":"t","step":1,"thread":"%s"}\n{"at":"t","step":2,"thread":"%s"}\n' "$PARENT" "$CHILD" >"$SD/steps.jsonl"

before=$(git -C "$BARE" rev-parse "refs/heads/workbench/$CHILD")
wbp "$SCRATCH/rebase1.out" series rebase r
sed 's/^/    /' "$SCRATCH/rebase1.out" | head -6
check "rebase: step 2 rebased onto the base and its pull request retargeted" "exit $RC: $(head -c 300 "$SCRATCH/rebase1.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "^step 2: rebased onto '"$BASE"'; pull request #2 now targets it" "$2"' _ "$RC" "$SCRATCH/rebase1.out"
check "the branch holds exactly its own commit over the base" "log: $(git -C "$BARE" log --format=%s "$BASE..workbench/$CHILD" | tr '\n' '|')" \
    test "$(git -C "$BARE" log --format=%s "$BASE..refs/heads/workbench/$CHILD")" = "step two"
check "the stand-in gh was told to retarget pull request 2" "edit_2: $(cat "$GHD/edit_2" 2>/dev/null)" \
    test "$(cat "$GHD/edit_2" 2>/dev/null)" = "$BASE"

after=$(git -C "$BARE" rev-parse "refs/heads/workbench/$CHILD")
printf '{"state":"OPEN","baseRefName":"%s","headRefOid":"%s"}' "$BASE" "$after" >"$GHD/view_2"
wbp "$SCRATCH/rebase2.out" series rebase r
check "a second run changes nothing" "exit $RC: $(head -c 300 "$SCRATCH/rebase2.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "already on its base" "$2" && [ "$(git -C "$3" rev-parse refs/heads/workbench/'"$CHILD"')" = "$4" ]' _ "$RC" "$SCRATCH/rebase2.out" "$BARE" "$after"
check "no worktree was left behind" "$(git -C "$P" worktree list | grep -c series-rebase) left" \
    bash -c '! git -C "$1" worktree list | grep -q series-rebase' _ "$P"
finish
