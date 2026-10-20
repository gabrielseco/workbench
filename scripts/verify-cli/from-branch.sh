#!/bin/bash
# Runs a verify-cli scenario on a branch the way AGENTS.md asks (normally, then with VERIFY_CLI_SABOTAGE=1) without touching
# your checkout, and prints what the pull request description needs.
#   scripts/verify-cli/from-branch.sh <scenario> [branch] [--no-sabotage] [--keep]
# <scenario> is a name in scripts/verify-cli/ (`thread-setup`, `help`, ...). <branch> defaults to the current branch of the
# checkout the script is run in (a worktree is fine). The branch is cloned into a temp folder, which is a main checkout of its
# own as the scenarios require; the project's `.workbench/config.toml` is copied in from this repository's main checkout (it is
# not tracked). The scenario then runs with VERIFY_CLI_FROM_BRANCH=1.
# Exit 0 only when the normal run passed and the sabotaged run failed (a sabotage that still passes proved nothing). Costs what
# the scenario costs: a scenario that starts a turn spends real money (it caps itself), say so before running one.
set -u

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
scenario="" branch="" sabotage=1 keep=0
for arg in "$@"; do
    case "$arg" in
        --no-sabotage) sabotage=0 ;;
        --keep) keep=1 ;;
        -h | --help) usage ;;
        -*) echo "unknown option: $arg" >&2; usage ;;
        *) if [ -z "$scenario" ]; then scenario=$arg; elif [ -z "$branch" ]; then branch=$arg; else usage; fi ;;
    esac
done
[ -n "$scenario" ] || usage
[[ $scenario =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || { echo "bad scenario name: $scenario" >&2; exit 2; }

here=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "not in a git repository" >&2; exit 2; }
[ -f "$here/scripts/verify-cli/$scenario.sh" ] || { echo "no scripts/verify-cli/$scenario.sh in $here" >&2; exit 2; }
# The main checkout is where the untracked config lives: the parent of the common git directory.
common=$(cd "$here" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
main_checkout=$(dirname "$common")
config="$main_checkout/.workbench/config.toml"
[ -f "$config" ] || { echo "no $config to copy: run \`workbench init\` in the main checkout first" >&2; exit 2; }
[ -n "$branch" ] || branch=$(git -C "$here" rev-parse --abbrev-ref HEAD)
[ "$branch" != HEAD ] || { echo "detached HEAD: name the branch" >&2; exit 2; }
git -C "$here" rev-parse --verify -q "refs/heads/$branch" >/dev/null || { echo "no local branch $branch" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/tmp}/verify-cli-from-branch.XXXXXX") || exit 2
cleanup() { [ "$keep" = 1 ] || rm -rf "$work"; }
trap cleanup EXIT
git clone -q -b "$branch" "$here" "$work/repo" || { echo "git clone failed" >&2; exit 2; }
mkdir -p "$work/repo/.workbench" && cp "$config" "$work/repo/.workbench/config.toml"
sha=$(git -C "$work/repo" rev-parse --short HEAD)
echo "==> $scenario on $branch ($sha), in $work/repo" >&2

run() { # run <label> <SABOTAGE value>; the log is $work/<label>.log
    (cd "$work/repo" && VERIFY_CLI_FROM_BRANCH=1 VERIFY_CLI_SABOTAGE="$2" bash "scripts/verify-cli/$scenario.sh" >"$work/$1.log" 2>&1)
}
result() { grep -E '^RESULT' "$work/$1.log" | tail -1; }

echo "==> normal run" >&2
run normal 0; normal_rc=$?
sabotage_rc=""
if [ "$sabotage" = 1 ]; then
    echo "==> sabotaged run (it must fail)" >&2
    run sabotaged 1; sabotage_rc=$?
fi

echo
echo "## verify-cli: \`scripts/verify-cli/$scenario.sh\` on \`$branch\` ($sha)"
echo
echo "Normal run:"
echo
echo '```'
grep -E '^(FAIL|RESULT)' "$work/normal.log" || echo "(no RESULT line: see $work/normal.log)"
echo '```'
if [ "$sabotage" = 1 ]; then
    echo
    echo "With \`VERIFY_CLI_SABOTAGE=1\` (the steps its header names must FAIL):"
    echo
    echo '```'
    grep -E '^(FAIL|RESULT)' "$work/sabotaged.log" || echo "(no RESULT line: see $work/sabotaged.log)"
    echo '```'
fi

status=0
if [ "$normal_rc" != 0 ]; then echo "normal run did not pass (exit $normal_rc); logs kept in $work" >&2; keep=1; status=1; fi
if [ "$sabotage" = 1 ] && [ "$sabotage_rc" = 0 ]; then
    echo "the sabotaged run PASSED: the sabotage broke nothing, so the scenario proves less than it says; logs kept in $work" >&2
    keep=1; status=1
fi
exit $status
