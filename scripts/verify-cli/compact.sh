#!/bin/bash
# verify-cli scenario for `workbench compact`, which brings an older log to the current shape (temporary: it goes once the logs
# are moved). On a clone of this repository.
# No turn is run, so it costs nothing: the scenario writes the log of an ended thread the way an older Workbench did, every
# stream line a `claude` event, with a grant that names a denial by `seq` and an agent attempt.
#   bash scripts/verify-cli/compact.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/compact.sh   (the same, on a branch that contains origin/main)
# `compact --dry-run` must change nothing. `compact <id>` must exit 0, shrink events.jsonl and leave gzipped transcript
# files (no plain ones, `gzip -t` passes). Then `log --transcript`, `status --json`, `review --json` and `grant --json`
# must say what they said before, bar the `seq` numbers a rewrite renumbers (and, in `review`, the denied call's whole input,
# which the end record now holds); the log must have no `seq` gap, the grant must
# still point at the denial (now the turn's end record, which holds the refused calls) and the attempt's id must be `a<seq of its start>`. A second `compact` must find
# nothing to move and leave the log's bytes alone; a thread that has not ended must be refused (exit 6) and skipped by
# `--all`. Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start (nothing changed).
# VERIFY_CLI_SABOTAGE=1 removes the transcript folder after the compaction, so "the transcript files are gzipped",
# and "log --transcript says what it said" must FAIL. The frame is in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

P="$SCRATCH/project"
BASE=verify-cli-base
g clone -q "$ROOT" "$P" || die "git clone failed"
g -C "$P" checkout -q -b "$BASE" || die "could not make the base branch in the clone"
echo "==> clone at $P, base $BASE"

RC=0
wbp() { # <out> args...: a workbench command in the clone, stdout and stderr together; sets RC
    local o=$1; shift
    echo "workbench $*   (in the clone)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    ( cd "$P" && with_timeout "$T_WB" "$WB" "$@" >"$o" 2>&1 )
    RC=$?
}
shown() { sed 's/^/    /' "$1" | head -${2:-8}; }
# The thread's JSON with the numbers a renumbering changes taken out, one line, for comparing.
plain() { python3 -I -c "
import json, sys
def strip(v):
    if isinstance(v, dict): return {k: strip(x) for k, x in v.items() if k not in ('seq', 'seqs', 'denial_seq', 'progress', 'input_full')}
    if isinstance(v, list): return [strip(x) for x in v]
    return v
print(json.dumps(strip(json.load(open(sys.argv[1]))), sort_keys=True))" "$1" 2>/dev/null; }

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
cat >"$SCRATCH/goal.md" <<'GOAL'
---
title: Compact an older log
budget_usd: 1
turn_timeout_min: 30
---

## Request

Nothing runs: this thread only checks what compact does to a log written with every stream line in it.

## Criteria

- [c1] The thread reads the same after compact.
  - proof: the scenario compares the output

## Out of scope

- Any change to the code.
GOAL
wbp "$SCRATCH/new.out" goal new compact --from "$SCRATCH/goal.md" --base "$BASE"
ID=$(sed -n 's/^created //p' "$SCRATCH/new.out")
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id ($(head -3 "$SCRATCH/new.out"))"
wbp "$SCRATCH/approve.out" goal approve "$ID"
[ "$RC" = 0 ] || die "goal approve $ID failed: $(cat "$SCRATCH/approve.out")"

T="$P/.workbench/threads/$ID"
EVENTS="$T/events.jsonl"
# The turn an older Workbench logged: 59 stream lines (one is not JSON), a result with a denial, an attempt, a grant that
# names the denial's seq, and the decision that ended the thread.
python3 -I - "$EVENTS" <<'PY' || die "could not write the older log"
import json, sys
path = sys.argv[1]
seq = max(json.loads(l)["seq"] for l in open(path) if l.strip())
out = []
def add(turn, kind, data):
    global seq
    seq += 1
    out.append(json.dumps({"v": 1, "seq": seq, "ts": "2026-10-20T10:00:%02d.000Z" % (seq % 60), "turn": turn, "kind": kind, "data": data},
                          separators=(",", ":")))
    return seq
def raw(turn, text):  # a stream line stored verbatim: its data is the line itself
    global seq
    seq += 1
    out.append('{"v":1,"seq":%d,"ts":"2026-10-20T10:00:%02d.000Z","turn":%d,"kind":"claude","data":%s}' % (seq, seq % 60, turn, text))
    return seq
add(1, "turn.started", {"resume": False, "pid": 1, "argv": ["claude"], "prompt_ref": "prompts/turn-1.md", "session_id": "s"})
add(1, "agent.attempt.started", {"attempt": "a%d" % (seq + 1), "role": "run", "provider": "claude", "model": None})
attempt = "a%d" % seq
raw(1, '{"type":"system","subtype":"init","session_id":"s"}')
for n in range(55):
    raw(1, '{"type":"stream_event","n":%d,"pad":"%s"}' % (n, "p" * 300))
raw(1, '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"chmod +x a.sh"}}]}}')
raw(1, '{"type":"user","message":{"content":[{"type":"tool_result","is_error":true,"content":"Permission for this tool use was denied"}]}}')
result = raw(1, '{"type":"result","subtype":"success","total_cost_usd":0.25,"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"chmod +x a.sh"}}]}')
add(1, "agent.attempt.ended", {"attempt": attempt, "outcome": "succeeded", "role": "run", "provider": "claude"})
add(1, "turn.ended", {"result": "succeeded", "exit_code": 0, "duration_ms": 1000, "cost_usd": 0.25})
add(0, "grant.added", {"scope": "once", "pattern": "Bash(chmod +x a.sh)", "level": "safe", "by": "user", "denial_seq": result})
add(0, "review.decision", {"decision": "accepted"})
open(path, "a").write("\n".join(out) + "\n")
PY
LINES_IN_LOG=$(grep -c '"kind":"claude"' "$EVENTS")
BEFORE_SIZE=$(wc -c <"$EVENTS" | tr -d ' ')
echo "    the older log: $LINES_IN_LOG stream lines, $BEFORE_SIZE bytes"
wbp "$SCRATCH/before.transcript" log "$ID" --transcript
wbp "$SCRATCH/before.status" status "$ID" --json
wbp "$SCRATCH/before.review" review "$ID" --json
wbp "$SCRATCH/before.grant" grant --json
check "the older log loads before anything is moved" "status exited $RC" test "$RC" = 0

# --- a dry run, then the real thing -----------------------------------------------------------------------

BEFORE_SUM=$(shasum "$EVENTS" | cut -d' ' -f1)
wbp "$SCRATCH/dry.out" compact "$ID" --dry-run
shown "$SCRATCH/dry.out" 4
check "compact --dry-run says what it would do and changes nothing" "exit $RC, or the log or a transcript folder changed" \
    bash -c '[ "$1" = 0 ] && grep -q "would move" "$2" && [ "$(shasum "$3" | cut -d" " -f1)" = "$4" ] && [ ! -e "$5/transcript" ]' \
    _ "$RC" "$SCRATCH/dry.out" "$EVENTS" "$BEFORE_SUM" "$T"

wbp "$SCRATCH/compact.out" compact "$ID"
shown "$SCRATCH/compact.out" 4
check "compact exits 0 and says the lines were moved" "exit $RC: $(head -c 200 "$SCRATCH/compact.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "stream line(s) of 1 turn(s) moved" "$2"' _ "$RC" "$SCRATCH/compact.out"
AFTER_SIZE=$(wc -c <"$EVENTS" | tr -d ' ')
echo "    events.jsonl: $BEFORE_SIZE -> $AFTER_SIZE bytes"
check "events.jsonl is a fraction of what it was" "$BEFORE_SIZE -> $AFTER_SIZE bytes" test "$AFTER_SIZE" -lt "$((BEFORE_SIZE / 4))"

if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: the transcript folder is removed after the compaction"
    rm -rf "$T/transcript"
fi

GZ="$T/transcript/turn-1.jsonl.gz"
check "the transcript files are gzipped: no plain file, gzip -t passes" "plain file present, or .gz missing or not gzip" \
    bash -c '[ ! -e "$1/transcript/turn-1.jsonl" ] && [ -f "$2" ] && gzip -t "$2"' _ "$T" "$GZ"
check "the log holds no claude event" "$(grep -c '"kind":"claude"' "$EVENTS") claude events left" \
    test "$(grep -c '"kind":"claude"' "$EVENTS")" = 0
check "the old log is kept as events.jsonl.before-migrate" "no such file, or not the older log" \
    bash -c 'test "$(wc -c <"$1.before-migrate" | tr -d " ")" = "$2"' _ "$EVENTS" "$BEFORE_SIZE"
check "the turn's stream is one dropped record that counts its tool calls and refusals" "no migrated dropped record with counts" \
    py "import sys
d = [l['data'] for l in lines if l['kind'] == 'agent.activity']
sys.exit(0 if len(d) == 1 and d[0].get('reason') == 'migrated' and d[0].get('denied', 0) >= 1 and d[0].get('tool_calls', -1) >= 0 else 1)" <"$EVENTS"
check "the log has no seq gap" "seq numbers are not 1..n" \
    py "import sys; s = [l['seq'] for l in lines]; sys.exit(0 if s == list(range(1, len(s) + 1)) else 1)" <"$EVENTS"
check "the grant still points at the denial: the turn's end record, which holds the refused call" "denial_seq does not name turn.ended with the call" \
    py "import sys
g = [l for l in lines if l['kind'] == 'grant.added'][0]['data']['denial_seq']
t = lines[g - 1]
sys.exit(0 if t['kind'] == 'turn.ended' and t['data'].get('denials', [{}])[0].get('tool') == 'Bash' else 1)" <"$EVENTS"
check "the attempt's id is a<seq of its start> on both lines" "the ids do not match their start" \
    py "import sys
s = [l for l in lines if l['kind'] == 'agent.attempt.started'][0]
e = [l for l in lines if l['kind'] == 'agent.attempt.ended'][0]
sys.exit(0 if s['data']['attempt'] == 'a%d' % s['seq'] and e['data']['attempt'] == s['data']['attempt'] else 1)" <"$EVENTS"

# --- the thread says what it said ------------------------------------------------------------------------

wbp "$SCRATCH/after.transcript" log "$ID" --transcript
check "log --transcript says what it said, line for line" "the stream lines differ from before" \
    cmp -s "$SCRATCH/before.transcript" "$SCRATCH/after.transcript"
wbp "$SCRATCH/after.json" log "$ID" --json
JSON_LINES=$(py "print(sum(1 for l in lines if l['kind'] == 'claude'))" <"$SCRATCH/after.json" 2>/dev/null)
check "log --json prints no stream line as an event; they are in the transcript" "log --json has '$JSON_LINES' claude lines" \
    test "$JSON_LINES" = 0
wbp "$SCRATCH/after.status" status "$ID" --json
wbp "$SCRATCH/after.review" review "$ID" --json
wbp "$SCRATCH/after.grant" grant --json
check "status --json says the same, bar the seq numbers" "status --json differs" \
    test -n "$(plain "$SCRATCH/before.status")" -a "$(plain "$SCRATCH/before.status")" = "$(plain "$SCRATCH/after.status")"
check "review --json says the same, bar the seq numbers" "review --json differs" \
    test -n "$(plain "$SCRATCH/before.review")" -a "$(plain "$SCRATCH/before.review")" = "$(plain "$SCRATCH/after.review")"
check "review --json now carries the denied call's whole input, which the end record holds" "input_full is not the command" \
    py "import sys; sys.exit(0 if any(t.get('input_full') == 'chmod +x a.sh' for t in d['denied_tools']) else 1)" <"$SCRATCH/after.review"
check "grant --json says the same, bar the seq numbers" "grant --json differs" \
    test -n "$(plain "$SCRATCH/before.grant")" -a "$(plain "$SCRATCH/before.grant")" = "$(plain "$SCRATCH/after.grant")"

# --- again, and a thread that has not ended -------------------------------------------------------------

SUM_AFTER=$(shasum "$EVENTS" | cut -d' ' -f1)
if [ "$SABOTAGE" != 1 ]; then
    wbp "$SCRATCH/again.out" compact "$ID"
    check "a second compact finds nothing and leaves the log alone" "exit $RC: $(head -c 150 "$SCRATCH/again.out")" \
        bash -c '[ "$1" = 0 ] && grep -q "nothing to move" "$2" && [ "$(shasum "$3" | cut -d" " -f1)" = "$4" ]' \
        _ "$RC" "$SCRATCH/again.out" "$EVENTS" "$SUM_AFTER"
fi

wbp "$SCRATCH/new2.out" goal new compact-active --from "$SCRATCH/goal.md" --base "$BASE"
ID2=$(sed -n 's/^created //p' "$SCRATCH/new2.out")
[ -n "$ID2" ] || die "the second goal new made no thread: $(cat "$SCRATCH/new2.out")"
wbp "$SCRATCH/approve2.out" goal approve "$ID2"
wbp "$SCRATCH/active.out" compact "$ID2"
check "a thread that has not ended is refused with exit 6" "exit $RC: $(head -c 150 "$SCRATCH/active.out")" \
    bash -c '[ "$1" = 6 ] && grep -q "has not ended" "$2"' _ "$RC" "$SCRATCH/active.out"
wbp "$SCRATCH/all.out" compact --all
check "compact --all skips it and says so" "exit $RC: $(head -c 150 "$SCRATCH/all.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "$2: skipped, it has not ended" "$3"' _ "$RC" "$ID2" "$SCRATCH/all.out"
wbp "$SCRATCH/abandon.out" abandon "$ID2"
check "abandon ends the second thread" "workbench abandon exited $RC" test "$RC" = 0
finish
