#!/bin/bash
# verify-cli scenario for `workbench prune`, built from this repository. No turn is run and GitHub is not asked, so it costs
# nothing.
#   bash scripts/verify-cli/prune.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/prune.sh   (the same, on a branch that contains origin/main)
# The binary is built here, but every prune runs on a throwaway repository in the scratch folder, never on this one (its
# worktrees are someone's work). `gh` is a stand-in script first on PATH that answers `gh pr list --head <branch>` from files.
# The throwaway repository has worktrees that are: merged into main, squash-merged (a merged pull request, not an ancestor),
# detached on main, dirty, locked, with an open pull request, with no pull request, with a closed one; an unregistered directory
# under .workbench/worktrees/ and one a thread names. Steps: the dry run lists each with its verdict and changes nothing; --yes
# removes the three removable ones and their branches and keeps the rest; --yes --unregistered removes the unregistered
# directory but not the thread's; --yes --closed removes the closed one; a failing `gh` keeps a worktree that needs it and exits 1
# while one decided by git is still removed. Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start.
# VERIFY_CLI_SABOTAGE=1 has the stand-in say the squash-merged branch's pull request is open, so the "squash-merged is removable"
# and "--yes removes" steps must FAIL. Everything is in the scratch folder, removed on a pass. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

FX="$SCRATCH/repo"
WT="$SCRATCH/wt"
GH="$SCRATCH/gh-bin"
mkdir -p "$FX" "$WT" "$GH/answers"
# Physical paths, as git prints them (a temporary folder can sit behind a link, /var -> /private/var on macOS).
FX=$(cd "$FX" && pwd -P) WT=$(cd "$WT" && pwd -P)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=verify GIT_AUTHOR_EMAIL=verify@example.invalid GIT_COMMITTER_NAME=verify GIT_COMMITTER_EMAIL=verify@example.invalid

cat >"$GH/gh" <<SCRIPT
#!/bin/sh
echo "\$*" >>"$GH/calls"
[ -f "$GH/fail" ] && { echo "HTTP 502" >&2; exit 1; }
f="$GH/answers/\$(echo "\$4" | tr / _).json"
if [ -f "\$f" ]; then cat "\$f"; else echo '[]'; fi
SCRIPT
chmod +x "$GH/gh"
answer() { printf '[{"number":%s,"state":"%s","headRefOid":"%s"}]' "$3" "$2" "$4" >"$GH/answers/$(echo "$1" | tr / _).json"; }

fx() { with_timeout "$T_GIT" git -C "$FX" "$@"; }
# A worktree in $WT/<name> on a new branch (none: detached) from main, with <commits> commits; prints its tip.
add_wt() {
    local name=$1 branch=$2 commits=$3 i
    if [ "$branch" = none ]; then fx worktree add -q --detach "$WT/$name" main; else fx worktree add -q -b "$branch" "$WT/$name" main; fi
    for ((i = 0; i < commits; i++)); do
        echo "$name $i" >"$WT/$name/$name-$i.txt"
        git -C "$WT/$name" add -A && git -C "$WT/$name" commit -q -m "$name $i"
    done
    git -C "$WT/$name" rev-parse HEAD
}
# `workbench prune` in the throwaway repository with the stand-in `gh`; output in $SCRATCH/<out>, sets RC.
RC=0
prune() {
    local o=$1; shift
    echo "workbench prune $*   (in the throwaway repository)" >>"$SCRATCH/commands"
    ( cd "$FX" && PATH="$GH:$PATH" with_timeout "$T_WB" "$WB" prune "$@" >"$SCRATCH/$o" 2>&1 )
    RC=$?
    sed 's/^/    /' "$SCRATCH/$o"
}
line() { grep -F "$2" "$SCRATCH/$1" | grep -q "^$3"; }
state() { { fx worktree list --porcelain; fx for-each-ref --format='%(refname) %(objectname)' refs/heads; ls "$FX/.workbench/worktrees"; } 2>&1; }
has_branch() { fx rev-parse -q --verify "refs/heads/$1" >/dev/null; }

# --- the throwaway repository -------------------------------------------------------------------------------------------

fx init -q -b main
echo one >"$FX/a.txt"
fx add a.txt && fx commit -q -m init
mkdir -p "$FX/.workbench/worktrees/leftover" "$FX/.workbench/worktrees/t-named" "$FX/.workbench/threads/t-named"
echo ".workbench/" >>"$FX/.git/info/exclude"
add_wt merged feat/merged 1 >/dev/null
fx merge -q --ff-only feat/merged
SQUASH=$(add_wt squash feat/squash 2)
if [ "$SABOTAGE" = 1 ]; then answer feat/squash OPEN 3 "$SQUASH"; else answer feat/squash MERGED 3 "$SQUASH"; fi
add_wt detached none 0 >/dev/null
add_wt dirty feat/dirty 0 >/dev/null
echo x >"$WT/dirty/new.txt"
add_wt locked feat/locked 0 >/dev/null
fx worktree lock "$WT/locked"
answer feat/open OPEN 4 "$(add_wt open feat/open 1)"
add_wt nopr feat/nopr 1 >/dev/null
answer feat/closed CLOSED 5 "$(add_wt closed feat/closed 1)"

# --- 1. the dry run -----------------------------------------------------------------------------------------------------

BEFORE=$(state)
prune dry.out
check "dry run exits 0" "exit $RC" test "$RC" -eq 0
check "dry run changes nothing" "the worktrees, branches or directories changed" test "$(state)" = "$BEFORE"
check "merged into main is removable" "no 'removable' line for it" line dry.out "$WT/merged (feat/merged)" removable
check "squash-merged is removable" "no 'removable' line for it" line dry.out "$WT/squash (feat/squash)" removable
check "detached on main is removable" "no 'removable' line for it" line dry.out "$WT/detached (detached)" removable
check "dirty is kept" "no kept line with the reason" line dry.out "(feat/dirty): uncommitted changes" kept
check "locked is kept" "no kept line with the reason" line dry.out "(feat/locked): locked" kept
check "open PR is kept" "no kept line with the reason" line dry.out "(feat/open): pull request #4 is open" kept
check "no PR is kept" "no kept line with the reason" line dry.out "(feat/nopr): no pull request" kept
check "closed PR is kept without --closed" "no kept line naming --closed" line dry.out "#5 was closed without merging; --closed" kept
check "the primary checkout is kept" "no kept line for it" line dry.out "(main): the primary checkout" kept
check "unregistered directory is listed" "no line for it" line dry.out "leftover: unregistered; --unregistered" kept
check "ancestor needs no GitHub" "gh was asked about feat/merged" bash -c "! grep -q feat/merged '$GH/calls'"

# --- 2. --yes ------------------------------------------------------------------------------------------------------------

prune yes.out --yes
check "--yes exits 0" "exit $RC" test "$RC" -eq 0
check "--yes removes the removable worktrees" "one is still there" \
    bash -c "[ ! -e '$WT/merged' ] && [ ! -e '$WT/squash' ] && [ ! -e '$WT/detached' ]"
check "--yes removes their branches" "a branch is still there" bash -c "! git -C '$FX' rev-parse -q --verify refs/heads/feat/merged \
    && ! git -C '$FX' rev-parse -q --verify refs/heads/feat/squash"
check "--yes keeps the rest" "a kept worktree is gone" bash -c \
    "[ -d '$WT/dirty' ] && [ -d '$WT/locked' ] && [ -d '$WT/open' ] && [ -d '$WT/nopr' ] && [ -d '$WT/closed' ]"
check "--yes keeps their branches and main" "a kept branch is gone" bash -c "for b in feat/dirty feat/locked feat/open feat/nopr \
    feat/closed main; do git -C '$FX' rev-parse -q --verify refs/heads/\$b >/dev/null || exit 1; done"
check "--yes alone leaves the unregistered directory" "it is gone" test -d "$FX/.workbench/worktrees/leftover"

# --- 3. --unregistered, --closed -----------------------------------------------------------------------------------------

prune unreg.out --yes --unregistered
check "--unregistered removes the leftover directory" "exit $RC, or it is still there" \
    bash -c "[ $RC -eq 0 ] && [ ! -e '$FX/.workbench/worktrees/leftover' ]"
check "a directory a thread names stays" "it is gone" test -d "$FX/.workbench/worktrees/t-named"
prune closed.out --yes --closed
check "--closed removes the closed PR's worktree and branch" "exit $RC, or it is still there" \
    bash -c "[ $RC -eq 0 ] && [ ! -e '$WT/closed' ] && ! git -C '$FX' rev-parse -q --verify refs/heads/feat/closed"

# --- 4. GitHub cannot be asked --------------------------------------------------------------------------------------------

add_wt merged2 feat/merged2 0 >/dev/null
add_wt pending feat/pending 1 >/dev/null
touch "$GH/fail"
prune fail.out --yes
check "a failing gh exits 1" "exit $RC" test "$RC" -eq 1
check "the worktree that needed GitHub is kept and says so" "no such line, or it is gone" \
    bash -c "grep -F '(feat/pending): GitHub could not be asked' '$SCRATCH/fail.out' | grep -q ^kept && [ -d '$WT/pending' ]"
check "the one git decides is still removed" "it is still there" test ! -e "$WT/merged2"

finish
