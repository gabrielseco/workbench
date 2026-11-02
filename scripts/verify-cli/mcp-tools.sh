#!/bin/bash
# verify-cli scenario for a task's `mcp_tools` and the project's `[mcp_servers.*]` tables, on a clone of this repository in the temp
# folder. No turn is run, so it costs nothing (the argv a real turn gets is checked by the unit tests and the fake claude).
#   bash scripts/verify-cli/mcp-tools.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/mcp-tools.sh   (the same, on a branch that contains origin/main)
# A `fix: pr` task that lists tools whose server has a `[mcp_servers.<name>]` table must list as not approved with the tools it may
# call, `task approve` must repeat that each tool is unattended write access and that the run is without --safe-mode, and
# `workbench config` must show the server and the task's tools. A task naming a server with no table, a wildcard, or `fix: report`
# must be a PROBLEM in `task list` and refused by `task approve` (exit 6). Editing the tool list after approval must say STALE.
# A config with a bad `[mcp_servers.*]` table must be refused. Exit 0 only when every step passed, 1 when one failed, 2 when it
# refused to start (nothing changed). VERIFY_CLI_SABOTAGE=1 leaves the server table out of the config, so "list shows the tools",
# "approve warns", "config shows the server" and "editing the tools says STALE" must FAIL. The frame is in lib.sh. Run by hand, not by CI.
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
[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the [mcp_servers.linear] table is left out of the config"

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
task() { mkdir -p "$TASKS/$1"; printf -- '---\n%b\n---\nDo the thing.\n' "$2" >"$TASKS/$1/task.md"; }

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
CONFIG="$P/.workbench/config.toml"
if [ "$SABOTAGE" != 1 ]; then
    printf '\n[mcp_servers.linear]\ntype = "http"\nurl = "https://mcp.linear.app/mcp"\n' >>"$CONFIG"
fi

task tracker 'at: 21:00\nfix: pr\nmcp_tools: mcp__linear__get_issue, mcp__linear__save_issue'
task noserver 'fix: pr\nmcp_tools: mcp__jira__get_issue'
task wild 'fix: pr\nmcp_tools: mcp__linear__*'
task reporter 'fix: report\nmcp_tools: mcp__linear__get_issue'

# --- 1. list -------------------------------------------------------------------------------------------------

wbp "$SCRATCH/list.out" task list; shown "$SCRATCH/list.out" 12
check "list: a task whose server has a table shows the tools it may call" "got: $(grep -A1 '^tracker' "$SCRATCH/list.out")" \
    bash -c 'grep -q "^    mcp: may call mcp__linear__get_issue, mcp__linear__save_issue" "$1"' _ "$SCRATCH/list.out"
check "list: a server with no table is a PROBLEM naming it" "got: $(grep '^noserver' "$SCRATCH/list.out")" \
    bash -c 'grep -E "^noserver +PROBLEM.*server .jira. with no \[mcp_servers" "$1" >/dev/null' _ "$SCRATCH/list.out"
check "list: a wildcard is a PROBLEM naming the line and the key" "got: $(grep '^wild' "$SCRATCH/list.out")" \
    bash -c 'grep -E "^wild +PROBLEM.*line 3: .mcp_tools. has .mcp__linear__\*." "$1" >/dev/null' _ "$SCRATCH/list.out"
check "list: fix: report with mcp_tools is a PROBLEM" "got: $(grep '^reporter' "$SCRATCH/list.out")" \
    bash -c 'grep -E "^reporter +PROBLEM.*needs .fix: pr." "$1" >/dev/null' _ "$SCRATCH/list.out"

# --- 2. approve ----------------------------------------------------------------------------------------------

wbp "$SCRATCH/approve.out" task approve tracker; shown "$SCRATCH/approve.out"
check "approve warns that every run may call the tools unattended and without --safe-mode" "exit $RC: $(head -c 300 "$SCRATCH/approve.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "mcp_tools: every run may call mcp__linear__get_issue" "$2" && grep -q "without --safe-mode" "$2"' _ "$RC" "$SCRATCH/approve.out"
for t in noserver wild reporter; do
    wbp "$SCRATCH/refuse-$t.out" task approve "$t"
    check "approve refuses $t (exit 6)" "exit $RC: $(head -c 200 "$SCRATCH/refuse-$t.out")" test "$RC" = 6
done

# --- 3. config -----------------------------------------------------------------------------------------------

wbp "$SCRATCH/config.out" config; shown "$SCRATCH/config.out" 14
check "config shows the server and the task's tools" "got: $(grep '^mcp' "$SCRATCH/config.out")" \
    bash -c 'grep -q "^mcp: .*linear (http https://mcp.linear.app/mcp)" "$1" && grep -q "^mcp tools: task tracker may call mcp__linear__get_issue" "$1"' _ "$SCRATCH/config.out"
check "config's own command line keeps --safe-mode (a goal run is unchanged)" "$(grep '^command' "$SCRATCH/config.out" | head -c 200)" \
    bash -c 'grep "^command" "$1" | grep -q -- "--safe-mode" && ! grep "^command" "$1" | grep -q -- "--mcp-config"' _ "$SCRATCH/config.out"

# --- 4. editing the list revokes the approval ------------------------------------------------------------------

task tracker 'at: 21:00\nfix: pr\nmcp_tools: mcp__linear__get_issue'
wbp "$SCRATCH/stale.out" task list
check "editing the tools says STALE" "got: $(grep '^tracker' "$SCRATCH/stale.out")" \
    bash -c 'grep -E "^tracker .*STALE" "$1" >/dev/null' _ "$SCRATCH/stale.out"

# --- 5. a bad server table -------------------------------------------------------------------------------------

printf '\n[mcp_servers.bad]\ntype = "http"\nurl = "http://insecure.example/mcp"\n' >>"$CONFIG"
wbp "$SCRATCH/bad.out" config
check "a plain-http server table is refused with its table named" "exit $RC: $(head -c 300 "$SCRATCH/bad.out")" \
    bash -c '[ "$1" != 0 ] && grep -q "mcp_servers.bad" "$2"' _ "$RC" "$SCRATCH/bad.out"

finish
