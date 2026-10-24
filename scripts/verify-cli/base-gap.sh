#!/bin/bash
# verify-cli scenario for `status` and `review` not asking origin by default. On a clone of this repository whose origin
# is a bare copy in the temp folder, so nothing real is contacted. No turn is run, so it costs nothing.
#   bash scripts/verify-cli/base-gap.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/base-gap.sh   (the same, on a branch that contains origin/main)
# Someone else pushes a commit to origin/main. Plain `status` and `review` must not fetch: they say nothing about the
# gap (the clone has not been told) and `status --json` has `base_gap.fetched` false. `status --fetch` must say "main is 1
# commit behind origin/main" with no age and `--json --fetch` must have `fetched` true. After that fetch, plain `review`
# must still say it, with "(as of the last fetch, ..." and `status --json` must carry `as_of`. With the origin taken
# away, plain `status` must still exit 0 and print the same line and no "could not fetch" note, while `status --fetch`
# must print "could not fetch origin". `status --all --fetch` must exit 2. Exit 0 only when every step passed, 1 when one
# failed, 2 when it refused to start (nothing changed). VERIFY_CLI_SABOTAGE=1 adds `--fetch` to every plain command, as
# the old behaviour did, so "plain status does not fetch", "plain status --json says fetched false", "plain review keeps
# the age", "plain status --json carries as_of" and "with the origin gone plain status prints no fetch note" must FAIL. The frame is in lib.sh. Run by hand,
# not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

ORIGIN="$SCRATCH/origin.git"
P="$SCRATCH/project"
OTHER="$SCRATCH/other"
g clone -q --bare "$ROOT" "$ORIGIN" || die "git clone --bare failed"
g -C "$ORIGIN" update-ref refs/heads/main "$BASE_SHA" || die "could not set main in the bare copy"
g -C "$ORIGIN" symbolic-ref HEAD refs/heads/main || die "could not point the bare copy's HEAD at main"
g clone -q "$ORIGIN" "$P" || die "git clone failed"
g -C "$P" checkout -q -B main origin/main || die "could not check out main in the clone"
g clone -q "$ORIGIN" "$OTHER" || die "git clone (the other person) failed"
echo "==> clone at $P, origin $ORIGIN"

PLAIN=()
if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: every plain status and review gets --fetch, as the old behaviour had"
    PLAIN=(--fetch)
fi

RC=0
wbp() { # <out> args...: a workbench command in the clone, stdout and stderr together; sets RC
    local o=$1; shift
    echo "workbench $*   (in the clone)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    ( cd "$P" && with_timeout "$T_WB" "$WB" "$@" >"$o" 2>&1 )
    RC=$?
}
shown() { sed 's/^/    /' "$1" | head -${2:-8}; }
behind() { grep -q "main is 1 commit behind origin/main" "$1"; }

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
cat >"$SCRATCH/goal.md" <<'GOAL'
---
title: Base gap
budget_usd: 1
turn_timeout_min: 30
---

## Request

Nothing runs: this thread only checks what status and review say about the base.

## Criteria

- [c1] The base gap is said only when asked or known.
  - proof: the scenario reads the output

## Out of scope

- Any change to the code.
GOAL
wbp "$SCRATCH/new.out" goal new base-gap --from "$SCRATCH/goal.md" --base main
TID=$(sed -n 's/^created //p' "$SCRATCH/new.out")
[ -n "$TID" ] || die "goal new made no thread: $(cat "$SCRATCH/new.out")"
wbp "$SCRATCH/approve.out" goal approve "$TID"
[ "$RC" = 0 ] || die "goal approve $TID failed: $(cat "$SCRATCH/approve.out")"

# Someone else moves origin/main one commit ahead; this clone has not been told.
echo x >"$OTHER/x.txt"
g -C "$OTHER" add x.txt
g -C "$OTHER" -c user.name=verify-cli -c user.email=verify-cli@example.com commit -q -m "verify-cli: someone else"
g -C "$OTHER" push -q origin HEAD:main || die "the other person could not push"

wbp "$SCRATCH/status-plain.out" status "$TID" ${PLAIN[@]+"${PLAIN[@]}"}
shown "$SCRATCH/status-plain.out" 14
check "plain status exits 0" "workbench status exited $RC" test "$RC" = 0
check "plain status does not fetch: the gap is not said" "it says the base is behind, so origin was asked" \
    bash -c '! grep -q "commit.* behind origin" "$1"' _ "$SCRATCH/status-plain.out"
wbp "$SCRATCH/status-plain.json" status "$TID" --json ${PLAIN[@]+"${PLAIN[@]}"}
fetched=$(py "print(d['base_gap']['fetched'] if d['base_gap'] else 'null')" <"$SCRATCH/status-plain.json" 2>/dev/null)
check "plain status --json says fetched false" "base_gap.fetched is '$fetched'" test "$fetched" = False

wbp "$SCRATCH/status-fetch.out" status "$TID" --fetch
shown "$SCRATCH/status-fetch.out" 14
check "status --fetch says the base is 1 commit behind" "no 'main is 1 commit behind origin/main' line" \
    behind "$SCRATCH/status-fetch.out"
check "status --fetch gives no age: it just asked" "the line has an age" \
    bash -c '! grep -q "as of the last fetch" "$1"' _ "$SCRATCH/status-fetch.out"
wbp "$SCRATCH/status-fetch.json" status "$TID" --json --fetch
fetched=$(py "print(d['base_gap']['fetched'], d['base_gap']['behind'], d['base_gap']['as_of'])" \
    <"$SCRATCH/status-fetch.json" 2>/dev/null)
check "status --json --fetch says fetched true, behind 1, no as_of" "base_gap is '$fetched'" \
    test "$fetched" = "True 1 None"

# The clone now knows, so plain commands say it, with how old that is.
wbp "$SCRATCH/review-plain.out" review "$TID" ${PLAIN[@]+"${PLAIN[@]}"}
grep "behind" "$SCRATCH/review-plain.out" | sed 's/^/    /'
check "plain review keeps the age of what it knows" "no '(as of the last fetch, ' after the gap" \
    grep -q "main is 1 commit behind origin/main (as of the last fetch, " "$SCRATCH/review-plain.out"
wbp "$SCRATCH/status-known.json" status "$TID" --json ${PLAIN[@]+"${PLAIN[@]}"}
known=$(py "print(d['base_gap']['fetched'], d['base_gap']['behind'], d['base_gap']['as_of'] is not None)" \
    <"$SCRATCH/status-known.json" 2>/dev/null)
check "plain status --json carries as_of" "base_gap is '$known'" test "$known" = "False 1 True"

# The origin goes away: a plain command does not need it, a requested fetch says it could not.
mv "$ORIGIN" "$SCRATCH/origin-gone.git" || die "could not take the origin away"
wbp "$SCRATCH/status-gone.out" status "$TID" ${PLAIN[@]+"${PLAIN[@]}"}
shown "$SCRATCH/status-gone.out" 14
check "with the origin gone plain status exits 0 and still says the gap" "exit $RC or no gap line" \
    bash -c '[ "$2" = 0 ] && grep -q "main is 1 commit behind origin/main" "$1"' _ "$SCRATCH/status-gone.out" "$RC"
check "with the origin gone plain status prints no fetch note" "a 'could not fetch' note" \
    bash -c '! grep -q "could not fetch" "$1"' _ "$SCRATCH/status-gone.out"
wbp "$SCRATCH/status-gone-fetch.out" status "$TID" --fetch
check "with the origin gone status --fetch says it could not fetch" "no 'could not fetch origin' note" \
    grep -q "could not fetch origin" "$SCRATCH/status-gone-fetch.out"
mv "$SCRATCH/origin-gone.git" "$ORIGIN"

wbp "$SCRATCH/all-fetch.out" status --all --fetch
check "status --all --fetch exits 2" "workbench status --all --fetch exited $RC" test "$RC" = 2
finish
