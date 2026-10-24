#!/bin/sh
# What CI saw, without trusting the local environment: the status of a PR's checks, the failed steps' log, and
# the test timings the Test step published.
#   scripts/ci-report.sh [<pr-number>]     default: the PR of the current branch
#   scripts/ci-report.sh --run <run-id>    a specific run
# Needs gh. Timings come from the `test-reports` artifact (timings.md, timings.json, test.log, soak.log).
set -u
cd "$(dirname "$0")/.." || exit 1

if [ "${1:-}" = "--run" ]; then
    run=${2:?run id}
else
    pr=${1:-$(gh pr view --json number --jq .number)} || exit 1
    # By head commit, not branch name: a fork or a reused branch name could match another PR's run.
    sha=$(gh pr view "$pr" --json headRefOid --jq .headRefOid) || exit 1
    run=$(gh run list --commit "$sha" --workflow CI --event pull_request --limit 1 --json databaseId --jq '.[0].databaseId') || exit 1
    echo "==> PR #$pr, head $sha"
    gh pr checks "$pr"
fi
[ -n "${run:-}" ] || { echo "error: no CI run found" >&2; exit 1; }

echo "==> run $run"
gh run view "$run" --json status,conclusion,headSha --jq '"\(.status) \(.conclusion) \(.headSha)"'
dir=$(mktemp -d)
if gh run view "$run" --log-failed 2>/dev/null | head -80 | grep . ; then :; else echo "(no failed steps)"; fi
if gh run download "$run" -n test-reports -D "$dir" >/dev/null 2>&1; then
    echo "==> timings (full files in $dir)"
    cat "$dir/timings.md"
else
    echo "(no test-reports artifact: the Test step did not run or the run is still going)"
fi
