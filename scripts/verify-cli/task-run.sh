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
# the task file is edited it must exit 6 as stale-approval and start nothing; `task tick` must find nothing due, and once the
# pending script is deleted it must say out loud that the task cannot be loaded and exit 1. Exit 0 only
# when every step passed, 1 when one failed, 2 when it refused to start (nothing changed).
# VERIFY_CLI_SABOTAGE=1 makes the stand-in gh say every pull request it opened was closed unmerged, so the units come back:
# "the second run takes only the last country", "the third run finds nothing pending", "the third run started no thread" and
# "the log holds one approval and three run ends" must FAIL, and so must "task log --all lists every run in one line" (the
# sabotaged runs differ) and "task log tells the run from its thread" (the sabotage hides the first thread's log for that call). `task log` must show the pull request, the check and the agent's last message of a run,
# `task log --all` one line per run, `task list` the reason under a run that stopped, and an unknown task must be exit 7.
# With two of its pull requests open and `max_open: 2` the task must wait for review (exit 6, skipped-too-many-open, both addresses in the
# reason): under the sabotage the pull requests read as closed, so "the task waits for review at max_open" must FAIL too. A task whose
# setup fails before any turn must be failed (exit 1) with its thread discarded, and the next run must fail the same way and not be
# skipped for a dead thread: the sabotage leaves a thread active, so "the next run is not skipped for a dead thread" must FAIL.
# A `fix: report` task must not be skipped for an active thread (the sabotage makes it a pr task, so "a dry run is not skipped for an
# active thread" must FAIL), and a task with `base: origin/main` must cut its thread from the freshly fetched tip of origin's main, which
# moved after the clone (the sabotage points origin nowhere, so "a base on origin starts the thread from the freshly fetched origin
# branch" must FAIL).
# `task run` prints what the run is doing as it goes (the turn starting, a tool call at most every 2 s, the check). Not named in the sabotage.
# The frame is in lib.sh. Run by hand, not by CI.
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
    if [ -z "\$head" ]; then
        # No --head: the question about every open pull request (the task counts its own against max_open).
        if [ "$STATE" = OPEN ]; then
            printf '['; sed 's/.*/{"headRefName":"&"}/' "$GHDIR/heads" 2>/dev/null | paste -sd, -; printf ']\n'
        else echo '[]'; fi
    elif grep -qx "\$head" "$GHDIR/heads" 2>/dev/null; then echo '[{"state":"$STATE"}]'; else echo '[]'; fi
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
printf -- '---\nbatch: 2\nfix: pr\nmax_open: 5\ninputs: countries.txt\npending: .workbench/tasks/bump/pending.sh\n---\nBump the next countries.\n' >"$TASK/task.md"

# --- 1. approve and run ------------------------------------------------------------------------------------

wbp "$SCRATCH/approve.out" task approve bump
check "approve records the task" "exit $RC: $(head -c 200 "$SCRATCH/approve.out")" test "$RC" = 0

wbp "$SCRATCH/run1.out" task run bump; shown "$SCRATCH/run1.out"
check "the first run opens a pull request for the first two countries" "exit $RC: $(head -c 400 "$SCRATCH/run1.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "^bump: pr-opened" "$2" && grep -q "units:  ROU, TUR" "$2" && grep -q "pull request: https://github.com/o/r/pull/1" "$2"' _ "$RC" "$SCRATCH/run1.out"
check "the run says what it is doing while it goes (the turn starting, the check)" "got: $(head -c 400 "$SCRATCH/run1.out")" \
    bash -c 'grep -q "^  turn 1 started" "$1" && grep -q "^  check started" "$1"' _ "$SCRATCH/run1.out"
THREAD=$(sed -n 's/^  thread: //p' "$SCRATCH/run1.out" | head -1)
check "the thread was accepted by the task and its branch is on origin" "thread '$THREAD'" \
    bash -c 'grep -q "\"by\":\"task:bump\"" "$1/.workbench/threads/$2/events.jsonl" && git -C "$3" rev-parse -q --verify "refs/heads/workbench/$2" >/dev/null' _ "$P" "$THREAD" "$ORIGIN"
check "exactly one pull request was opened" "gh calls: $(grep -c 'pr create' "$GHDIR/calls")" test "$(grep -c 'pr create' "$GHDIR/calls")" = 1

# Sabotage hides the thread's log for this one call only, so nothing after it is affected.
EVENTS="$P/.workbench/threads/$THREAD/events.jsonl"
[ "$SABOTAGE" = 1 ] && mv "$EVENTS" "$EVENTS.hidden"
wbp "$SCRATCH/log1.out" task log bump; shown "$SCRATCH/log1.out" 12
[ "$SABOTAGE" = 1 ] && mv "$EVENTS.hidden" "$EVENTS"
check "task log tells the run from its thread: the pull request, the check and the agent's last message" "exit $RC: $(head -c 500 "$SCRATCH/log1.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "^outcome:  pr-opened" "$2" && grep -q "^pull request: https://github.com/o/r/pull/1" "$2" && grep -q "^check:    passed" "$2" && grep -q "^agent:    fake claude:" "$2"' _ "$RC" "$SCRATCH/log1.out"

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

wbp "$SCRATCH/logall.out" task log bump --all; shown "$SCRATCH/logall.out" 6
check "task log --all lists every run in one line" "got: $(cat "$SCRATCH/logall.out" | head -c 400)" \
    bash -c '[ "$(grep -c "" "$1")" = 3 ] && sed -n 3p "$1" | grep -q "nothing-pending"' _ "$SCRATCH/logall.out"

# --- 2b. waiting for review ---------------------------------------------------------------------------------

sed -i.bak 's/^max_open: 5$/max_open: 2/' "$TASK/task.md" && rm -f "$TASK/task.md.bak"
wbp "$SCRATCH/approve2.out" task approve bump
wbp "$SCRATCH/waits.out" task run bump; shown "$SCRATCH/waits.out" 5
check "the task waits for review at max_open (exit 6, both pull requests named)" "exit $RC: $(head -c 400 "$SCRATCH/waits.out")" \
    bash -c '[ "$1" = 6 ] && grep -q "^bump: skipped-too-many-open" "$2" && grep -q "2 of the task.s pull requests are still open (max_open 2)" "$2" && grep -q "pull/1" "$2" && grep -q "pull/2" "$2"' _ "$RC" "$SCRATCH/waits.out"
sed -i.bak 's/^max_open: 2$/max_open: 5/' "$TASK/task.md" && rm -f "$TASK/task.md.bak"
wbp "$SCRATCH/approve3.out" task approve bump

# --- 2c. a setup that fails before any turn -------------------------------------------------------------------

mkdir -p "$P/.workbench/tasks/setup"
printf -- '---\nfix: pr\nmax_open: 5\n---\nDo the thing.\n' >"$P/.workbench/tasks/setup/task.md"
{ printf 'setup_command = "false"\n'; cat "$P/.workbench/config.toml"; } >"$SCRATCH/config.new" && cp "$SCRATCH/config.new" "$P/.workbench/config.toml"
wbp "$SCRATCH/approve4.out" task approve setup
wbp "$SCRATCH/setup1.out" task run setup; shown "$SCRATCH/setup1.out" 4
check "a failed setup is a failed run with its thread discarded" "exit $RC: $(head -c 400 "$SCRATCH/setup1.out")" \
    bash -c '[ "$1" = 1 ] && grep -q "^setup: failed" "$2" && grep -q "the thread was discarded" "$2"' _ "$RC" "$SCRATCH/setup1.out"
if [ "$SABOTAGE" = 1 ]; then wbp "$SCRATCH/blocker2.out" goal new blocker2; fi
wbp "$SCRATCH/setup2.out" task run setup
check "the next run is not skipped for a dead thread" "exit $RC: $(head -c 300 "$SCRATCH/setup2.out")" \
    bash -c '[ "$1" = 1 ] && grep -q "^setup: failed" "$2" && ! grep -q "skipped-project-busy" "$2"' _ "$RC" "$SCRATCH/setup2.out"
if [ "$SABOTAGE" = 1 ]; then wbp "$SCRATCH/abandon2.out" abandon; fi
sed -i.bak '1d' "$P/.workbench/config.toml" && rm -f "$P/.workbench/config.toml.bak"
rm -rf "$P/.workbench/tasks/setup"

# --- 2d. a base on origin ------------------------------------------------------------------------------------

g clone -q "$ORIGIN" "$SCRATCH/other" || die "git clone (the other person) failed"
( cd "$SCRATCH/other" && echo ahead >ahead.txt && g add ahead.txt \
    && g -c user.email=v@example.invalid -c user.name=verify commit -q -m "ahead" && g push -q origin HEAD:main ) || die "could not move origin ahead"
NEWTIP=$(g -C "$ORIGIN" rev-parse refs/heads/main)
mkdir -p "$P/.workbench/tasks/based"
printf -- '---\nfix: pr\nbase: origin/main\nmax_open: 5\n---\nDo the thing.\n' >"$P/.workbench/tasks/based/task.md"
# The sabotage points origin nowhere, so the fetch fails.
[ "$SABOTAGE" = 1 ] && g -C "$P" remote set-url origin "$SCRATCH/nowhere.git"
wbp "$SCRATCH/approve5.out" task approve based
wbp "$SCRATCH/based.out" task run based; shown "$SCRATCH/based.out" 4
BTHREAD=$(sed -n 's/^  thread: //p' "$SCRATCH/based.out" | head -1)
check "a base on origin starts the thread from the freshly fetched origin branch" "exit $RC, thread '$BTHREAD': $(head -c 300 "$SCRATCH/based.out")" \
    bash -c '[ -n "$3" ] && grep -q "\"base_commit\":\"$1\"" "$2/.workbench/threads/$3/events.jsonl"' _ "$NEWTIP" "$P" "$BTHREAD"
[ "$SABOTAGE" = 1 ] && g -C "$P" remote set-url origin "$ORIGIN"

# --- 3. what stops a run -----------------------------------------------------------------------------------

wbp "$SCRATCH/blocker.out" goal new blocker
wbp "$SCRATCH/busy.out" task run bump
check "a run while a thread is active is skipped (exit 6) and records why" "exit $RC: $(head -c 300 "$SCRATCH/busy.out")" \
    bash -c '[ "$1" = 6 ] && grep -q "skipped-project-busy" "$2"' _ "$RC" "$SCRATCH/busy.out"
# A dry run (`task run --dry`, no agent) starts no thread, so the active one does not stop it. (The sabotage makes the dry task a pr task, which the thread does stop.)
mkdir -p "$P/.workbench/tasks/dry"
FIX=report; [ "$SABOTAGE" = 1 ] && FIX=pr
printf -- '---\nfix: %s\nmax_open: 5\n---\nList what you would do.\n' "$FIX" >"$P/.workbench/tasks/dry/task.md"
wbp "$SCRATCH/approve-dry.out" task approve dry
wbp "$SCRATCH/dry.out" task run dry --dry; shown "$SCRATCH/dry.out" 3
check "a dry run is not skipped for an active thread" "exit $RC: $(head -c 300 "$SCRATCH/dry.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "^dry: reported" "$2"' _ "$RC" "$SCRATCH/dry.out"
wbp "$SCRATCH/abandon.out" abandon
printf 'Bump the next countries, and merge them.\n' >>"$TASK/task.md"
BEFORE=$(threads)
wbp "$SCRATCH/stale.out" task run bump
check "after the task file is edited the run is refused (exit 6) and starts nothing" "exit $RC: $(head -c 300 "$SCRATCH/stale.out")" \
    bash -c '[ "$1" = 6 ] && grep -q "stale-approval" "$2" && [ "$3" = "$4" ]' _ "$RC" "$SCRATCH/stale.out" "$(threads)" "$BEFORE"
wbp "$SCRATCH/liststale.out" task list
check "task list says why the last run stopped" "got: $(cat "$SCRATCH/liststale.out" | head -c 400)" \
    bash -c 'grep -q "^    why: the task changed since it was approved" "$1"' _ "$SCRATCH/liststale.out"
wbp "$SCRATCH/lognone.out" task log nope
check "task log of an unknown task is exit 7" "exit $RC" test "$RC" = 7
wbp "$SCRATCH/tick.out" task tick
check "task tick finds nothing due (the task has no schedule)" "exit $RC: $(head -c 200 "$SCRATCH/tick.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "no task is due" "$2"' _ "$RC" "$SCRATCH/tick.out"

rm "$TASK/pending.sh"
wbp "$SCRATCH/broken.out" task tick; TICK_RC=$RC
wbp "$SCRATCH/listbroken.out" task list
check "task list shows the last run's reason even for a task that cannot be loaded now" "got: $(head -c 400 "$SCRATCH/listbroken.out")" \
    bash -c 'grep -q "^bump  PROBLEM" "$1" && grep -q "^    why: the task changed since it was approved" "$1"' _ "$SCRATCH/listbroken.out"
check "task tick says out loud that an approved task can no longer be loaded (exit 1)" "exit $TICK_RC: $(head -c 300 "$SCRATCH/broken.out")" \
    bash -c '[ "$1" = 1 ] && grep -q "^bump: PROBLEM" "$2"' _ "$TICK_RC" "$SCRATCH/broken.out"

finish
