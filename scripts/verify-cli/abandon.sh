#!/bin/bash
# verify-cli scenario for `workbench abandon` (P12 task 1), with the real `claude`, on this repository.
#   bash scripts/verify-cli/abandon.sh      (in the main checkout, on a clean origin/main, no active thread)
# Builds .build/debug/workbench, runs one throwaway thread (goal new, goal approve, run), leaves its worktree
# dirty in five ways, abandons it and prints PASS or FAIL per step. Exit 0 only when every step passed,
# 1 when one failed, 2 when it refused to start (nothing changed).
# Costs one real turn: VERIFY_CLI_BUDGET_USD caps it (default 0.50), VERIFY_CLI_MODEL picks the model
# (default haiku). VERIFY_CLI_SABOTAGE=1 deletes abandon.patch before the assertions, to see a FAIL.
# Run by hand, not by CI. See .agents/skills/verify-cli/SKILL.md.
set -u

BUDGET_USD=${VERIFY_CLI_BUDGET_USD:-0.50}
MODEL=${VERIFY_CLI_MODEL:-haiku}
TURN_TIMEOUT_MIN=10
# Seconds per command; `run` holds the turn plus the project's check.
T_BUILD=900
T_GIT=60
T_WB=120
T_RUN=$(( (TURN_TIMEOUT_MIN + 10) * 60 ))

SCRATCH=""
die() { echo "refused: $*" >&2; [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"; exit 2; }

CHILD=""
# Runs "$@" for at most $1 seconds: SIGTERM first (a `workbench run` then stops its turn and records it),
# SIGKILL 10 s later. The watchdog's stdout goes nowhere, so `$(with_timeout ...)` does not wait for it.
with_timeout() {
    local secs=$1; shift
    "$@" &
    local pid=$!
    CHILD=$pid
    ( sleep "$secs" && { kill -TERM "$pid" 2>/dev/null || exit 0
        echo "timed out after ${secs}s: $*" >&2; sleep 10 && kill -KILL "$pid" 2>/dev/null; } ) >/dev/null &
    local dog=$!
    wait "$pid"
    local rc=$?
    CHILD=""
    # Ending the watchdog's sleep ends the watchdog: each step after a sleep needs the sleep to have finished.
    pkill -P "$dog" 2>/dev/null; wait "$dog" 2>/dev/null
    return $rc
}

# A workbench command, printed before it runs and kept for the summary (in a file: `$(wb ...)` is a subshell).
wb() {
    local secs=$1; shift
    echo "\$ workbench $*" >&2
    [ -n "$SCRATCH" ] && echo "workbench $*" >>"$SCRATCH/commands"
    with_timeout "$secs" "$WB" "$@"
}

g() { with_timeout "$T_GIT" git "$@"; }

# Reads JSON on stdin with Python code over `d` (one document, else None) and `lines` (JSON lines).
py() { python3 -I -c "import json,sys
def _p(s):
    try: return json.loads(s)
    except ValueError: return None
raw=sys.stdin.read()
d=_p(raw)
lines=[x for x in map(_p, raw.splitlines()) if isinstance(x, dict)]
$1"; }

# --- refuse before anything changes -------------------------------------------------------------------

command -v python3 >/dev/null || die "python3 is needed to read workbench's JSON"
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die "not in a git repository"
cd "$ROOT" || die "cannot enter $ROOT"
[ "$(git rev-parse --absolute-git-dir)" = "$(cd "$(git rev-parse --git-common-dir)" && pwd -P)" ] \
    || die "run it in the main checkout of this repository, not in a linked worktree"
[ -f Package.swift ] && [ -f scripts/verify-cli/abandon.sh ] || die "$ROOT is not the Workbench repository"
[[ $BUDGET_USD =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "VERIFY_CLI_BUDGET_USD must be a number of dollars, got '$BUDGET_USD'"
[[ $MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "VERIFY_CLI_MODEL is not a model name: '$MODEL'"

[ -z "$(git status --porcelain)" ] || die "the checkout has local changes (git status); commit or set them aside"
remote_main=$(with_timeout "$T_GIT" git ls-remote origin refs/heads/main | cut -f1)
[ -n "$remote_main" ] || die "could not read main from origin"
[ "$(git rev-parse HEAD)" = "$remote_main" ] || die "HEAD is not origin's main ($remote_main); check it out first"
[ "$(git rev-parse -q --verify origin/main)" = "$remote_main" ] \
    || die "origin/main is behind origin; run git fetch origin main"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/verify-cli-abandon.XXXXXX") || die "mktemp failed"
echo "==> building workbench"
with_timeout "$T_BUILD" swift build --product workbench || die "swift build failed"
WB="$ROOT/.build/debug/workbench"
[ -x "$WB" ] || die "no $WB after the build"

active=$(wb "$T_WB" status --all --json | py "print(' '.join(t['thread'] for t in d['threads'] if t['ended'] is None))") \
    || die "workbench status --all --json failed"
[ -z "$active" ] || die "thread $active is active here (one project, one active thread); end it first"

claude=$(wb "$T_WB" config | sed -n 's/^claude: *//p')
case "$claude" in
    ""|NOT\ FOUND*) die "claude_path does not resolve: '${claude}'" ;;
    *fake-claude*) die "claude_path resolves to the test double ($claude); this scenario needs the real claude" ;;
esac
echo "==> claude: $claude"

# --- the thread ---------------------------------------------------------------------------------------

GOAL_SRC="$SCRATCH/goal.md"
EXPECT="$SCRATCH/expect"
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

PASSED=()
FAILED=()
pass() { PASSED+=("$1"); printf 'PASS  %s\n' "$1"; }
fail() { FAILED+=("$1"); printf 'FAIL  %s: %s\n' "$1" "$2"; }
check() { local name=$1 why=$2; shift 2; if "$@"; then pass "$name"; else fail "$name" "$why"; fi; }

ID=""
BRANCH=""
RESTORE="$SCRATCH/restore"
RESTORE_STAGED="$SCRATCH/restore-staged"
interrupted() {
    # A background child does not get the terminal's Ctrl-C; a run asked with SIGTERM records its turn as stopped.
    [ -n "$CHILD" ] && kill -TERM "$CHILD" 2>/dev/null && wait "$CHILD"
    echo
    echo "interrupted; left as they are: thread ${ID:-none}, branch ${BRANCH:-none}, $SCRATCH"
    [ -n "$ID" ] && echo "if the thread is still active: $WB abandon --force"
    exit 130
}
trap interrupted INT TERM

created=$(wb "$T_WB" goal new verify-cli-abandon --base origin/main --from "$GOAL_SRC") || {
    echo "$created"; die "goal new failed"; }
echo "$created"
ID=$(echo "$created" | sed -n 's/^created //p')
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id"
BRANCH="workbench/$ID"
THREAD_DIR="$ROOT/.workbench/threads/$ID"
# The draft takes the config's budget and a 30 minute timeout; this run is capped lower and uses $MODEL.
perl -pi -e "s/^budget_usd: .*/budget_usd: $BUDGET_USD/; s/^turn_timeout_min: .*/turn_timeout_min: $TURN_TIMEOUT_MIN/; s/^# model: .*/model: $MODEL/" \
    "$THREAD_DIR/goal.md"

wb "$T_WB" goal approve "$ID"
goal=$(wb "$T_WB" status "$ID" --json | py "g=d['goal']; print(g['approval'], g['budget_usd'], g['turn_timeout_min'])")
read -r approval budget timeout <<<"$goal"
# Never spend more than asked: a goal that did not take the cap is ended before any turn.
if ! python3 -I -c "import sys; sys.exit(abs(float(sys.argv[1]) - float(sys.argv[2])) > 1e-9)" "${budget:-x}" "$BUDGET_USD" 2>/dev/null \
    || [ "${timeout:-}" != "$TURN_TIMEOUT_MIN" ]; then
    wb "$T_WB" abandon "$ID"
    die "the goal has budget '${budget:-?}' and timeout '${timeout:-?}', not $BUDGET_USD and $TURN_TIMEOUT_MIN; thread $ID abandoned unrun"
fi
check "goal approved with a $BUDGET_USD USD cap" "approval is '${approval:-?}'" test "${approval:-}" = approved

wb "$T_RUN" run "$ID"
run_exit=$?
check "run: the turn succeeded" "workbench run exited $run_exit" test "$run_exit" = 0

LOG=$(wb "$T_WB" log "$ID" --json)
argv0=$(echo "$LOG" | py "s=[e for e in lines if e['kind']=='turn.started']; print(s[-1]['data']['argv'][0] if s else '')")
stream=$(echo "$LOG" | py "c=[e['data'] for e in lines if e['kind']=='claude']
init=[x for x in c if isinstance(x,dict) and x.get('type')=='system' and x.get('subtype')=='init']
print(len(c), init[0].get('model','?') if init else '-', init[0].get('claude_code_version','?') if init else '-')")
echo "    turn argv[0]: $argv0; claude lines, model, version: $stream"
real_claude() { [ -n "$argv0" ] && [[ $argv0 != *fake-claude* ]] && [ "${stream%% *}" -gt 0 ] && [[ $stream != *" - -" ]]; }
check "run: real claude stream lines in the log" "argv[0] '$argv0', stream '$stream'" real_claude

WT=$(wb "$T_WB" status "$ID" --json | py "print(d['worktree']['path'] or '')")
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
    fail "worktree left by run" "no worktree at '${WT}'"
else
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
    git -C "$WT" status --short | sed 's/^/    /'
fi

# --- abandon and assert -------------------------------------------------------------------------------

wb "$T_WB" abandon "$ID"
abandon_exit=$?
check "abandon exits 0 without --force" "exit $abandon_exit" test "$abandon_exit" = 0

if [ "${VERIFY_CLI_SABOTAGE:-0}" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: deleting $THREAD_DIR/abandon.patch"
    rm -f "$THREAD_DIR/abandon.patch"
fi

check "worktree gone" "${WT:-?} is still there or registered" \
    bash -c '[ -n "$1" ] && [ ! -e "$1" ] && ! git worktree list --porcelain | grep -qxF "worktree $1"' _ "${WT:-}"
check "branch $BRANCH kept" "no such branch" git rev-parse -q --verify "refs/heads/$BRANCH"
check "abandon.patch and abandon-staged.patch exist" "missing in $THREAD_DIR" \
    test -s "$THREAD_DIR/abandon.patch" -a -s "$THREAD_DIR/abandon-staged.patch"

LOG=$(wb "$T_WB" log "$ID" --json)
saved=$(echo "$LOG" | py "s=[e['data'] for e in lines if e['kind']=='abandon.saved']
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

same() { cmp -s "$1" "$2" || { echo "    differs: $2"; return 1; }; }
restore_working() {
    [ "$(git rev-parse "$BRANCH" 2>/dev/null)" = "$HEAD_SAVED" ] || { echo "    branch tip is not the saved head"; return 1; }
    g worktree add --detach "$RESTORE" "$BRANCH" >/dev/null 2>&1 || { echo "    could not check out $BRANCH"; return 1; }
    g -C "$RESTORE" apply "$THREAD_DIR/abandon.patch" || return 1
    same "$EXPECT/README.md" "$RESTORE/README.md" && same "$EXPECT/staged-edited.txt" "$RESTORE/verify-cli/staged-edited.txt" \
        && same "$EXPECT/untracked.txt" "$RESTORE/verify-cli/untracked.txt" && same "$EXPECT/blob.bin" "$RESTORE/verify-cli/blob.bin"
}
restore_staged() {
    g worktree add --detach "$RESTORE_STAGED" "$BRANCH" >/dev/null 2>&1 || { echo "    could not check out $BRANCH"; return 1; }
    g -C "$RESTORE_STAGED" apply "$THREAD_DIR/abandon-staged.patch" || return 1
    [ "$(cat "$RESTORE_STAGED/verify-cli/staged-edited.txt" 2>/dev/null)" = "staged version" ] \
        && [ "$(cat "$RESTORE_STAGED/verify-cli/staged-deleted.txt" 2>/dev/null)" = "staged then deleted" ] \
        || { echo "    staged-only content not restored"; return 1; }
}
check "git apply abandon.patch on $BRANCH restores the modified, untracked and binary files" "see above" restore_working
check "git apply abandon-staged.patch restores the staged-only content" "see above" restore_staged

left=$( [ -n "${WT:-}" ] && pgrep -fl "$WT")
check "no process of the worktree left" "$left" test -z "$left"

# --- summary ------------------------------------------------------------------------------------------

cost=$(echo "$LOG" | py "e=[x['data'] for x in lines if x['kind']=='turn.ended']
print('%.4f USD over %d turn(s)' % (sum(x.get('cost_usd') or 0 for x in e), len(e)))")

echo
echo "commands run:"
sed 's/^/  /' "$SCRATCH/commands"
echo "cost of the real turn: $cost (cap $BUDGET_USD USD, model $MODEL)"
echo "thread log kept: $THREAD_DIR"
if [ ${#FAILED[@]} -eq 0 ]; then
    g worktree remove --force "$RESTORE" >/dev/null 2>&1
    g worktree remove --force "$RESTORE_STAGED" >/dev/null 2>&1
    g branch -D "$BRANCH" >/dev/null
    rm -rf "$SCRATCH"
    echo "removed: branch $BRANCH, the restore checkouts and $SCRATCH"
    echo "RESULT: PASS (${#PASSED[@]} steps)"
    exit 0
fi
echo "kept for a look: branch $BRANCH, checkouts $RESTORE and $RESTORE_STAGED (if made), $SCRATCH"
echo "  remove with: git worktree remove --force <checkout>; git branch -D $BRANCH; rm -rf $SCRATCH"
echo "RESULT: FAIL (${#FAILED[@]} of $(( ${#PASSED[@]} + ${#FAILED[@]} ))): $(IFS=';'; echo "${FAILED[*]}")"
exit 1
