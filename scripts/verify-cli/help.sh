#!/bin/bash
# verify-cli scenario for per-command help (P15 task 2), on this repository. No turn is run, so it costs nothing.
#   bash scripts/verify-cli/help.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/help.sh   (the same, on a branch that contains origin/main)
# Every command in `workbench help` must answer `<cmd> --help`, `-h` and `help <cmd>` with one text and exit 0, in this
# repository and in a directory that is no repository; help must write nothing to a thread; a usage error keeps one line
# and names the command's synopsis, in text and in JSON; an unknown command lists the commands. Exit 0 only when every
# step passed, 1 when one failed, 2 when it refused to start (nothing changed). VERIFY_CLI_SABOTAGE=1 compares `ship`'s
# help with `plan`'s, so the "same text" step must FAIL. The frame and the other switches are in lib.sh. Run by hand,
# not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

GOAL_SRC="$SCRATCH/goal.md"
cat >"$GOAL_SRC" <<'GOAL'
---
id: verify-cli-help
title: verify-cli help scenario
base: origin/main
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

This is a throwaway thread that tests `workbench help`; no turn is run and its branch never exists.

## Criteria

- [c1] Nothing changes.
  - proof: the thread's log is the same before and after help

## Out of scope

- Everything.
GOAL

start_thread verify-cli-help "$GOAL_SRC"
EMPTY="$SCRATCH/not-a-repo"
mkdir -p "$EMPTY"

# `wbx <dir> <out> <err> args...`: a workbench command in <dir>, stdout and stderr kept apart; sets RC.
RC=0
wbx() {
    local dir=$1 o=$2 e=$3; shift 3
    echo "workbench $*   (in ${dir#$ROOT})" >>"$SCRATCH/commands"
    ( cd "$dir" && with_timeout "$T_WB" "$WB" "$@" >"$o" 2>"$e" )
    RC=$?
}
same() { cmp -s "$1" "$2" && cmp -s "$1" "$3"; }
log_lines() { wb "$T_WB" log "$ID" --json | py "print(len(lines))"; }

# --- 1. every command, three ways, in a repository and outside one ----------------------------------------

wbx "$ROOT" "$SCRATCH/usage.out" "$SCRATCH/usage.err" help
# The command names are the usage block's two-space entries, as the help is cut from them.
NAMES=$(sed -n 's/^  \([a-z][a-z-]*\)\( .*\)\{0,1\}$/\1/p' "$SCRATCH/usage.out" | awk '!seen[$0]++')
COUNT=$(echo "$NAMES" | wc -w | tr -d ' ')
check "help lists the commands" "found $COUNT command names in 'workbench help'" test "$COUNT" -ge 20

bad_exit=""; bad_same=""; bad_parts=""; bad_outside=""
for name in $NAMES; do
    wbx "$ROOT" "$SCRATCH/h1" "$SCRATCH/e1" "$name" --help; r1=$RC
    wbx "$ROOT" "$SCRATCH/h2" "$SCRATCH/e2" "$name" -h; r2=$RC
    third=$name; [ "$SABOTAGE" = 1 ] && [ "$name" = ship ] && third=plan
    wbx "$ROOT" "$SCRATCH/h3" "$SCRATCH/e3" help "$third"; r3=$RC
    { [ "$r1" = 0 ] && [ "$r2" = 0 ] && [ "$r3" = 0 ]; } || bad_exit="$bad_exit $name"
    same "$SCRATCH/h1" "$SCRATCH/h2" "$SCRATCH/h3" || bad_same="$bad_same $name"
    for part in "workbench $name" "changes: " "example: workbench " "--json: " "exit: "; do
        grep -qF -- "$part" "$SCRATCH/h1" || { bad_parts="$bad_parts $name($part)"; break; }
    done
    [ -s "$SCRATCH/e1" ] && bad_exit="$bad_exit $name(stderr)"
    wbx "$EMPTY" "$SCRATCH/h4" "$SCRATCH/e4" "$name" --help
    { [ "$RC" = 0 ] && cmp -s "$SCRATCH/h1" "$SCRATCH/h4"; } || bad_outside="$bad_outside $name"
done
check "every command: --help, -h and help <cmd> exit 0, print nothing on stderr" "failed for:$bad_exit" test -z "$bad_exit"
check "every command: the three forms print the same text" "differ for:$bad_same" test -z "$bad_same"
check "every command: the text names it, what it changes, an example, --json and the exit codes" \
    "missing for:$bad_parts" test -z "$bad_parts"
check "every command: the same help outside a repository" "differs or fails for:$bad_outside" test -z "$bad_outside"
[ -z "$(ls -A "$EMPTY")" ] || fail "help wrote into the empty directory" "$(ls -A "$EMPTY")"

# --- 2. forms of one command ------------------------------------------------------------------------------

wbx "$ROOT" "$SCRATCH/plan.out" "$SCRATCH/plan.err" help plan
wbx "$ROOT" "$SCRATCH/show.out" "$SCRATCH/show.err" plan show --help
check "plan: every form" "help plan lacks a form" bash -c 'grep -q "plan show \[id\]" "$1" && grep -q "plan edit \[id\]" "$1" && grep -q -- "--again" "$1"' _ "$SCRATCH/plan.out"
check "plan show --help: that form alone" "it also shows another form" \
    bash -c 'grep -q "plan show \[id\]" "$1" && ! grep -q "plan edit \[id\]" "$1"' _ "$SCRATCH/show.out"

# --- 3. help changes nothing in a thread ------------------------------------------------------------------

before=$(log_lines)
for args in "status --help" "run -h" "help accept" "ship --help"; do wbx "$ROOT" "$SCRATCH/o" "$SCRATCH/e" $args; done
check "help leaves the thread's log alone" "the log had $before lines, now $(log_lines)" test "$(log_lines)" = "$before"
check "help creates no worktree or branch for the thread" "branch $BRANCH exists" \
    bash -c '! git rev-parse -q --verify "refs/heads/$1" >/dev/null' _ "$BRANCH"

# --- 4. usage errors keep one line and carry the synopsis -------------------------------------------------

wbx "$ROOT" "$SCRATCH/o" "$SCRATCH/e" ship --bogus
check "usage error: exit 2, nothing on stdout" "exit $RC, stdout: $(head -c 200 "$SCRATCH/o")" bash -c '[ "$1" = 2 ] && [ ! -s "$2" ]' _ "$RC" "$SCRATCH/o"
check "usage error: one line on stderr" "$(wc -l <"$SCRATCH/e" | tr -d ' ') lines" test "$(grep -c . "$SCRATCH/e")" = 1
check "usage error: the argument, the synopsis and the help pointer" "stderr: $(head -c 300 "$SCRATCH/e")" \
    bash -c 'grep -q "unexpected argument .--bogus." "$1" && grep -q "usage: ship \[id\] \[--yes\]" "$1" && grep -q "(workbench help ship)" "$1"' _ "$SCRATCH/e"
wbx "$ROOT" "$SCRATCH/o" "$SCRATCH/e" status --bogus --json
msg=$(py "print(d['error']['message'] if d else '')" <"$SCRATCH/o")
check "usage error with --json: exit 2 and the synopsis in error.message" "exit $RC, message '$msg'" \
    bash -c '[ "$1" = 2 ] && [[ $2 == *"usage: status [id] [--all]"* ]] && [[ $2 == *"(workbench help status)"* ]]' _ "$RC" "$msg"

# --- 5. unknown command, plain help -----------------------------------------------------------------------

wbx "$ROOT" "$SCRATCH/o" "$SCRATCH/e" help frobnicate
check "help <unknown>: exit 2 and the list of commands" "exit $RC: $(head -c 200 "$SCRATCH/e")" \
    bash -c '[ "$1" = 2 ] && grep -q "unknown command .frobnicate." "$2" && grep -q "Commands: new, init" "$2"' _ "$RC" "$SCRATCH/e"
check "plain help is the usage block" "it no longer starts with 'usage: workbench <command>'" \
    grep -q '^usage: workbench <command>' "$SCRATCH/usage.out"

# Ends the thread (one active thread at a time); it never had a branch or a worktree.
wb "$T_WB" abandon "$ID" >/dev/null 2>&1
ended=$(wb "$T_WB" status "$ID" --json | py "print(d['ended'])")
check "abandon ends the thread" "status says ended: $ended" test "$ended" = abandoned
finish
