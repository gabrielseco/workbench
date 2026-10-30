#!/bin/bash
# verify-cli scenario for `[review] auto`: the judge run by itself after a turn. On a clone of this repository with a `claude`
# stand-in that runs the fake-claude test double: the coding turn writes one file and the judge's turn answers with a known verdict.
# No real turn is run, so it costs nothing.
#   bash scripts/verify-cli/auto-advice.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/auto-advice.sh   (the same, on a branch that contains origin/main)
# With `[review] auto = ["judge"]` in the config, `workbench run` must end its output with `auto judge: 1 of 1 criteria met` before the
# `review:` line and exit 0; the log must then hold exactly one `judge.ran` (for turn 1, ok) and no second judge; `workbench next` must
# no longer list the judge (its first line is the decision) and `workbench judge` must say the turn was judged already. Exit 0 only
# when every step passed, 1 when one failed, 2 when it refused to start (nothing changed). VERIFY_CLI_SABOTAGE=1 leaves `auto` out of
# the config, so the steps that expect the auto line, the judge event and a next without the judge must FAIL. A second thread whose goal
# says `skip: judge` is then run the same way: its run must print `auto judge: skipped, the goal skips it`, the log must hold no
# `judge.ran`, and `next` must not list the judge (under SABOTAGE no auto line is printed and `next` lists the judge, so those fail).
# The frame is in lib.sh.
# Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

echo "==> building fake-claude"
with_timeout "$T_BUILD" swift build --product fake-claude || die "swift build --product fake-claude failed"
FAKE="$ROOT/.build/debug/fake-claude"
[ -x "$FAKE" ] || die "no $FAKE after the build"

P="$SCRATCH/project"
BIN="$SCRATCH/bin"
VERDICT="$SCRATCH/verdict.json"
BASE=verify-cli-base
g clone -q "$ROOT" "$P" || die "git clone failed"
g -C "$P" checkout -q -b "$BASE" || die "could not make the base branch in the clone"
mkdir -p "$BIN" || die "could not make $BIN"
printf '{"criteria": [{"id": "c1", "met": true, "evidence": ["stand-in verdict"]}], "concerns": []}\n' >"$VERDICT"
# `--output-format json` is the judge's turn (the coding turn streams).
cat >"$BIN/claude" <<STUB
#!/bin/sh
mode=""; prev=""
for a in "\$@"; do [ "\$prev" = --output-format ] && mode=\$a; prev=\$a; done
if [ "\$mode" = json ]; then FAKE_CLAUDE='answer=$VERDICT' exec '$FAKE' "\$@"; fi
FAKE_CLAUDE=write=auto-probe.txt exec '$FAKE' "\$@"
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
AUTO='auto = ["judge"]'
if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: [review] auto is left out of the config"
    AUTO=''
fi
cat >"$P/.workbench/config.toml" <<TOML
claude_path = "$BIN/claude"
default_budget_usd = 0.10

[tools]
available = ["Read", "Edit", "Write"]
allowed = ["Read", "Edit", "Write"]

[review]
$AUTO
TOML

cat >"$SCRATCH/goal.md" <<'GOAL'
---
title: Auto advice
budget_usd: 0.10
turn_timeout_min: 5
---

## Request

Nothing real runs: the stand-in claude writes one file and the judge answers with a known verdict.

## Criteria

- [c1] The judge ran by itself.
  - proof: the scenario reads the output

## Out of scope

- Any change to the code.
GOAL
wbp "$SCRATCH/new.out" goal new auto-advice --from "$SCRATCH/goal.md" --base "$BASE"
ID=$(sed -n 's/^created //p' "$SCRATCH/new.out")
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id ($(head -3 "$SCRATCH/new.out"))"
wbp "$SCRATCH/approve.out" goal approve "$ID"
[ "$RC" = 0 ] || die "goal approve $ID failed: $(cat "$SCRATCH/approve.out")"
EVENTS="$P/.workbench/threads/$ID/events.jsonl"

wbp "$SCRATCH/run.out" run "$ID"
shown "$SCRATCH/run.out" 24
check "run: exit 0" "workbench run exited $RC" test "$RC" = 0
check "run prints the auto judge line, before the review line" "output: $(tail -6 "$SCRATCH/run.out")" \
    bash -c 'a=$(grep -n "^auto judge: 1 of 1 criteria met" "$1" | head -1 | cut -d: -f1); r=$(grep -n "^review:" "$1" | head -1 | cut -d: -f1); [ -n "$a" ] && [ -n "$r" ] && [ "$a" -lt "$r" ]' _ "$SCRATCH/run.out"
check "the log holds one judge.ran for turn 1, ok" "judge.ran events: $(grep -c '"kind":"judge.ran"' "$EVENTS")" \
    bash -c 'test "$(grep -c "\"kind\":\"judge.ran\"" "$1")" = 1 && grep "\"kind\":\"judge.ran\"" "$1" | grep -q "\"turn\":1" && grep "\"kind\":\"judge.ran\"" "$1" | grep -q "\"ok\":true"' _ "$EVENTS"

wbp "$SCRATCH/next.out" next "$ID"
shown "$SCRATCH/next.out" 4
check "next no longer lists the judge" "first line: $(head -1 "$SCRATCH/next.out")" \
    bash -c 'head -1 "$1" | grep -q "^next  workbench accept " && ! grep -q "workbench judge" "$1"' _ "$SCRATCH/next.out"
wbp "$SCRATCH/judge.out" judge "$ID"
check "judge says the turn was judged already (exit 6)" "exit $RC: $(head -c 200 "$SCRATCH/judge.out")" \
    bash -c 'test "$1" = 6 && grep -qi "already" "$2"' _ "$RC" "$SCRATCH/judge.out"

# --- a goal that skips the judge -------------------------------------------------------------------------------------------

wbp "$SCRATCH/abandon.out" abandon "$ID" --force
[ "$RC" = 0 ] || die "abandon $ID failed: $(cat "$SCRATCH/abandon.out")"
wbp "$SCRATCH/new2.out" goal new skip-probe --from "$SCRATCH/goal.md" --base "$BASE"
ID2=$(sed -n 's/^created //p' "$SCRATCH/new2.out")
[[ $ID2 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id ($(head -3 "$SCRATCH/new2.out"))"
if [ "$SABOTAGE" != 1 ]; then
    # `goal new --from` does not carry `skip`, so the line goes into the draft the way a person's editor would put it.
    python3 -I - "$P/.workbench/threads/$ID2/goal.md" <<'PY' || die "could not add skip to the goal"
import sys
path = sys.argv[1]
lines = open(path).read().split("\n")
close = [i for i, l in enumerate(lines) if l == "---"][1]
lines.insert(close, "skip: judge")
open(path, "w").write("\n".join(lines))
PY
fi
wbp "$SCRATCH/approve2.out" goal approve "$ID2"
[ "$RC" = 0 ] || die "goal approve $ID2 failed: $(cat "$SCRATCH/approve2.out")"
EVENTS2="$P/.workbench/threads/$ID2/events.jsonl"
wbp "$SCRATCH/run2.out" run "$ID2"
shown "$SCRATCH/run2.out" 24
check "run on the goal that skips the judge: exit 0" "workbench run exited $RC" test "$RC" = 0
check "run says the goal skips the judge" "output: $(tail -6 "$SCRATCH/run2.out")" \
    grep -q "^auto judge: skipped, the goal skips it" "$SCRATCH/run2.out"
check "the log holds no judge.ran" "judge.ran events: $(grep -c '"kind":"judge.ran"' "$EVENTS2")" \
    bash -c 'test "$(grep -c "\"kind\":\"judge.ran\"" "$1")" = 0' _ "$EVENTS2"
wbp "$SCRATCH/next2.out" next "$ID2"
check "next does not list the judge for that goal" "output: $(cat "$SCRATCH/next2.out")" \
    bash -c '! grep -q "workbench judge" "$1" && head -1 "$1" | grep -q "^next  workbench accept "' _ "$SCRATCH/next2.out"
finish
