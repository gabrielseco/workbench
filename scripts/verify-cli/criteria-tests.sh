#!/bin/bash
# verify-cli scenario for criteria backed by the tests the check ran (P15 task 3), with the real `claude`, on this repository.
#   bash scripts/verify-cli/criteria-tests.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/criteria-tests.sh   (the same, on a branch that contains origin/main)
# Runs one throwaway thread whose turn touches one Swift file, so the project check (scripts/check-changed.sh) runs the
# suite that covers it. The goal has two `proof: test:` criteria: one names a test of that suite, one names a test that
# does not exist. `review` must show the first as passed with "named test ran in the check" and leave the second to the
# person. Costs at most the turn cap ($VERIFY_CLI_BUDGET_USD, default 0.50) plus the time of the suite. Exit 0 only when
# every step passed, 1 when one failed, 2 when it refused to start (nothing changed). VERIFY_CLI_SABOTAGE=1 makes the first
# criterion name a test that does not exist, so the steps that expect it passed must FAIL. The frame and the other
# switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

GOAL_SRC="$SCRATCH/goal.md"
cat >"$GOAL_SRC" <<'GOAL'
---
id: verify-cli-criteria-tests
title: verify-cli criteria-tests scenario
base: origin/main
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

This is a throwaway thread that tests how `workbench review` reads criteria. Append one line, `// verify-cli probe`,
to the end of `Sources/WorkbenchCore/Goal/ScreenshotProof.swift`. Change nothing else, do not commit, and do not run
any test yourself: Workbench runs the check after your turn.

## Criteria

- [c1] The file ends with the line `// verify-cli probe`.
  - proof: test: ScreenshotProofTests/aScreenshotProofNamesOneFile
- [c2] Nothing else changed.
  - proof: test: ScreenshotProofTests/noSuchTestAnywhere

## Out of scope

- Any other file, and committing.
GOAL
if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: c1 names a test that does not exist"
    perl -pi -e 's#aScreenshotProofNamesOneFile#aTestThatWasNeverWritten#' "$GOAL_SRC"
fi

start_thread verify-cli-criteria-tests "$GOAL_SRC"
remove_on_pass branch "$BRANCH"
run_thread

check_ran() { # the check.ran event of the turn carries the tests it saw
    wb "$T_WB" log "$ID" --json | py "c=[e['data'] for e in lines if e['kind']=='check.ran']
t=c[-1].get('tests_passed') if c else None
print('    check result %s, %d test(s) seen passing' % (c[-1]['result'] if c else 'none', len(t or [])))
sys.exit(0 if t else 1)"
}
check "check.ran records the tests the output showed passing" "no tests_passed on the last check.ran" check_ran

criterion() { # <id> <field>: that field of the criterion in review --json
    wb "$T_WB" review "$ID" --json | py "print(next((c['$2'] or '' for c in d['criteria'] if c['id']=='$1'), ''))"
}
s1=$(criterion c1 status); n1=$(criterion c1 note)
s2=$(criterion c2 status)
echo "    c1: $s1 ($n1); c2: $s2"
check "review: c1 (a test the check ran) is passed" "c1 is '$s1'" test "$s1" = passed
check "review: c1 says the named test ran in the check" "note is '$n1'" bash -c '[[ $1 == "named test ran in the check, turn "* ]]' _ "$n1"
check "review: c2 (a test that never appeared) is left to a person" "c2 is '$s2'" test "$s2" = manual

text=$(wb "$T_WB" review "$ID" 2>&1)
echo "$text" | grep -E '^\s+\[c[0-9]\]' | sed 's/^/    /'
check "review text shows c1 as passed" "no passed row for c1" bash -c 'grep -q "\[c1\] ✔ passed" <<<"$1"' _ "$text"

wb "$T_WB" abandon "$ID" >/dev/null 2>&1
ended=$(wb "$T_WB" status "$ID" --json | py "print(d['ended'])")
check "abandon ends the thread" "status says ended: $ended" test "$ended" = abandoned
finish
