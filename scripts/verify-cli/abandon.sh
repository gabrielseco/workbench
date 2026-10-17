#!/bin/bash
# verify-cli scenario for `workbench abandon` (P12 task 1), with the real `claude`, on this repository.
#   bash scripts/verify-cli/abandon.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/abandon.sh   (the same, on a branch that contains origin/main)
# Runs one throwaway thread, commits scratch/verify-cli.txt on its branch, leaves its worktree dirty in five
# ways, abandons it and prints PASS or FAIL per step. Exit 0 only when every step passed, 1 when one failed,
# 2 when it refused to start (nothing changed). VERIFY_CLI_SABOTAGE=1 deletes abandon.patch before the
# assertions, to see a FAIL. The frame and the other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

GOAL_SRC="$SCRATCH/goal.md"
EXPECT="$SCRATCH/expect"
RESTORE="$SCRATCH/restore"
RESTORE_STAGED="$SCRATCH/restore-staged"
cat >"$GOAL_SRC" <<'EOF'
---
id: verify-cli-abandon
title: verify-cli abandon scenario
base: origin/main
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

Add the file `scratch/verify-cli.txt` holding the single line `verify-cli was here`, and commit it. This is a
throwaway thread that tests `workbench abandon`; its branch is deleted afterwards.

## Criteria

- [c1] `scratch/verify-cli.txt` holds the single line `verify-cli was here` and is committed on the branch.
  - proof: the diff shows that one new file and nothing else

## Out of scope

- Any other file.
EOF

start_thread verify-cli-abandon "$GOAL_SRC"
remove_on_pass branch "$BRANCH"
run_thread

# A committed change of the script's own, so the restore check applies the patch to a tip that is not the
# base, whatever the model did.
TIP=""
commit_scratch() {
    [ -f "$WT/scratch/verify-cli.txt" ] || { mkdir -p "$WT/scratch" && echo "verify-cli was here" >"$WT/scratch/verify-cli.txt"; }
    echo "committed by the verify-cli script" >>"$WT/scratch/verify-cli.txt"
    g -C "$WT" add scratch/verify-cli.txt \
        && g -C "$WT" -c user.name=verify-cli -c user.email=verify-cli@localhost commit -q --no-verify \
            -m "chore(scratch): verify-cli commit on the thread's branch" || return 1
    TIP=$(g rev-parse "$BRANCH")
    echo "    tip $TIP, base $BASE_SHA"
    [ -n "$TIP" ] && [ "$TIP" != "$BASE_SHA" ] && ! g diff --quiet "$BASE_SHA" "$TIP" -- scratch/verify-cli.txt
}

if [ -z "$WT" ] || [ ! -d "$WT" ]; then
    fail "worktree left by run" "no worktree at '${WT}'"
else
    check "scratch/verify-cli.txt committed: the branch tip differs from the base" "see above" commit_scratch

    # --- leave the worktree in a bad state ---------------------------------------------------------------
    mkdir -p "$EXPECT" "$WT/verify-cli"
    echo "modified by verify-cli" >>"$WT/README.md"
    printf 'staged version\n' >"$WT/verify-cli/staged-edited.txt"
    printf 'staged then deleted\n' >"$WT/verify-cli/staged-deleted.txt"
    g -C "$WT" add verify-cli/staged-edited.txt verify-cli/staged-deleted.txt
    printf 'working version\n' >"$WT/verify-cli/staged-edited.txt"
    rm "$WT/verify-cli/staged-deleted.txt"
    printf 'untracked\n' >"$WT/verify-cli/untracked.txt"
    { printf '\0\1\2\377'; head -c 4096 /dev/urandom; } >"$WT/verify-cli/blob.bin"
    cp "$WT/README.md" "$EXPECT/README.md"
    cp "$WT/verify-cli/staged-edited.txt" "$WT/verify-cli/untracked.txt" "$WT/verify-cli/blob.bin" "$EXPECT/"
    echo "    worktree left with: README.md modified; verify-cli/staged-edited.txt staged then edited;"
    echo "    verify-cli/staged-deleted.txt staged then deleted; verify-cli/untracked.txt; verify-cli/blob.bin (binary)"
    g -C "$WT" status --short | sed 's/^/    /'
fi

# --- abandon and assert -------------------------------------------------------------------------------

wb "$T_WB" abandon "$ID"
abandon_exit=$?
check "abandon exits 0 without --force" "exit $abandon_exit" test "$abandon_exit" = 0

if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: deleting $THREAD_DIR/abandon.patch"
    rm -f "$THREAD_DIR/abandon.patch"
fi

worktree_gone() {
    [ -n "$WT" ] && [ ! -e "$WT" ] || return 1
    local list
    list=$(g worktree list --porcelain) && ! grep -qxF "worktree $WT" <<<"$list"
}
check "worktree gone" "${WT:-?} is still there or registered" worktree_gone
check "branch $BRANCH kept" "no such branch" branch_exists "$BRANCH"
check "abandon.patch and abandon-staged.patch exist" "missing in $THREAD_DIR" \
    test -s "$THREAD_DIR/abandon.patch" -a -s "$THREAD_DIR/abandon-staged.patch"

saved=$(wb "$T_WB" log "$ID" --json | py "s=[e['data'] for e in lines if e['kind']=='abandon.saved']
print(json.dumps(s[-1]) if s else '')")
saved_ok() {
    [ -n "$saved" ] || { echo "    no abandon.saved event"; return 1; }
    echo "$saved" | THREAD_DIR="$THREAD_DIR" py "
import hashlib, os
missing=[k for k in ('path','bytes','sha256','tree','head') if not d.get(k)]
if missing: sys.exit('    abandon.saved has no ' + ', '.join(missing))
p=os.path.join(os.environ['THREAD_DIR'], d['path'])
print('    abandon.saved: %d bytes, sha256 %s, tree %s, head %s' % (d['bytes'], d['sha256'][:12], d['tree'][:12], d['head'][:12]))
if os.path.exists(p):
    b=open(p,'rb').read()
    if len(b)!=d['bytes'] or hashlib.sha256(b).hexdigest()!=d['sha256']: sys.exit('    size or sha256 differs from the file')
"
}
check "abandon.saved in workbench log with size, sha256, tree and head" "see above" saved_ok
HEAD_SAVED=$(echo "${saved:-null}" | py "print((d or {}).get('head',''))")

checkout_tip() {
    g worktree add --detach "$1" "$BRANCH" >/dev/null 2>&1 || { echo "    could not check out $BRANCH"; return 1; }
    remove_on_pass worktree "$1"
}
same() { cmp -s "$1" "$2" || { echo "    differs: $2"; return 1; }; }
restore_working() {
    [ -n "$TIP" ] && [ "$(g rev-parse "$BRANCH" 2>/dev/null)" = "$TIP" ] && [ "$TIP" = "$HEAD_SAVED" ] \
        || { echo "    branch tip is not the committed tip and the saved head"; return 1; }
    checkout_tip "$RESTORE" && g -C "$RESTORE" apply "$THREAD_DIR/abandon.patch" || return 1
    same "$EXPECT/README.md" "$RESTORE/README.md" && same "$EXPECT/staged-edited.txt" "$RESTORE/verify-cli/staged-edited.txt" \
        && same "$EXPECT/untracked.txt" "$RESTORE/verify-cli/untracked.txt" && same "$EXPECT/blob.bin" "$RESTORE/verify-cli/blob.bin"
}
restore_staged() {
    checkout_tip "$RESTORE_STAGED" && g -C "$RESTORE_STAGED" apply "$THREAD_DIR/abandon-staged.patch" || return 1
    [ "$(cat "$RESTORE_STAGED/verify-cli/staged-edited.txt" 2>/dev/null)" = "staged version" ] \
        && [ "$(cat "$RESTORE_STAGED/verify-cli/staged-deleted.txt" 2>/dev/null)" = "staged then deleted" ] \
        || { echo "    staged-only content not restored"; return 1; }
}
check "git apply abandon.patch on the committed tip of $BRANCH restores the modified, untracked and binary files" \
    "see above" restore_working
check "git apply abandon-staged.patch restores the staged-only content" "see above" restore_staged

left=$( [ -n "$WT" ] && pgrep -fl "$WT")
check "no process of the worktree left" "$left" test -z "$left"

finish
