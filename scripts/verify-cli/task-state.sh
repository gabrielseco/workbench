#!/bin/bash
# verify-cli scenario for turning a scheduled task off and putting it away (`task disable|enable|archive|restore`, `task list --archived`),
# on a clone of this repository in the temp folder, so nothing real is contacted. The task is `fix: report` with a pending script that lists
# nothing, so a run ends `nothing-pending` before any agent: no turn runs and it costs nothing.
#   bash scripts/verify-cli/task-state.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/task-state.sh   (the same, on a branch that contains origin/main)
# The task is approved and its log's times are moved back a year, so it is due. Disabled, `task list` must say DISABLED and a `task tick`
# must run nothing (no task.run.started in its log), also from a new process; `task run --dry` by hand must still run it. Enabled again
# (and moved back again, since enabling counts the schedule from now) the tick must run it. Archived, `task list` must leave it out and
# say how many are archived, `task list --archived` must list it, its task.md and run log must be unchanged, a tick must run nothing and
# `task run` must be skipped (exit 6, skipped-disabled). Restored, it must say it is enabled and be listed again. An unknown task is not found
# (exit 7). Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start (nothing changed).
# VERIFY_CLI_SABOTAGE=1 skips the disable and the archive commands, so "list says DISABLED", "a tick does not run a disabled task",
# "archive takes it off the list", "list --archived lists it", "a tick does not run an archived task" and "run refuses an archived task"
# must FAIL. The frame is in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

ORIGIN="$SCRATCH/origin.git"
P="$SCRATCH/project"
g clone -q --bare "$ROOT" "$ORIGIN" || die "git clone --bare failed"
g -C "$ORIGIN" update-ref refs/heads/main "$BASE_SHA" || die "could not set main in the bare copy"
g -C "$ORIGIN" symbolic-ref HEAD refs/heads/main || die "could not point the bare copy's HEAD at main"
g clone -q "$ORIGIN" "$P" || die "git clone failed"
g -C "$P" checkout -q -B main origin/main || die "could not check out main in the clone"
echo "==> clone at $P"
[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the disable and archive commands are skipped"

RC=0
wbp() { # <out> args...: a workbench command in the clone, stdout and stderr together; sets RC
    local o=$1; shift
    echo "workbench $*   (in the clone)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    ( cd "$P" && with_timeout "$T_WB" "$WB" "$@" >"$o" 2>&1 )
    RC=$?
}
shown() { sed 's/^/    /' "$1" | head -${2:-8}; }
TASK="$P/.workbench/tasks/nightly"
LOG="$TASK/runs.jsonl"
mkdir -p "$TASK"
printf -- '---\nevery: 5m\nfix: report\npending: .workbench/tasks/nightly/pending.sh\n---\nSay what changed.\n' >"$TASK/task.md"
printf '#!/bin/sh\necho "[]"\n' >"$TASK/pending.sh"; chmod +x "$TASK/pending.sh"
# Every event a year back, in order: the schedule then counts from long ago, so the task is due now.
backdate() { sed -E 's/"ts":"[^"]*"/"ts":"2025-01-01T00:00:00.000Z"/' "$LOG" >"$LOG.new" && mv "$LOG.new" "$LOG"; }
starts() { grep -c '"kind":"task.run.started"' "$LOG" 2>/dev/null; }

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
wbp "$SCRATCH/approve.out" task approve nightly
check "the task is approved" "exit $RC: $(head -c 200 "$SCRATCH/approve.out")" test "$RC" = 0
backdate

# --- 1. disabled --------------------------------------------------------------------------------------------

if [ "$SABOTAGE" = 1 ]; then : >"$SCRATCH/disable.out"; RC=0; else wbp "$SCRATCH/disable.out" task disable nightly; fi
shown "$SCRATCH/disable.out"
wbp "$SCRATCH/list1.out" task list; shown "$SCRATCH/list1.out"
check "list says DISABLED and gives no next time" "got: $(grep '^nightly' "$SCRATCH/list1.out")" \
    bash -c 'grep -E "^nightly +DISABLED +every 5m .*next: - " "$1" >/dev/null' _ "$SCRATCH/list1.out"
before=$(starts)
wbp "$SCRATCH/tick1.out" task tick; shown "$SCRATCH/tick1.out"
check "a tick does not run a disabled task (a new process reads the state from its log)" "exit $RC, starts $before -> $(starts): $(head -c 200 "$SCRATCH/tick1.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "no task is due" "$2" && [ "$3" = "$4" ]' _ "$RC" "$SCRATCH/tick1.out" "$before" "$(starts)"
wbp "$SCRATCH/dry.out" task run nightly --dry
check "a disabled task still runs by hand" "exit $RC: $(head -c 200 "$SCRATCH/dry.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "^nightly: nothing-pending" "$2"' _ "$RC" "$SCRATCH/dry.out"

# --- 2. enabled again ---------------------------------------------------------------------------------------

wbp "$SCRATCH/enable.out" task enable nightly; shown "$SCRATCH/enable.out"
check "enable says the schedule is on, counted from now" "exit $RC: $(head -c 200 "$SCRATCH/enable.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "^nightly: enabled: it runs on its schedule again, counted from now" "$2"' _ "$RC" "$SCRATCH/enable.out"
backdate
wbp "$SCRATCH/tick2.out" task tick; shown "$SCRATCH/tick2.out"
check "the tick runs it again once enabled" "exit $RC: $(head -c 200 "$SCRATCH/tick2.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "^nightly: nothing-pending" "$2"' _ "$RC" "$SCRATCH/tick2.out"

# --- 3. archived --------------------------------------------------------------------------------------------

backdate
TASK_SUM=$(cksum <"$TASK/task.md")
RUNS=$(starts)
if [ "$SABOTAGE" = 1 ]; then : >"$SCRATCH/archive.out"; RC=0; else wbp "$SCRATCH/archive.out" task archive nightly; fi
shown "$SCRATCH/archive.out"
wbp "$SCRATCH/list2.out" task list; shown "$SCRATCH/list2.out"
check "archive takes it off the list and says how many are archived" "got: $(head -c 300 "$SCRATCH/list2.out")" \
    bash -c '! grep -q "^nightly" "$1" && grep -q "^1 archived: workbench task list --archived" "$1"' _ "$SCRATCH/list2.out"
wbp "$SCRATCH/list3.out" task list --archived; shown "$SCRATCH/list3.out"
check "list --archived lists it" "got: $(head -c 300 "$SCRATCH/list3.out")" \
    bash -c 'grep -E "^nightly +archived +every 5m" "$1" >/dev/null' _ "$SCRATCH/list3.out"
check "archiving keeps task.md and every run" "task.md $(cksum <"$TASK/task.md") vs $TASK_SUM, starts $(starts) vs $RUNS" \
    bash -c '[ "$(cksum <"$1")" = "$2" ] && [ "$3" = "$4" ]' _ "$TASK/task.md" "$TASK_SUM" "$(starts)" "$RUNS"
wbp "$SCRATCH/tick3.out" task tick; shown "$SCRATCH/tick3.out"
check "a tick does not run an archived task" "exit $RC, starts $RUNS -> $(starts): $(head -c 200 "$SCRATCH/tick3.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "no task is due" "$2" && [ "$3" = "$4" ]' _ "$RC" "$SCRATCH/tick3.out" "$RUNS" "$(starts)"
wbp "$SCRATCH/run.out" task run nightly; shown "$SCRATCH/run.out"
check "run refuses an archived task (exit 6) and records nothing" "exit $RC: $(head -c 200 "$SCRATCH/run.out")" \
    bash -c '[ "$1" = 6 ] && grep -q "^nightly: skipped-disabled  the task is archived" "$2" && [ "$3" = "$4" ]' _ "$RC" "$SCRATCH/run.out" "$RUNS" "$(starts)"

# --- 4. restored --------------------------------------------------------------------------------------------

wbp "$SCRATCH/restore.out" task restore nightly; shown "$SCRATCH/restore.out"
check "restore says it is back and enabled" "exit $RC: $(head -c 200 "$SCRATCH/restore.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "^nightly: restored to the task list, enabled" "$2"' _ "$RC" "$SCRATCH/restore.out"
wbp "$SCRATCH/list4.out" task list
check "a restored task is listed again" "got: $(grep '^nightly' "$SCRATCH/list4.out")" \
    bash -c 'grep -E "^nightly +every 5m +fix: report +approved" "$1" >/dev/null' _ "$SCRATCH/list4.out"
wbp "$SCRATCH/none.out" task disable nope
check "an unknown task is not found (exit 7)" "exit $RC: $(head -c 200 "$SCRATCH/none.out")" test "$RC" = 7

finish
