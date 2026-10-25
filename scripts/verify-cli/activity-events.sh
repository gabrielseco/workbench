#!/bin/bash
# verify-cli scenario for normalized activity events (P9 PR 10), on a clone of this repository. No agent is started
# (nothing runs), so it costs nothing.
#   bash scripts/verify-cli/activity-events.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/activity-events.sh   (the same, on a branch that contains origin/main)
# No agent is started, so the scenario writes what the recorder would: a thread's log gets a Claude turn (a tool call as
# `agent.activity`) and an open turn of provider `codex` with `agent.activity` events (text, two tool calls, an event nobody
# understood), as the log writer lays them out. Then `log` must print both turns through their lines, `log --json` must carry the stored events unchanged, and `status --json` must count the codex
# turn's two tool calls and say its denied calls are null (a provider that reported none has not said there were none).
# Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start.
# VERIFY_CLI_SABOTAGE=1 leaves the `agent.activity` events out of the codex turn, so the steps that expect its lines, its
# stored events and its two counted tool calls must FAIL. The frame and the other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the codex turn has no agent.activity events"

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

cat >"$SCRATCH/goal.md" <<'GOAL'
---
id: verify-cli-activity
title: verify-cli activity events scenario
base: verify-cli-base
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

A throwaway thread for normalized activity events; nothing is run.

## Criteria

- [c1] Nothing runs.
  - proof: the log

## Out of scope

- Everything else.
GOAL
wbp "$SCRATCH/new.out" goal new verify-cli-activity --base "$BASE" --from "$SCRATCH/goal.md"
ID=$(sed -n 's/^created //p' "$SCRATCH/new.out")
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id ($(head -3 "$SCRATCH/new.out"))"
LOG="$P/.workbench/threads/$ID/events.jsonl"

# Append events after the last seq, one JSON line each, the way the writer does.
python3 -I - "$LOG" "$SABOTAGE" <<'PY' || die "could not seed the log"
import json, sys
path, sabotage = sys.argv[1], sys.argv[2] == "1"
seq = sum(1 for _ in open(path))
def add(turn, kind, data):
    global seq
    seq += 1
    with open(path, "a") as f:
        f.write(json.dumps({"v": 1, "seq": seq, "ts": "2026-10-24T10:00:%02d.000Z" % (seq % 60), "turn": turn,
                            "kind": kind, "data": data}) + "\n")
add(1, "turn.started", {"provider": "claude", "session_id": "s1", "resume": False, "pid": 1})
add(1, "agent.activity", {"provider": "claude", "type": "tool", "name": "Bash", "summary": "ls"})
add(1, "turn.ended", {"result": "succeeded", "exit_code": 0})
add(2, "turn.started", {"provider": "codex", "session_id": "c1", "resume": False, "pid": 2})
if not sabotage:
    act = lambda t, **k: dict(provider="codex", type=t, **k)
    add(2, "agent.activity", act("text", text="hello from codex"))
    add(2, "agent.activity", act("tool", name="shell", summary="git status"))
    add(2, "agent.activity", act("tool", name="shell", summary="ls"))
    add(2, "agent.activity", dict(provider="codex", type="unknown", raw="{\"weird\":1}"))
PY

wbp "$SCRATCH/log.out" log "$ID"
shown "$SCRATCH/log.out" 14
check "the Claude turn is a line" "no 'tool: Bash ls' line" grep -q "tool: Bash ls" "$SCRATCH/log.out"
check "the codex turn's text is a line" "no 'codex: hello from codex' line" grep -q "codex: hello from codex" "$SCRATCH/log.out"
check "its tool calls are lines" "no 'tool: shell git status' line" grep -q "tool: shell git status" "$SCRATCH/log.out"
check "an event nobody understood names its provider" "no 'codex event not understood' line" \
    grep -q "codex event not understood" "$SCRATCH/log.out"

wbp "$SCRATCH/logjson.out" log "$ID" --json
stored=$(py "print(sum(1 for x in lines if x.get('kind')=='agent.activity' and x['data'].get('provider')=='codex'))" \
    <"$SCRATCH/logjson.out")
check "log --json carries the stored agent.activity events" "found '${stored:-?}' agent.activity events, not 4" test "$stored" = 4

wbp "$SCRATCH/status.out" status "$ID" --json
tools=$(py "print(d['progress']['tool_calls'])" <"$SCRATCH/status.out")
denied=$(py "print(d['progress']['denied_calls'])" <"$SCRATCH/status.out")
check "status counts the codex turn's two tool calls" "tool_calls is '${tools:-?}'" test "$tools" = 2
check "its denied calls are unknown, not 0" "denied_calls is '${denied:-?}'" test "$denied" = None
finish
