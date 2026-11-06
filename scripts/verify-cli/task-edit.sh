#!/bin/bash
# verify-cli scenario for `workbench task edit`, on a clone of this repository. The goal agent is a fake `codex` script the scenario
# writes, so no real agent is started and it costs nothing.
#   bash scripts/verify-cli/task-edit.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/task-edit.sh   (the same, on a branch that contains origin/main)
# The request is the words after the name (or --request, or --request-file). With no [agents.goal] the command is refused (exit 6) and nothing changes. With a Codex goal agent a proposal is shown as what it
# changes (a setting approval binds to as old -> new, the instructions as a diff) and nothing is written without --accept; an answer that
# is not a task file fails (exit 1) and leaves the file byte-identical; with --accept the file is rewritten, and a task that was approved
# reads stale (accepting never approves).
# Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start. VERIFY_CLI_SABOTAGE=1 never passes --accept and has
# the fake answer with a valid file even for the "bad answer" step, so the steps that expect the failure, the written file and the stale
# approval must FAIL. The frame and the other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: no --accept, and the fake never answers with a bad file"

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
shown() { sed 's/^/    /' "$1" | head -${2:-14}; }
cfg="$P/.workbench/config.toml"
TASK="$P/.workbench/tasks/bump/task.md"

# The fake Codex: writes the contents of $FAKE/answer to the file after -o and counts its runs.
FAKE="$SCRATCH/fake-codex"
mkdir -p "$FAKE"
cat >"$FAKE/codex" <<FAKE_SCRIPT
#!/bin/sh
out=""; prev=""
for a in "\$@"; do [ "\$prev" = "-o" ] && out="\$a"; prev="\$a"; done
echo run >> "$FAKE/runs"
printf '%s\\n' "\$@" > "$FAKE/prompt.args"
cat > "$FAKE/prompt.stdin"
cat "$FAKE/answer" > "\$out"
echo "fake codex"
FAKE_SCRIPT
chmod +x "$FAKE/codex"
runs() { if [ -f "$FAKE/runs" ]; then wc -l <"$FAKE/runs" | tr -d ' '; else echo 0; fi; }
setgoal() { # <"-" for no goal agent>: rewrites the config with a Codex goal agent
    grep -v -e '^model = ' -e '^claude_path = ' "$SCRATCH/config.base" >"$SCRATCH/config.rest"
    { echo 'claude_path = "/usr/bin/false"'; cat "$SCRATCH/config.rest"
      if [ "$1" != "-" ]; then
          printf '\n[providers.codex]\nexecutable = "%s"\n\n[agents.goal]\nprovider = "codex"\nallow_unpriced = true\n' "$FAKE/codex"
      fi; } >"$cfg"
}

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
cp "$cfg" "$SCRATCH/config.base"
mkdir -p "$P/.workbench/tasks/bump"
printf -- '---\nat: 04:00\ndays: weekdays\nfix: report\n---\nList the open TODOs.\nNever touch .workbench/notes.txt.\n' >"$TASK"
cp "$TASK" "$SCRATCH/task.before"
GOOD='---\nat: 04:00\ndays: weekdays\nfix: report\nbudget: 3\n---\nList the open TODOs.\nNever touch .workbench/notes.txt.\nSkip the vendor folder.\n'
printf -- "$GOOD" >"$FAKE/answer"

# --- 1. no [agents.goal] -------------------------------------------------------------------------------------

setgoal -
wbp "$SCRATCH/none.out" task edit bump --request "skip vendor"
shown "$SCRATCH/none.out" 3
check "no [agents.goal]: task edit is refused, exit 6" "workbench task edit exited $RC" test "$RC" = 6
check "nothing was written" "task.md changed" cmp -s "$SCRATCH/task.before" "$TASK"

# --- 2. a proposal is shown and writes nothing ---------------------------------------------------------------

setgoal codex
wbp "$SCRATCH/propose.out" task edit bump "allow three dollars and skip the vendor folder"
shown "$SCRATCH/propose.out" 14
check "a proposal: exit 0" "workbench task edit exited $RC" test "$RC" = 0
check "it shows the budget as a setting that changes" "no budget line" grep -q "budget: (not set) -> 3" "$SCRATCH/propose.out"
check "it shows the new instruction as an added line" "no + line" grep -q "+ Skip the vendor folder." "$SCRATCH/propose.out"
check "it says nothing was written" "no such line" grep -q "nothing was written" "$SCRATCH/propose.out"
check "the task file is byte-identical" "task.md changed" cmp -s "$SCRATCH/task.before" "$TASK"
check "the agent ran once" "the fake ran $(runs) time(s)" test "$(runs)" = 1
check "the agent was given the file's own .workbench path whole, not <path>" "the path was scrubbed" \
    bash -c 'cat "$1" "$2" | grep -q "Never touch .workbench/notes.txt."' _ "$FAKE/prompt.args" "$FAKE/prompt.stdin"

# --- 3. an answer that is not a task file ---------------------------------------------------------------------

[ "$SABOTAGE" = 1 ] || echo "Sorry, I cannot do that." >"$FAKE/answer"
wbp "$SCRATCH/bad.out" task edit bump --request "skip vendor"
shown "$SCRATCH/bad.out" 3
check "an answer that is not a task file: exit 1" "exit $RC" test "$RC" = 1
check "it says nothing was written" "no such line" grep -q "Nothing was written" "$SCRATCH/bad.out"
check "the task file is still byte-identical" "task.md changed" cmp -s "$SCRATCH/task.before" "$TASK"

# --- 4. --accept writes it, and an approval no longer holds ---------------------------------------------------

printf -- "$GOOD" >"$FAKE/answer"
wbp "$SCRATCH/approve.out" task approve bump
check "the task is approved" "task approve exited $RC" test "$RC" = 0
wbp "$SCRATCH/list1.out" task list
check "task list shows it approved" "no such state" grep -qi "approved" "$SCRATCH/list1.out"
ACCEPT=--accept
[ "$SABOTAGE" = 1 ] && ACCEPT=
wbp "$SCRATCH/accept.out" task edit bump --request "allow three dollars and skip the vendor folder" $ACCEPT
shown "$SCRATCH/accept.out" 14
check "--accept: exit 0" "exit $RC" test "$RC" = 0
check "the file now holds the new budget and instruction" "task.md not rewritten" \
    bash -c 'grep -q "^budget: 3" "$1" && grep -q "Skip the vendor folder." "$1"' _ "$TASK"
wbp "$SCRATCH/list2.out" task list
shown "$SCRATCH/list2.out" 4
check "accepting did not approve: the task reads stale" "task list does not say stale" grep -qi "stale" "$SCRATCH/list2.out"
finish
