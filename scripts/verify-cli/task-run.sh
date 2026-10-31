#!/bin/bash
# verify-cli scenario for running a scheduled task (`task run`, `task tick`), on a clone of this repository whose origin is a bare
# copy in the temp folder, with a `claude` stand-in that runs the fake-claude test double and a `gh` stand-in that keeps pull
# requests in a file. Nothing real is contacted and no real turn runs, so it costs nothing.
#   bash scripts/verify-cli/task-run.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/task-run.sh   (the same, on a branch that contains origin/main)
# A task reads a plain text list of three countries (its input) through a pending script and takes two at a time. The first
# `task run` must open one pull request for ROU and TUR, accepted by the task (`by: task:bump`) and pushed to origin; the
# second must take only PAN; the third must say nothing-pending and start no thread. The task's own log must hold the approval
# and three run ends with those outcomes. While a thread is active `task run` must exit 6 as skipped-project-busy, and after
# the task file is edited it must exit 6 as stale-approval and start nothing; `task tick` must find nothing due. Exit 0 only
# when every step passed, 1 when one failed, 2 when it refused to start (nothing changed).
# VERIFY_CLI_SABOTAGE=1 makes the stand-in gh say every pull request it opened was closed unmerged, so the units come back:
# "the second run takes only the last country", "the third run finds nothing pending", "the third run started no thread" and
# "the log holds one approval and three run ends" must FAIL. The frame is in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

echo "==> building fake-claude"
with_timeout "$T_BUILD" swift build --product fake-claude || die "swift build --product fake-claude failed"
FAKE="$ROOT/.build/debug/fake-claude"
[ -x "$FAKE" ] || die "no $FAKE after the build"

ORIGIN="$SCRATCH/origin.git"
P="$SCRATCH/project"
BIN="$SCRATCH/bin"
GHDIR="$SCRATCH/gh"
g clone -q --bare "$ROOT" "$ORIGIN" || die "git clone --bare failed"
g -C "$ORIGIN" update-ref refs/heads/main "$BASE_SHA" || die "could not set main in the bare copy"
g -C "$ORIGIN" symbolic-ref HEAD refs/heads/main || die "could not point the bare copy's HEAD at main"
g clone -q "$ORIGIN" "$P" || die "git clone failed"
g -C "$P" checkout -q -B main origin/main || die "could not check out main in the clone"
mkdir -p "$BIN" "$GHDIR" || die "could not make the stand-in folders"

# The description the stand-in claude gives the describing turn.
echo '{"title": "chore: bump countries", "summary": "Bumps the next countries.", "decisions": [], "deviations": []}' >"$SCRATCH/answer.txt"
cat >"$BIN/claude" <<STUB
#!/bin/sh
FAKE_CLAUDE=write=task-probe.txt,answer=$SCRATCH/answer.txt exec '$FAKE' "\$@"
STUB
# A gh that is logged in, opens pull requests into a file, and answers `pr list --head X` for the branches it opened.
STATE=OPEN
[ "$SABOTAGE" = 1 ] && STATE=CLOSED
cat >"$BIN/gh" <<STUB
#!/bin/sh
echo "\$@" >>"$GHDIR/calls"
head=""; prev=""
for a in "\$@"; do [ "\$prev" = "--head" ] && head=\$a; prev=\$a; done
case "\$1 \$2" in
"auth status") exit 0 ;;
"pr list")
    if [ -n "\$head" ] && grep -qx "\$head" "$GHDIR/heads" 2>/dev/null; then echo '[{"state":"$STATE"}]'; else echo '[]'; fi
    exit 0 ;;
"pr create")
    echo "\$head" >>"$GHDIR/heads"
    echo "https://github.com/o/r/pull/\$(wc -l <"$GHDIR/heads" | tr -d ' ')"
    exit 0 ;;
esac
echo "verify-cli stand-in gh: \$*" >&2
exit 2
STUB
chmod +x "$BIN/claude" "$BIN/gh"
[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the stand-in gh says every pull request was closed unmerged"
echo "==> clone at $P, stand-ins in $BIN"

RC=0
wbp() { # <out> args...: a workbench command in the clone with the stand-ins, stdout and stderr together; sets RC
    local o=$1 secs=$T_WB; shift
    case "$1" in task) [ "$2" = run ] || [ "$2" = tick ] && secs=$T_RUN ;; esac
    echo "workbench $*   (in the clone)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    ( cd "$P" && PATH="$BIN:$PATH" with_timeout "$secs" "$WB" "$@" >"$o" 2>&1 )
    RC=$?
}
shown() { sed 's/^/    /' "$1" | head -${2:-10}; }
threads() { ls "$P/.workbench/threads" 2>/dev/null | wc -l | tr -d ' '; }

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
cat >"$P/.workbench/config.toml" <<TOML
claude_path = "$BIN/claude"
check_command = "true"
default_budget_usd = 0.10

[tools]
available = ["Read", "Edit", "Write"]
allowed = ["Read", "Edit", "Write"]
TOML

TASK="$P/.workbench/tasks/bump"
mkdir -p "$TASK"
printf 'ROU\nTUR\nPAN\n' >"$P/countries.txt"
cat >"$TASK/pending.sh" <<'SH'
#!/bin/sh
# One unit per line of countries.txt.
printf '['
sed 's/.*/{"id":"&","title":"bump &"}/' countries.txt | paste -sd, -
printf ']\n'
SH
chmod +x "$TASK/pending.sh"
printf -- '---\nbatch: 2\nfix: pr\ninputs: countries.txt\npending: .workbench/tasks/bump/pending.sh\n---\nBump the next countries.\n' >"$TASK/task.md"

# --- 1. approve and run ------------------------------------------------------------------------------------

wbp "$SCRATCH/approve.out" task approve bump
check "approve records the task" "exit $RC: $(head -c 200 "$SCRATCH/approve.out")" test "$RC" = 0

wbp "$SCRATCH/run1.out" task run bump; shown "$SCRATCH/run1.out"
check "the first run opens a pull request for the first two countries" "exit $RC: $(head -c 400 "$SCRATCH/run1.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "^bump: pr-opened" "$2" && grep -q "units:  ROU, TUR" "$2" && grep -q "pull request: https://github.com/o/r/pull/1" "$2"' _ "$RC" "$SCRATCH/run1.out"
THREAD=$(sed -n 's/^  thread: //p' "$SCRATCH/run1.out" | head -1)
check "the thread was accepted by the task and its branch is on origin" "thread '$THREAD'" \
    bash -c 'grep -q "\"by\":\"task:bump\"" "$1/.workbench/threads/$2/events.jsonl" && git -C "$3" rev-parse -q --verify "refs/heads/workbench/$2" >/dev/null' _ "$P" "$THREAD" "$ORIGIN"
check "exactly one pull request was opened" "gh calls: $(grep -c 'pr create' "$GHDIR/calls")" test "$(grep -c 'pr create' "$GHDIR/calls")" = 1

wbp "$SCRATCH/run2.out" task run bump; shown "$SCRATCH/run2.out"
check "the second run takes only the last country" "exit $RC: $(head -c 300 "$SCRATCH/run2.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "^bump: pr-opened" "$2" && grep -q "units:  PAN$" "$2"' _ "$RC" "$SCRATCH/run2.out"
BEFORE=$(threads)
wbp "$SCRATCH/run3.out" task run bump; shown "$SCRATCH/run3.out"
check "the third run finds nothing pending" "exit $RC: $(head -c 300 "$SCRATCH/run3.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "^bump: nothing-pending" "$2"' _ "$RC" "$SCRATCH/run3.out"
check "the third run started no thread" "threads: $BEFORE -> $(threads)" test "$(threads)" = "$BEFORE"

# --- 2. the task's own log ---------------------------------------------------------------------------------

LOG="$TASK/runs.jsonl"
check "the log holds one approval and three run ends with their outcomes" "log: $(grep -o '"kind":"[a-z.]*"\|"outcome":"[a-z-]*"' "$LOG" 2>&1 | tr '\n' ' ')" \
    bash -c '[ "$(grep -c "\"kind\":\"task.approved\"" "$1")" = 1 ] && [ "$(grep -c "\"kind\":\"task.run.started\"" "$1")" = 3 ] && [ "$(grep -o "\"outcome\":\"[a-z-]*\"" "$1" | tr "\n" " ")" = "\"outcome\":\"pr-opened\" \"outcome\":\"pr-opened\" \"outcome\":\"nothing-pending\" " ]' _ "$LOG"

# --- 3. what stops a run -----------------------------------------------------------------------------------

wbp "$SCRATCH/blocker.out" goal new blocker
wbp "$SCRATCH/busy.out" task run bump
check "a run while a thread is active is skipped (exit 6) and records why" "exit $RC: $(head -c 300 "$SCRATCH/busy.out")" \
    bash -c '[ "$1" = 6 ] && grep -q "skipped-project-busy" "$2"' _ "$RC" "$SCRATCH/busy.out"
wbp "$SCRATCH/abandon.out" abandon
printf 'Bump the next countries, and merge them.\n' >>"$TASK/task.md"
BEFORE=$(threads)
wbp "$SCRATCH/stale.out" task run bump
check "after the task file is edited the run is refused (exit 6) and starts nothing" "exit $RC: $(head -c 300 "$SCRATCH/stale.out")" \
    bash -c '[ "$1" = 6 ] && grep -q "stale-approval" "$2" && [ "$3" = "$4" ]' _ "$RC" "$SCRATCH/stale.out" "$(threads)" "$BEFORE"
wbp "$SCRATCH/tick.out" task tick
check "task tick finds nothing due (the task has no schedule)" "exit $RC: $(head -c 200 "$SCRATCH/tick.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "no task is due" "$2"' _ "$RC" "$SCRATCH/tick.out"

finish
