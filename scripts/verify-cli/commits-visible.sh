#!/bin/bash
# verify-cli scenario for commits a run made being visible in accept, ship and review. On a clone of this repository
# whose origin is a bare copy in the temp folder, so nothing is pushed anywhere real, with a stand-in `gh` that only
# answers `auth status` (the pull request step then fails, after the push). No turn is run, so it costs nothing: the
# scenario makes each thread's worktree, its `worktree.created` record and its commits itself, as a run would.
#   bash scripts/verify-cli/commits-visible.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/commits-visible.sh   (the same, on a branch that contains origin/main)
# Thread A has two commits and nothing pending: `review` must list them under `Commits` between the criteria and the
# diff, oldest first, and `review --json` must have them as `commits`; `accept -m` must exit 0, print
# `-m ignored: the work was already committed (2 commit(s) on <branch>); nothing to commit` and leave the tip as it was;
# after a commit added by hand, `ship` must print `note: 1 commit(s) were added after accept: <sha>`, write one
# `branch.ahead` event with the accepted commit, the new head and that commit, push the head, and `workbench log` must
# show it. Thread B has no commits and pending work: no `Commits` heading, `accept -m` uses the message and says nothing
# about ignoring it, and its `ship` writes no `branch.ahead`. Exit 0 only when every step passed, 1 when one failed, 2
# when it refused to start (nothing changed). VERIFY_CLI_SABOTAGE=1 leaves a file uncommitted in thread A's worktree
# before `accept`, so accept commits it with the message and the steps "accept -m with nothing pending prints the
# ignored line" and "the branch tip is unchanged by accept" must FAIL. The frame is in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

ORIGIN="$SCRATCH/origin.git"
P="$SCRATCH/project"
g clone -q --bare "$ROOT" "$ORIGIN" || die "git clone --bare failed"
g -C "$ORIGIN" update-ref refs/heads/main "$BASE_SHA" || die "could not set main in the bare copy"
g -C "$ORIGIN" symbolic-ref HEAD refs/heads/main || die "could not point the bare copy's HEAD at main"
g clone -q "$ORIGIN" "$P" || die "git clone failed"
g -C "$P" checkout -q -B main origin/main || die "could not check out main in the clone"
# A `gh` that is logged in and can do nothing else: ship pushes, then fails to open the pull request.
mkdir -p "$SCRATCH/bin"
printf '#!/bin/sh\n[ "$1 $2" = "auth status" ] && exit 0\necho "verify-cli stand-in gh: $*" >&2\nexit 1\n' >"$SCRATCH/bin/gh"
chmod +x "$SCRATCH/bin/gh"
echo "==> clone at $P, origin $ORIGIN"

RC=0
wbp() { # <out> args...: a workbench command in the clone with the stand-in gh, stdout and stderr together; sets RC
    local o=$1; shift
    echo "workbench $*   (in the clone)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    ( cd "$P" && PATH="$SCRATCH/bin:$PATH" with_timeout "$T_WB" "$WB" "$@" >"$o" 2>&1 )
    RC=$?
}
shown() { sed 's/^/    /' "$1" | head -${2:-8}; }
created() { sed -n 's/^created //p' "$1"; }
gc() { g -C "$1" -c user.name=verify-cli -c user.email=verify-cli@example.com commit -q -m "$2"; }

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0

new_thread() { # <name>: an approved thread on main with its worktree and worktree.created record; sets TID, WTP
    cat >"$SCRATCH/$1.md" <<'GOAL'
---
title: Commits visible
budget_usd: 1
turn_timeout_min: 30
---

## Request

Nothing runs: this thread only checks what accept, ship and review say about commits.

## Criteria

- [c1] The commits are shown.
  - proof: the scenario reads the output

## Out of scope

- Any change to the code.
GOAL
    wbp "$SCRATCH/new-$1.out" goal new "$1" --from "$SCRATCH/$1.md" --base main
    TID=$(created "$SCRATCH/new-$1.out")
    [ -n "$TID" ] || die "goal new $1 made no thread: $(cat "$SCRATCH/new-$1.out")"
    wbp "$SCRATCH/approve-$1.out" goal approve "$TID"
    [ "$RC" = 0 ] || die "goal approve $TID failed: $(cat "$SCRATCH/approve-$1.out")"
    WTP="$P/.workbench/worktrees/$TID"
    g -C "$P" worktree add -q -b "workbench/$TID" "$WTP" main || die "could not add the worktree of $TID"
    # What a run records when it makes the worktree; review and accept read the base commit from it.
    python3 -I - "$P/.workbench/threads/$TID/events.jsonl" "$WTP" "workbench/$TID" "$BASE_SHA" <<'PY' \
        || die "could not record worktree.created for $TID"
import json, sys
path, wt, branch, base = sys.argv[1:5]
last = json.loads(open(path).read().splitlines()[-1])
event = {"v": 1, "seq": last["seq"] + 1, "ts": last["ts"], "turn": 0, "kind": "worktree.created",
         "data": {"path": wt, "branch": branch, "base_commit": base}}
open(path, "a").write(json.dumps(event, separators=(",", ":")) + "\n")
PY
}
tip() { g -C "$P" rev-parse "refs/heads/workbench/$1"; }

# --- thread A: commits, nothing pending ---------------------------------------------------------------------

new_thread commits-a
A=$TID
WTA=$WTP
echo one >"$WTA/one.txt"; g -C "$WTA" add one.txt; gc "$WTA" "verify-cli: first commit"
echo two >"$WTA/two.txt"; g -C "$WTA" add two.txt; gc "$WTA" "verify-cli: second commit"
SHA1=$(g -C "$WTA" rev-parse HEAD~1)
SHA2=$(g -C "$WTA" rev-parse HEAD)

wbp "$SCRATCH/review-a.out" review "$A"
sed -n '/^Commits$/,/^$/p' "$SCRATCH/review-a.out" | sed 's/^/    /'
check "review lists the commits under Commits, oldest first" "no Commits block with both commits in order" \
    bash -c 'sed -n "/^Commits$/,/^$/p" "$1" | grep -v "^Commits$" | grep -v "^$" | tr "\n" "|" \
        | grep -qx "  ${2:0:12} verify-cli: first commit|  ${3:0:12} verify-cli: second commit|"' \
    _ "$SCRATCH/review-a.out" "$SHA1" "$SHA2"
check "Commits sits between the criteria and the diff" "the order of the headings is wrong" \
    bash -c 'grep -n -e "^Criteria$" -e "^Commits$" -e "^Diff against" "$1" | cut -d: -f2 | cut -c1-6 | tr "\n" " " \
        | grep -qx "Criteria Commits Diff a "' _ "$SCRATCH/review-a.out"
wbp "$SCRATCH/review-a.json" review "$A" --json
subjects=$(py "print('|'.join(c['subject'] + '@' + c['sha'] for c in d['commits']))" <"$SCRATCH/review-a.json" 2>/dev/null)
check "review --json has commits with sha and subject" "commits is '$subjects'" \
    test "$subjects" = "verify-cli: first commit@$SHA1|verify-cli: second commit@$SHA2"

if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: a file is left uncommitted in $A's worktree before accept"
    echo pending >"$WTA/pending.txt"
fi
BEFORE=$(tip "$A")
wbp "$SCRATCH/accept-a.out" accept "$A" -m "chore: my message" --yes
shown "$SCRATCH/accept-a.out" 12
check "accept -m with nothing pending: exit 0" "workbench accept exited $RC" test "$RC" = 0
check "accept -m with nothing pending prints the ignored line" "no '-m ignored' line after the result" \
    grep -qx -- "-m ignored: the work was already committed (2 commit(s) on workbench/$A); nothing to commit" \
    "$SCRATCH/accept-a.out"
check "the branch tip is unchanged by accept" "workbench/$A moved from $BEFORE to $(tip "$A")" test "$(tip "$A")" = "$BEFORE"

echo fix >"$WTA/fix.txt"; g -C "$WTA" add fix.txt; gc "$WTA" "verify-cli: fix after accept"
SHA3=$(g -C "$WTA" rev-parse HEAD)
wbp "$SCRATCH/ship-a.out" ship "$A" --yes --no-describe
shown "$SCRATCH/ship-a.out" 30
echo "    (ship exited $RC: the stand-in gh cannot open a pull request, so a failure after the push is expected)"
check "ship prints the note about the commit added after accept" "no note line" \
    grep -qx "note: 1 commit(s) were added after accept: ${SHA3:0:12}" "$SCRATCH/ship-a.out"
check "ship still pushed the head" "origin has '$(g -C "$ORIGIN" rev-parse -q --verify "refs/heads/workbench/$A")'" \
    test "$(g -C "$ORIGIN" rev-parse -q --verify "refs/heads/workbench/$A")" = "$SHA3"
wbp "$SCRATCH/log-a.json" log "$A" --json
ahead=$(py "e=[x['data'] for x in lines if x['kind']=='branch.ahead']
print(len(e), e[0]['accepted'] if e else '', e[0]['head'] if e else '', [c['sha'] for c in e[0]['commits']] if e else '')" \
    <"$SCRATCH/log-a.json" 2>/dev/null)
check "one branch.ahead event with the accepted commit, the head and the added commit" "the log has: $ahead" \
    test "$ahead" = "1 ${SHA2:0:12} $SHA3 ['$SHA3']"
wbp "$SCRATCH/log-a.out" log "$A"
grep "branch ahead" "$SCRATCH/log-a.out" | sed 's/^/    /'
check "workbench log shows branch.ahead in one line" "no 'branch ahead of accept' line" \
    test "$(grep -c "branch ahead of accept: 1 commit(s) after ${SHA2:0:12}" "$SCRATCH/log-a.out")" = 1

# --- thread B: no commits, pending work ---------------------------------------------------------------------

new_thread commits-b
B=$TID
echo pending >"$WTP/pending.txt"
wbp "$SCRATCH/review-b.out" review "$B"
check "review of a thread without commits has no Commits heading" "a Commits heading is shown" \
    bash -c '! grep -qx "Commits" "$1"' _ "$SCRATCH/review-b.out"
wbp "$SCRATCH/accept-b.out" accept "$B" -m "chore: pending work" --yes
check "accept -m with pending work: exit 0" "workbench accept exited $RC" test "$RC" = 0
check "accept -m with pending work says nothing about ignoring it" "an '-m ignored' line" \
    bash -c '! grep -q -- "-m ignored" "$1"' _ "$SCRATCH/accept-b.out"
check "the message is the commit on the branch" "the tip says '$(g -C "$P" log -1 --format=%s "workbench/$B")'" \
    test "$(g -C "$P" log -1 --format=%s "workbench/$B")" = "chore: pending work"
wbp "$SCRATCH/ship-b.out" ship "$B" --yes --no-describe
wbp "$SCRATCH/log-b.json" log "$B" --json
nahead=$(py "print(len([x for x in lines if x['kind']=='branch.ahead']))" <"$SCRATCH/log-b.json" 2>/dev/null)
check "ship at the accepted commit writes no branch.ahead and no note" "branch.ahead x$nahead or a note line" \
    bash -c '[ "$2" = 0 ] && ! grep -q "^note: " "$1"' _ "$SCRATCH/ship-b.out" "$nahead"
finish
