#!/bin/bash
# Runs Codex's `$pr-review` skill on a pull request and prints what it found. Read-only: it does not build,
# run tests or post anything; posting a review is the user's call (see .agents/skills/pr-review).
#
#   scripts/codex-review.sh <pr-number> [spec-file]
#
# `spec-file` is what the change was written against (a goal file, a task from a plan). Without it Codex
# reviews against the PR description. The full transcript is kept in .workbench/reviews/.
set -u
cd "$(dirname "$0")/.." || exit 1

pr=${1:-}
spec=${2:-}
if [[ ! $pr =~ ^[0-9]+$ ]]; then
    echo "usage: scripts/codex-review.sh <pr-number> [spec-file]" >&2
    exit 2
fi
for tool in gh codex python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is missing" >&2; exit 1; }
done
[[ -z $spec || -f $spec ]] || { echo "error: no such spec file: $spec" >&2; exit 2; }

sha=$(gh pr view "$pr" --json headRefOid -q .headRefOid) || exit 1
work=$(mktemp -d "${TMPDIR:-/tmp}/codex-review.XXXXXX")
tree="$work/tree"
cleanup() {
    git worktree remove --force "$tree" >/dev/null 2>&1
    rm -rf "$work"
}
trap cleanup EXIT

# The PR head as it is on GitHub, in a throwaway detached worktree: Codex reads the files, not a patch.
git fetch -q origin "pull/$pr/head" || { echo "error: cannot fetch PR $pr" >&2; exit 1; }
git worktree add -q --detach "$tree" "$sha" || exit 1
gh pr diff "$pr" > "$work/diff.patch" || exit 1

{
    echo '$pr-review'
    echo
    echo "Review pull request #$pr of this repository with the pr-review skill"
    echo "(.agents/skills/pr-review/SKILL.md). The working directory is checked out at the PR head."
    echo
    echo "Do not run builds or the test suite: read files and the diff only. Do not post anything anywhere."
    echo "\`gh\` may not be reachable from your sandbox; the diff is saved at $work/diff.patch."
    if [[ -n $spec ]]; then
        echo "The change was written against this spec (criteria are numbered): $(cd "$(dirname "$spec")" && pwd)/$(basename "$spec")"
    else
        echo "There is no separate spec: judge the change against the PR description and the plan it cites."
    fi
    echo
    echo "Report, most severe first and each with a concrete failure scenario:"
    echo "1. If there is a spec: each criterion as holds / does not hold / cannot tell, with file and line."
    echo "   A test existing is not enough: say whether it would fail without the behaviour."
    echo "2. Findings per the skill's Step 3."
    echo "3. Anything the spec asked for that is missing, and anything the change does that was not asked for."
    echo "Keep it under 90 lines."
} > "$work/prompt.md"

mkdir -p .workbench/reviews
log=".workbench/reviews/pr-$pr-${sha:0:7}.txt"
# "Selected model is at capacity" happens and passes; try again before giving up. Only when there is no answer:
# the log also holds every file Codex read, and this repo's own code and docs contain that phrase.
for attempt in 1 2 3; do
    codex exec -s read-only -C "$tree" - < "$work/prompt.md" > "$log" 2>&1
    grep -q "model is at capacity" "$log" && ! grep -q '^codex$' "$log" || break
    echo "codex: model at capacity (attempt $attempt of 3)" >&2
    sleep $((attempt * 20))
done

python3 - "$log" <<'PY'
import sys
text = open(sys.argv[1]).read()
if "model is at capacity" in text and "\ncodex\n" not in text:
    print("Codex was at capacity three times; no review. Try again later.")
    sys.exit(3)
i = text.rfind("\ncodex\n")
answer = text[i + 7:] if i >= 0 else text[-6000:]
j = answer.find("\ntokens used")
print(answer[:j] if j > 0 else answer)
PY
status=$?
echo
echo "transcript: $log"
exit $status
