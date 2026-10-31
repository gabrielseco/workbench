#!/bin/bash
# verify-cli scenario for the hold a Claude session handed to Herdr keeps on its thread, on a clone of this repository. The clone's
# claude_path is /usr/bin/false, so no real agent is started and it costs nothing.
#   bash scripts/verify-cli/herdr-session-hold.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/herdr-session-hold.sh   (the same, on a branch that contains origin/main)
# A thread with an approved timeout_only goal gets the `runner.json` the session's supervisor writes (a live process, `"session":
# "herdr"`, its start second). `workbench run` must then refuse and name the session, start no turn, leave the marker as it was, and
# `status --json` must say the thread is running; once the process is gone and the marker with it, `run` starts a turn again.
# Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start. VERIFY_CLI_SABOTAGE=1 writes no marker, so the
# steps that expect the refusal and the running status must FAIL. The frame and the other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: no marker is written for the session"

P="$SCRATCH/project"
g clone -q "$ROOT" "$P" || die "git clone failed"
BASE=verify-cli-base
git -C "$P" checkout -q -b "$BASE" || die "could not make the base branch in the clone"
echo "==> clone at $P, base $BASE"

RC=0
wbp() { # <out> args...: a workbench command in the clone, stdout and stderr together; sets RC
    local o=$1; shift
    echo "workbench $*   (in the clone)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    ( cd "$P" && with_timeout "$T_WB" "$WB" "$@" >"$o" 2>&1 )
    RC=$?
}
shown() { sed 's/^/    /' "$1" | head -${2:-12}; }

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
cfg="$P/.workbench/config.toml"
grep -v -e '^claude_path = ' "$cfg" >"$SCRATCH/config.rest"
{ echo 'claude_path = "/usr/bin/false"'; cat "$SCRATCH/config.rest"; } >"$cfg"

cat >"$SCRATCH/goal.md" <<GOAL
---
id: verify-cli-source
title: source for the Herdr session hold scenario
base: verify-cli-base
spend_policy: timeout_only
turn_timeout_min: 10
---

## Request

A throwaway thread; nothing real is run.

## Criteria

- [c1] Nothing runs.
  - proof: the log

## Out of scope

- Everything else.
GOAL
wbp "$SCRATCH/new.out" goal new verify-cli-hold --base "$BASE" --from "$SCRATCH/goal.md"
ID=$(sed -n 's/^created //p' "$SCRATCH/new.out")
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id ($(head -3 "$SCRATCH/new.out"))"
wbp "$SCRATCH/approve.out" goal approve "$ID"
check "the goal is approved" "goal approve exited $RC" test "$RC" = 0

# The session's supervisor: any live process will do, with the marker it would write.
LOG="$P/.workbench/threads/$ID/events.jsonl"
MARKER="$P/.workbench/threads/$ID/runner.json"
sleep 600 &
SESSION=$!
trap 'kill "$SESSION" 2>/dev/null' EXIT
if [ "$SABOTAGE" != 1 ]; then
    printf '{"pid":%s,"session":"herdr","started_seconds":%s}' "$SESSION" "$(date +%s)" >"$MARKER"
fi
BEFORE=$(cat "$MARKER" 2>/dev/null)

wbp "$SCRATCH/run1.out" run "$ID"
shown "$SCRATCH/run1.out" 4
check "run refuses beside the session and names it" "run exited $RC, or did not mention a Claude session handed to Herdr" \
    bash -c '[ "$1" != 0 ] && grep -q "Claude session handed to Herdr" "$2"' _ "$RC" "$SCRATCH/run1.out"
check "no turn was started and the marker is as it was" "a turn.started is in the log, or the marker changed" \
    bash -c '! grep -q "\"turn.started\"" "$1" && [ "$(cat "$2" 2>/dev/null)" = "$3" ]' _ "$LOG" "$MARKER" "$BEFORE"
wbp "$SCRATCH/status.json" status "$ID" --json
check "status says the thread is running" "status --json does not report a runner" \
    py "assert d.get('running') is True or d.get('runner_alive') is True, [k for k in d]" <"$SCRATCH/status.json"

kill "$SESSION" 2>/dev/null
wait "$SESSION" 2>/dev/null
rm -f "$MARKER"
wbp "$SCRATCH/run2.out" run "$ID"
shown "$SCRATCH/run2.out" 4
check "once the session is gone a run starts a turn again" "no turn.started after the session ended" \
    grep -q "\"turn.started\"" "$LOG"
finish
