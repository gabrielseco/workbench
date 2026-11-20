#!/bin/bash
# verify-cli scenario for a task's gate (`gate: inline` in task.md; `task run --dry`, `task held`), on a clone of this repository whose
# origin is a bare copy in the temp folder, with a `claude` stand-in that runs the fake-claude test double (its read-only turns answer
# one after the other, from files) and a `gh` stand-in that keeps pull requests in a file. Nothing real is contacted and no real turn
# runs, so it costs nothing.
#   bash scripts/verify-cli/task-gate.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/task-gate.sh   (the same, on a branch that contains origin/main)
# A task with a gate reads a list of three countries through a pending script and takes two at a time. The gate says TUR depends on a
# setting that is off. `task run --dry` must say it would take ROU and PAN and hold TUR, start no thread and write no verdict (`task held`
# says it holds nothing). The real run must open one pull request for ROU and PAN only, and `task held` must list TUR with the
# gate's reason (`task list` says `held: 1`). The next run must say nothing-pending with TUR held and must not ask the gate again.
# `task held --release TUR` must forget it (exit 0; a second release exit 6; an unknown task exit 7). A gate answer that is not usable
# must end the run failed (exit 1) with no thread, and a gate that holds every candidate must end it nothing-to-do (exit 0, no thread
# and no pull request). Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start (nothing changed).
# VERIFY_CLI_SABOTAGE=1 makes the stand-in gate clear every candidate: "the dry run holds TUR and takes ROU and PAN", "the real run
# takes ROU and PAN and leaves TUR", "task held lists TUR with the gate's reason" and "a held unit is not offered or asked about
# again" must FAIL.
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

DESCRIPTION='{"title": "chore: bump countries", "summary": "Bumps the next countries.", "decisions": [], "deviations": []}'
# The read-only turns (the gate's, then the pull request's description) answer one after the other from $ANS; the worker's turn adds a file.
ANS="$SCRATCH/answers"
mkdir -p "$ANS"
cat >"$BIN/claude" <<STUB
#!/bin/sh
FAKE_CLAUDE=write=task-probe.txt,answers=$ANS exec '$FAKE' "\$@"
STUB
# A gh that is logged in, opens pull requests into a file, and answers `pr list --head X` for the branches it opened.
STATE=OPEN
cat >"$BIN/gh" <<STUB
#!/bin/sh
echo "\$@" >>"$GHDIR/calls"
head=""; prev=""
for a in "\$@"; do [ "\$prev" = "--head" ] && head=\$a; prev=\$a; done
case "\$1 \$2" in
"auth status") exit 0 ;;
"pr list")
    if [ -z "\$head" ]; then
        if [ -f "$GHDIR/list_fail" ]; then echo "error connecting to api.github.com" >&2; exit 1; fi
        # No --head: the question about every open pull request (the task counts its own against max_open).
        if [ "$STATE" = OPEN ]; then
            printf '['; sed 's/.*/{"headRefName":"&"}/' "$GHDIR/heads" 2>/dev/null | paste -sd, -; printf ']\n'
        else echo '[]'; fi
    elif grep -qx "\$head" "$GHDIR/heads" 2>/dev/null; then echo '[{"state":"$STATE"}]'; else echo '[]'; fi
    exit 0 ;;
"label create")
    if [ -f "$GHDIR/label_fail" ]; then echo "HTTP 403: Resource not accessible" >&2; exit 1; fi
    exit 0 ;;
"pr edit") exit 0 ;;
"pr create")
    echo "\$head" >>"$GHDIR/heads"
    echo "https://github.com/o/r/pull/\$(wc -l <"$GHDIR/heads" | tr -d ' ')"
    exit 0 ;;
esac
echo "verify-cli stand-in gh: \$*" >&2
exit 2
STUB
chmod +x "$BIN/claude" "$BIN/gh"
[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the stand-in gate clears every candidate"
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


answers() { # <text>...: the read-only turns' answers, in the order they are asked
    rm -rf "$ANS"; mkdir -p "$ANS"
    local i=1 t
    for t in "$@"; do printf '%s' "$t" >"$ANS/$i.txt"; i=$((i + 1)); done
}
asked() { cat "$ANS/count" 2>/dev/null || echo 0; }
TUR_VERDICT='{"id": "TUR", "verdict": "gated", "reason": "changelog v2: needs flag tur_x, which is off"}'
[ "$SABOTAGE" = 1 ] && TUR_VERDICT='{"id": "TUR", "verdict": "clear", "reason": "sabotaged: nothing found"}'
ROU_TUR="{\"units\": [{\"id\": \"ROU\", \"verdict\": \"clear\", \"reason\": \"no flag in v2\"}, $TUR_VERDICT], \"concerns\": []}"
PAN='{"units": [{"id": "PAN", "verdict": "clear", "reason": "no flag in v2"}], "concerns": []}'

TASK="$P/.workbench/tasks/bump"
mkdir -p "$TASK"
printf 'ROU\nTUR\nPAN\n' >"$P/countries.txt"
cat >"$TASK/pending.sh" <<'SH'
#!/bin/sh
printf '['
sed 's/.*/{"id":"&","title":"& v1 -> v2"}/' countries.txt | paste -sd, -
printf ']\n'
SH
chmod +x "$TASK/pending.sh"
cat >"$TASK/task.md" <<'MD'
---
batch: 2
fix: pr
max_open: 5
gate: inline
gate_rounds: 3
pending: .workbench/tasks/bump/pending.sh
---
Bump the next countries.

## Gate
A country is gated when the version it moves to depends on a setting that is not enabled.
MD

wbp "$SCRATCH/approve.out" task approve bump
check "approve records the task and says what the gate may run" "exit $RC: $(head -c 300 "$SCRATCH/approve.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "^gate:" "$2"' _ "$RC" "$SCRATCH/approve.out"

# --- 1. a dry run asks the gate and records nothing -------------------------------------------------------

answers "$ROU_TUR" "$PAN"
wbp "$SCRATCH/dry.out" task run bump --dry; shown "$SCRATCH/dry.out"
check "the dry run holds TUR and takes ROU and PAN" "exit $RC: $(head -c 400 "$SCRATCH/dry.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "dry run (gate): would take ROU, PAN; held: TUR" "$2"' _ "$RC" "$SCRATCH/dry.out"
check "the dry run started no thread and the gate was asked twice" "threads: $(threads), asked: $(asked)" \
    bash -c '[ "$(ls "$1/.workbench/threads" 2>/dev/null | wc -l)" -eq 0 ] && [ "$2" = 2 ]' _ "$P" "$(asked)"
wbp "$SCRATCH/held0.out" task held bump
check "a dry run wrote no verdict: nothing is held" "got: $(head -c 200 "$SCRATCH/held0.out")" \
    bash -c 'grep -q "the gate holds nothing" "$1"' _ "$SCRATCH/held0.out"

# --- 2. the real run takes only what the gate cleared -------------------------------------------------------

answers "$ROU_TUR" "$PAN" "$DESCRIPTION"
wbp "$SCRATCH/run1.out" task run bump; shown "$SCRATCH/run1.out"
check "the real run takes ROU and PAN and leaves TUR" "exit $RC: $(head -c 400 "$SCRATCH/run1.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "^bump: pr-opened" "$2" && grep -q "units:  ROU, PAN$" "$2"' _ "$RC" "$SCRATCH/run1.out"
check "exactly one pull request was opened" "gh calls: $(grep -c 'pr create' "$GHDIR/calls")" test "$(grep -c 'pr create' "$GHDIR/calls")" = 1
wbp "$SCRATCH/held1.out" task held bump; shown "$SCRATCH/held1.out"
check "task held lists TUR with the gate's reason" "got: $(head -c 400 "$SCRATCH/held1.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "1 held by the gate" "$2" && grep -q "TUR  TUR v1 -> v2" "$2" && grep -q "needs flag tur_x" "$2"' _ "$RC" "$SCRATCH/held1.out"
wbp "$SCRATCH/list.out" task list
check "task list says how many units are held" "got: $(head -c 400 "$SCRATCH/list.out")" bash -c 'grep -q "held: 1 by the gate" "$1"' _ "$SCRATCH/list.out"
LOG="$TASK/runs.jsonl"
check "the log holds the verdicts before the thread, in order" "kinds: $(grep -o '"kind":"task[a-z.]*"' "$LOG" | tr '\n' ' ')" \
    bash -c 'grep -o "\"kind\":\"task[a-z.]*\"" "$1" | sed "s/.*:\"//;s/\"//" | tr "\n" " " | grep -q "task.unit.cleared task.unit.held task.run.gate task.unit.cleared task.run.gate task.run.thread"' _ "$LOG"

# --- 3. a held unit is not offered or asked about again ----------------------------------------------------

BEFORE=$(asked)
wbp "$SCRATCH/run2.out" task run bump; shown "$SCRATCH/run2.out"
check "a held unit is not offered or asked about again" "exit $RC, asked $BEFORE -> $(asked): $(head -c 300 "$SCRATCH/run2.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "^bump: nothing-pending" "$2" && grep -q "1 held by the gate" "$2" && [ "$3" = "$4" ]' _ "$RC" "$SCRATCH/run2.out" "$BEFORE" "$(asked)"

# --- 4. a person releases it ---------------------------------------------------------------------------------

wbp "$SCRATCH/rel1.out" task held bump --release TUR
check "release forgets the unit" "exit $RC: $(head -c 200 "$SCRATCH/rel1.out")" test "$RC" = 0
wbp "$SCRATCH/rel2.out" task held bump --release TUR
check "releasing a unit that is not held is refused (exit 6)" "exit $RC: $(head -c 200 "$SCRATCH/rel2.out")" test "$RC" = 6
wbp "$SCRATCH/rel3.out" task held nothing
check "an unknown task is exit 7" "exit $RC: $(head -c 200 "$SCRATCH/rel3.out")" test "$RC" = 7

# --- 5. an answer that is not usable, and a gate that holds everything -----------------------------------

THREADS=$(threads)
answers 'this is not JSON'
wbp "$SCRATCH/bad.out" task run bump; shown "$SCRATCH/bad.out"
check "an unusable gate answer fails the run and starts no thread" "exit $RC: $(head -c 300 "$SCRATCH/bad.out")" \
    bash -c '[ "$1" = 1 ] && grep -q "^bump: failed" "$2" && grep -q "the gate could not decide" "$2" && [ "$3" = "$4" ]' _ "$RC" "$SCRATCH/bad.out" "$THREADS" "$(threads)"
answers '{"units": [{"id": "TUR", "verdict": "gated", "reason": "still needs flag tur_x"}], "concerns": []}'
wbp "$SCRATCH/none.out" task run bump; shown "$SCRATCH/none.out"
check "a gate that holds every candidate ends nothing-to-do with no thread and no pull request" "exit $RC: $(head -c 300 "$SCRATCH/none.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "^bump: nothing-to-do" "$2" && grep -q "TUR (still needs flag tur_x)" "$2" && [ "$3" = "$4" ] && [ "$(grep -c "pr create" "$5")" = 1 ]' _ "$RC" "$SCRATCH/none.out" "$THREADS" "$(threads)" "$GHDIR/calls"

finish
