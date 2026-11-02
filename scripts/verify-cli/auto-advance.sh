#!/bin/bash
# verify-cli scenario for `[review] auto_advance` and the goal's `auto_advance:` key: the judge run by itself after a turn, without `auto`
# listing it. On a clone of this repository with a `claude` stand-in that runs the fake-claude test double (the coding turn writes one
# file and the judge's turn answers with a known verdict), so no real turn is run and it costs nothing.
#   bash scripts/verify-cli/auto-advance.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/auto-advance.sh   (the same, on a branch that contains origin/main)
# Three threads, one after the other (each abandoned before the next):
#   1. `[review] auto_advance = true` and a goal that says nothing: `workbench run` must end its output with `auto judge: 1 of 1
#      criteria met` before the `review:` line and exit 0; the log must hold exactly one `judge.ran` (turn 1, ok); `workbench next` must
#      no longer list the judge and `workbench judge` must say the turn was judged already.
#   2. the same config and a goal that says `auto_advance: false`: its run must print no `auto` line at all, the log must hold no
#      `judge.ran`, and `next` must still list the judge (a negative control: it passes with or without the sabotage).
#   3. the config with the switch off and a goal that says `auto_advance: true`: its run must print `auto judge: 1 of 1 criteria met`
#      and the log must hold one `judge.ran`.
# Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start (nothing changed). VERIFY_CLI_SABOTAGE=1 leaves the
# config switch and the goals' keys out, so the steps of threads 1 and 3 that expect the auto line and the judge event must FAIL.
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

config() { # <review section body>: the project's config with that [review] body
    cat >"$P/.workbench/config.toml" <<TOML
claude_path = "$BIN/claude"
default_budget_usd = 0.10

[tools]
available = ["Read", "Edit", "Write"]
allowed = ["Read", "Edit", "Write"]

[review]
$1
TOML
}

cat >"$SCRATCH/goal.md" <<'GOAL'
---
title: Auto advance
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

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0

# A thread from the goal above, with `$2` (a front-matter line, or nothing) added the way a person's editor would put it; sets ID and EVENTS.
new_thread() { # <name> <front matter line or empty>
    wbp "$SCRATCH/new-$1.out" goal new "$1" --from "$SCRATCH/goal.md" --base "$BASE"
    ID=$(sed -n 's/^created //p' "$SCRATCH/new-$1.out")
    [[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id ($(head -3 "$SCRATCH/new-$1.out"))"
    if [ -n "$2" ] && [ "$SABOTAGE" != 1 ]; then
        python3 -I - "$P/.workbench/threads/$ID/goal.md" "$2" <<'PY' || die "could not add $2 to the goal"
import sys
path, line = sys.argv[1], sys.argv[2]
lines = open(path).read().split("\n")
close = [i for i, l in enumerate(lines) if l == "---"][1]
lines.insert(close, line)
open(path, "w").write("\n".join(lines))
PY
    fi
    wbp "$SCRATCH/approve-$1.out" goal approve "$ID"
    [ "$RC" = 0 ] || die "goal approve $ID failed: $(cat "$SCRATCH/approve-$1.out")"
    EVENTS="$P/.workbench/threads/$ID/events.jsonl"
}
judge_events() { grep -c '"kind":"judge.ran"' "$EVENTS"; }

# --- 1. the switch in the config, a goal that says nothing --------------------------------------------------------------------

SWITCH='auto_advance = true'
if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: the config switch and the goals' keys are left out"
    SWITCH=''
fi
config "$SWITCH"
new_thread switch-on ""
wbp "$SCRATCH/run1.out" run "$ID"
shown "$SCRATCH/run1.out" 24
check "1: run exits 0" "workbench run exited $RC" test "$RC" = 0
check "1: run prints the auto judge line, before the review line" "output: $(tail -6 "$SCRATCH/run1.out")" \
    bash -c 'a=$(grep -n "^auto judge: 1 of 1 criteria met" "$1" | head -1 | cut -d: -f1); r=$(grep -n "^review:" "$1" | head -1 | cut -d: -f1); [ -n "$a" ] && [ -n "$r" ] && [ "$a" -lt "$r" ]' _ "$SCRATCH/run1.out"
check "1: the log holds one judge.ran for turn 1, ok" "judge.ran events: $(judge_events)" \
    bash -c 'test "$(grep -c "\"kind\":\"judge.ran\"" "$1")" = 1 && grep "\"kind\":\"judge.ran\"" "$1" | grep -q "\"turn\":1" && grep "\"kind\":\"judge.ran\"" "$1" | grep -q "\"ok\":true"' _ "$EVENTS"
wbp "$SCRATCH/next1.out" next "$ID"
check "1: next no longer lists the judge" "first line: $(head -1 "$SCRATCH/next1.out")" \
    bash -c 'head -1 "$1" | grep -q "^next  workbench accept " && ! grep -q "workbench judge" "$1"' _ "$SCRATCH/next1.out"
wbp "$SCRATCH/judge1.out" judge "$ID"
check "1: judge says the turn was judged already (exit 6)" "exit $RC: $(head -c 200 "$SCRATCH/judge1.out")" \
    bash -c 'test "$1" = 6 && grep -qi "already" "$2"' _ "$RC" "$SCRATCH/judge1.out"
wbp "$SCRATCH/abandon1.out" abandon "$ID" --force
[ "$RC" = 0 ] || die "abandon $ID failed: $(cat "$SCRATCH/abandon1.out")"

# --- 2. the switch in the config, a goal that says false -----------------------------------------------------------------------

new_thread switch-off-for-this-goal "auto_advance: false"
wbp "$SCRATCH/run2.out" run "$ID"
shown "$SCRATCH/run2.out" 24
check "2: run exits 0" "workbench run exited $RC" test "$RC" = 0
check "2: run prints no auto line" "output: $(tail -6 "$SCRATCH/run2.out")" \
    bash -c '! grep -q "^auto " "$1"' _ "$SCRATCH/run2.out"
check "2: the log holds no judge.ran" "judge.ran events: $(judge_events)" bash -c 'test "$(grep -c "\"kind\":\"judge.ran\"" "$1")" = 0' _ "$EVENTS"
wbp "$SCRATCH/next2.out" next "$ID"
check "2: next still lists the judge" "output: $(cat "$SCRATCH/next2.out")" grep -q "workbench judge" "$SCRATCH/next2.out"
wbp "$SCRATCH/abandon2.out" abandon "$ID" --force
[ "$RC" = 0 ] || die "abandon $ID failed: $(cat "$SCRATCH/abandon2.out")"

# --- 3. the switch off in the config, a goal that says true --------------------------------------------------------------------

config ''
new_thread switch-on-for-this-goal "auto_advance: true"
wbp "$SCRATCH/run3.out" run "$ID"
shown "$SCRATCH/run3.out" 24
check "3: run exits 0" "workbench run exited $RC" test "$RC" = 0
check "3: run prints the auto judge line" "output: $(tail -6 "$SCRATCH/run3.out")" grep -q "^auto judge: 1 of 1 criteria met" "$SCRATCH/run3.out"
check "3: the log holds one judge.ran" "judge.ran events: $(judge_events)" bash -c 'test "$(grep -c "\"kind\":\"judge.ran\"" "$1")" = 1' _ "$EVENTS"
finish
