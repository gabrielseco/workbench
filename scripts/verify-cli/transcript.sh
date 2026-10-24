#!/bin/bash
# verify-cli scenario for the claude transcript living beside the event log. On a clone of this repository with a
# `claude` stand-in that runs the fake-claude test double, slowly, so the turn is still open while it is watched. No real
# turn is run, so it costs nothing.
#   bash scripts/verify-cli/transcript.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/transcript.sh   (the same, on a branch that contains origin/main)
# While the turn runs, `threads/<id>/transcript/turn-1.jsonl` must already hold lines and the log must not yet have
# `turn.ended`, and `log -f` must print the stream lines and end with `turn ended`. When the turn has ended the file must be
# gzipped (`turn-1.jsonl.gz`, the plain file gone, `gzip -t` passes). The log must hold one `claude` event (the result line),
# `turn.ended` must carry `transcript` with the line and byte counts of what `gzip -dc` gives, and those lines must be the
# stream, verbatim. `log` must print each stream line once, `log --transcript` the stored lines as they are, `log --json`
# the transcript lines as `claude` events with `"seq":null`, and `status`, `status --json` and `review` must still load the
# thread. Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start (nothing changed).
# VERIFY_CLI_SABOTAGE=1 removes the transcript folder after the turn, so "the transcript was gzipped", "turn.ended's counts
# are the file's", "the file holds the stream lines", "every line of the file is a whole record", "log prints each stream
# line", "log --transcript prints the stored lines" and "log --json prints the transcript lines" must FAIL. The frame is in
# lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

echo "==> building fake-claude"
with_timeout "$T_BUILD" swift build --product fake-claude || die "swift build --product fake-claude failed"
FAKE="$ROOT/.build/debug/fake-claude"
[ -x "$FAKE" ] || die "no $FAKE after the build"

P="$SCRATCH/project"
BIN="$SCRATCH/bin"
BASE=verify-cli-base
g clone -q "$ROOT" "$P" || die "git clone failed"
g -C "$P" checkout -q -b "$BASE" || die "could not make the base branch in the clone"
mkdir -p "$BIN" || die "could not make $BIN"
# The stream is slow (800 ms between lines), so the turn is open while the scenario looks at it.
cat >"$BIN/claude" <<STUB
#!/bin/sh
FAKE_CLAUDE=write=transcript-probe.txt,delay-ms=800 exec '$FAKE' "\$@"
STUB
chmod +x "$BIN/claude"
echo "==> clone at $P, base $BASE, stand-in in $BIN"

RC=0
wbp() { # <out> args...: a workbench command in the clone, stdout and stderr together; sets RC
    local o=$1 secs=$T_WB; shift
    [ "$1" = run ] && secs=$T_RUN
    echo "workbench $*   (in the clone)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    ( cd "$P" && with_timeout "$secs" "$WB" "$@" >"$o" 2>&1 )
    RC=$?
}
shown() { sed 's/^/    /' "$1" | head -${2:-8}; }

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
cat >"$P/.workbench/config.toml" <<TOML
claude_path = "$BIN/claude"
default_budget_usd = 0.10

[tools]
available = ["Read", "Edit", "Write"]
allowed = ["Read", "Edit", "Write"]
TOML

cat >"$SCRATCH/goal.md" <<'GOAL'
---
title: The transcript is beside the log
budget_usd: 0.10
turn_timeout_min: 5
---

## Request

Nothing real runs: the stand-in claude streams slowly and writes one file.

## Criteria

- [c1] The transcript is a file of its own.
  - proof: the scenario reads it

## Out of scope

- Any change to the code.
GOAL
wbp "$SCRATCH/new.out" goal new transcript --from "$SCRATCH/goal.md" --base "$BASE"
ID=$(sed -n 's/^created //p' "$SCRATCH/new.out")
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id ($(head -3 "$SCRATCH/new.out"))"
wbp "$SCRATCH/approve.out" goal approve "$ID"
[ "$RC" = 0 ] || die "goal approve $ID failed: $(cat "$SCRATCH/approve.out")"

T="$P/.workbench/threads/$ID"
EVENTS="$T/events.jsonl"
FILE="$T/transcript/turn-1.jsonl"

# --- the turn is open: the file grows, the log has no end yet, `log -f` shows the lines as they come --------

echo "\$ workbench run $ID   (in the clone, in the background)" >&2
echo "workbench run $ID   (in the clone, in the background)" >>"$SCRATCH/commands"
( cd "$P" && with_timeout "$T_RUN" "$WB" run "$ID" >"$SCRATCH/run.out" 2>&1; echo $? >"$SCRATCH/run.rc" ) &
RUN_PID=$!
MID=""
for _ in $(seq 1 100); do
    if [ -s "$FILE" ] && ! grep -q '"kind":"turn.ended"' "$EVENTS" 2>/dev/null; then
        MID="$(wc -l <"$FILE" | tr -d ' ') line(s) while the log has no turn.ended"
        break
    fi
    sleep 0.2
done
check "while the turn is open its transcript file already has lines" "no line in $FILE before turn.ended" test -n "$MID"
[ -n "$MID" ] && echo "    $MID"
wbp "$SCRATCH/follow.out" log "$ID" -f
shown "$SCRATCH/follow.out" 12
check "log -f ends with the turn's end" "workbench log -f exited $RC or did not end with 'turn ended'" \
    bash -c 'test "$1" = 0 && grep -q "turn ended" "$2"' _ "$RC" "$SCRATCH/follow.out"
check "log -f printed the stream lines" "no 'session started' line" grep -q "session started" "$SCRATCH/follow.out"
wait "$RUN_PID" 2>/dev/null
check "run: the turn finished" "workbench run exited $(cat "$SCRATCH/run.rc" 2>/dev/null)" test "$(cat "$SCRATCH/run.rc" 2>/dev/null)" = 0

if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: the transcript folder is removed after the turn"
    rm -rf "$T/transcript"
fi

# --- after the turn --------------------------------------------------------------------------------------

GZ="$FILE.gz"
check "the transcript was gzipped when the turn ended: no plain file, gzip -t passes" "plain file or .gz missing, or not gzip" \
    bash -c '[ ! -e "$1" ] && [ -f "$2" ] && gzip -t "$2"' _ "$FILE" "$GZ"
FILE="$SCRATCH/transcript-turn-1.jsonl"   # from here on, the decompressed copy
[ -f "$GZ" ] && gzip -dc "$GZ" >"$FILE" 2>/dev/null

LINES=$(py "print(sum(1 for l in lines if l['kind'] == 'claude'))" <"$EVENTS" 2>/dev/null)
FILE_LINES=$( [ -f "$FILE" ] && wc -l <"$FILE" | tr -d ' ' || echo 0 )
echo "    events.jsonl: $LINES claude event(s); transcript file: $FILE_LINES line(s)"
check "the log holds one claude event: the result line" "events.jsonl has $LINES claude events" test "$LINES" = 1
check "that event is the result line" "the claude event is not type result" \
    py "c = [l for l in lines if l['kind'] == 'claude']
import sys; sys.exit(0 if len(c) == 1 and c[0]['data'].get('type') == 'result' else 1)" <"$EVENTS"
ENDED=$(py "e = [l for l in lines if l['kind'] == 'turn.ended'][0]['data'].get('transcript') or {}
print(e.get('lines'), e.get('bytes'))" <"$EVENTS" 2>/dev/null)
FILE_BYTES=$( [ -f "$FILE" ] && wc -c <"$FILE" | tr -d ' ' || echo 0 )
check "turn.ended's transcript counts are the file's" "turn.ended says '$ENDED', the file has '$FILE_LINES $FILE_BYTES'" \
    test "$ENDED" = "$FILE_LINES $FILE_BYTES"
check "the file holds the stream lines, the last one the result" "the file has $FILE_LINES line(s) or no result last" \
    bash -c 'test "$2" -ge 3 && tail -n 1 "$1" | grep -q "\"type\":\"result\""' _ "$FILE" "$FILE_LINES"
WHOLE=$(py "print(bool(lines) and all(set(r) == {'ts', 'data'} for r in lines))" 2>/dev/null <"$FILE")
check "every line of the file is a whole {ts, data} record" "the file's lines are not all whole records ('$WHOLE')" \
    test "$WHOLE" = True

wbp "$SCRATCH/log.out" log "$ID"
INIT_LINES=$(grep -c "session started" "$SCRATCH/log.out")
RESULT_LINES=$(grep -c "result" "$SCRATCH/log.out")
check "log prints each stream line once" "'session started' x$INIT_LINES, result lines x$RESULT_LINES" \
    bash -c '[ "$1" = 1 ] && [ "$2" -le 2 ]' _ "$INIT_LINES" "$RESULT_LINES"
wbp "$SCRATCH/transcript.out" log "$ID" --transcript
SAME=$(python3 -I - "$FILE" "$SCRATCH/transcript.out" 2>/dev/null <<'PY'
import sys
want = [l.rstrip("\n")[l.index('"data":') + 7:-1] for l in open(sys.argv[1])]
got = [l.rstrip("\n") for l in open(sys.argv[2])]
print(bool(got) and want == got)
PY
)
check "log --transcript prints the stored lines as they are" "its output is not the file's data, line for line ('$SAME')" \
    test "$SAME" = True
wbp "$SCRATCH/log.json" log "$ID" --json
JSON_CLAUDE=$(py "print(sum(1 for l in lines if l['kind'] == 'claude' and l['seq'] is None))" <"$SCRATCH/log.json" 2>/dev/null)
check "log --json prints the transcript lines as claude events with seq null" \
    "log --json has '$JSON_CLAUDE' such lines, turn.ended counted ${ENDED%% *}" \
    bash -c '[ -n "$1" ] && [ "$1" -gt 0 ] && [ "$1" = "$2" ]' _ "$JSON_CLAUDE" "${ENDED%% *}"

wbp "$SCRATCH/status.out" status "$ID"
check "status loads the thread" "workbench status exited $RC" test "$RC" = 0
wbp "$SCRATCH/status.json" status "$ID" --json
check "status --json loads the thread" "workbench status --json exited $RC" test "$RC" = 0
wbp "$SCRATCH/review.out" review "$ID"
check "review loads the thread" "workbench review exited $RC" test "$RC" = 0

wbp "$SCRATCH/abandon.out" abandon "$ID"
check "abandon ends the thread" "workbench abandon exited $RC" test "$RC" = 0
finish
