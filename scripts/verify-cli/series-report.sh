#!/bin/bash
# verify-cli scenario for `series report` (P27 task 7), on a clone of this repository. No turn is run and nothing reaches GitHub (a
# stand-in `gh` that always fails is first on PATH), so it costs nothing.
#   bash scripts/verify-cli/series-report.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/series-report.sh   (the same, on a branch that contains origin/main)
# A one-step series whose thread (hand-written log) has a turn, a check, a judge reading, a pull request, a review round that said
# FIX with two findings, a follow-up thread that answered it, a clean second round, and a thread made by hand on the same branch.
# `series report` must print and write report.md with: the summary table with the rounds `FIX → CLEAN`, the findings' severities and
# titles, the follow-up that answered round 1 with what it said, the work done by hand, the judge's reading with the turn it is of,
# and a total that counts every thread. Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start.
# VERIFY_CLI_SABOTAGE=1 leaves the follow-up thread out, so "answered by" and the cost steps must FAIL. Run by
# hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

P="$SCRATCH/project"
g clone -q "$ROOT" "$P" || die "git clone failed"
GHD="$SCRATCH/gh"
mkdir -p "$GHD"
printf '#!/bin/sh\nexit 1\n' >"$GHD/gh"
chmod +x "$GHD/gh"

RC=0
wbp() { # <out> args...: a workbench command in the clone with the failing gh first on PATH; sets RC
    local o=$1; shift
    echo "workbench $*   (in the clone)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    ( cd "$P" && PATH="$GHD:$PATH" with_timeout "$T_WB" "$WB" "$@" >"$o" 2>"$o.err" )
    RC=$?
}
wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "exit $RC" test "$RC" = 0

goal() { # <id> <title> [push_to]
    local base=main push=""
    [ -n "${3:-}" ] && { base="origin/$3"; push=$'\npush_to: '"$3"; }
    printf -- '---\nid: %s\ntitle: %s\nstatus: draft\nbase: %s%s\nbudget_usd: 1.00\nturn_timeout_min: 10\n---\n\n## Request\n\nDo it.\n\n## Criteria\n\n- [c1] It works.\n  - proof: a test\n- [c2] It is tested.\n  - proof: a test\n\n## Out of scope\n\n- Nothing.\n' "$1" "$2" "$base" "$push"
}
ev() { # <seq> <turn> <kind> <data-json>
    printf '{"v":1,"seq":%s,"ts":"2026-01-01T00:00:%02d.000Z","turn":%s,"kind":"%s","data":%s}\n' "$1" "$1" "$2" "$3" "${4:-\{\}}"
}
ROOT_T=g-2026-01-01-rp-1
FOLLOW=g-2026-01-01-rp-1-review-1
HAND=g-2026-01-01-rp-rework
T="$P/.workbench/threads"
mkdir -p "$T/$ROOT_T/pr-review"
goal "$ROOT_T" "Report scenario goal" >"$T/$ROOT_T/goal.md"
{
    ev 1 0 thread.created
    ev 2 1 turn.started
    ev 3 1 turn.ended '{"result":"succeeded","cost_usd":1.0,"summary":"Built the thing."}'
    ev 4 1 check.ran '{"result":"passed"}'
    ev 5 1 judge.ran '{"ok":true,"criteria":[{"id":"c1","met":true,"evidence":[]},{"id":"c2","met":false,"evidence":[]}],"concerns":["It may be slow."],"cost_usd":0.1}'
    ev 6 0 pr.opened '{"number":7,"url":"https://example.test/pull/7","head_sha":"abc"}'
    ev 7 0 pr_review.started '{"round":1,"pr":7}'
    ev 8 0 pr_review.finished '{"round":1,"pr":7,"ok":true,"verdict":"fix","findings_path":"pr-review/round-1.findings.md"}'
} >"$T/$ROOT_T/events.jsonl"
printf -- '- **[P1] A real bug.** It breaks.\n- **[P2] A missing test.** Add one.\n\nVERDICT: FIX\n' >"$T/$ROOT_T/pr-review/round-1.findings.md"

if [ "$SABOTAGE" != 1 ]; then
    mkdir -p "$T/$FOLLOW/pr-review"
    goal "$FOLLOW" "Follow-up" "workbench/$ROOT_T" >"$T/$FOLLOW/goal.md"
    {
        ev 1 0 thread.created "{\"parent\":\"$ROOT_T\",\"root\":\"$ROOT_T\",\"round\":1}"
        ev 2 1 turn.started
        ev 3 1 turn.ended '{"result":"succeeded","cost_usd":0.5,"summary":"Fixed the bug. Left the test."}'
        ev 4 0 pr_review.started '{"round":2,"pr":7}'
        ev 5 0 pr_review.finished '{"round":2,"pr":7,"ok":true,"verdict":"clean","findings_path":"pr-review/round-2.findings.md"}'
    } >"$T/$FOLLOW/events.jsonl"
    printf 'No findings.\nVERDICT: CLEAN\n' >"$T/$FOLLOW/pr-review/round-2.findings.md"
else
    echo "    VERIFY_CLI_SABOTAGE=1: the follow-up thread is left out"
fi
mkdir -p "$T/$HAND"
goal "$HAND" "Rework" "workbench/$ROOT_T" >"$T/$HAND/goal.md"
{ ev 1 0 thread.created; ev 2 1 turn.started; ev 3 1 turn.ended '{"result":"succeeded","cost_usd":0.25,"summary":"Removed the job."}'; } >"$T/$HAND/events.jsonl"

SD="$P/.workbench/series/rp"
mkdir -p "$SD"
goal x "Report scenario goal" >"$SD/g.md"
printf -- '---\nbudget_usd: 10.00\n---\n## 1\nproject: %s\ngoal: g.md\n' "$P" >"$SD/series.md"
printf '{"at":"t","step":1,"thread":"%s"}\n' "$ROOT_T" >"$SD/steps.jsonl"

wbp "$SCRATCH/report.out" series report rp
sed 's/^/    /' "$SCRATCH/report.out" | head -30
has() { grep -q -- "$1" "$SCRATCH/report.out"; }
check "report: exit 0 and the summary line names the budget" "exit $RC: $(head -c 300 "$SCRATCH/report.out.err")" \
    bash -c '[ "$1" = 0 ] && grep -q "of the \$10.00 series budget" "$2"' _ "$RC" "$SCRATCH/report.out"
check "the table shows the rounds FIX → CLEAN" "$(grep '^| 1' "$SCRATCH/report.out")" has "FIX → CLEAN"
check "the findings are listed with severity and title" "no P1 line" \
    bash -c 'grep -q "P1 A real bug" "$1" && grep -q "P2 A missing test" "$1"' _ "$SCRATCH/report.out"
check "the follow-up that answered round 1 is named with what it said" "no 'Answered by'" \
    bash -c 'grep -q "Answered by .'"$FOLLOW"'." "$1" && grep -q "Fixed the bug. Left the test." "$1"' _ "$SCRATCH/report.out"
check "the work done by hand on the branch is shown" "no hand-made section" \
    bash -c 'grep -q "Also pushed to this branch by hand" "$1" && grep -q "Removed the job." "$1"' _ "$SCRATCH/report.out"
check "the judge's reading says which turn it is of" "$(grep judge "$SCRATCH/report.out" | head -1)" \
    has "judge after turn 1, before the review fixes: 1 of 2 criteria met"
check "the total counts every thread (1.00 + 0.50 + 0.25)" "$(grep 'Coding turns' "$SCRATCH/report.out")" has 'Coding turns cost \$1.75'
check "report.md was written in the series folder and equals what was printed" "diff: $(diff "$SD/report.md" "$SCRATCH/report.out" | head -3)" \
    cmp -s "$SD/report.md" "$SCRATCH/report.out"
finish
