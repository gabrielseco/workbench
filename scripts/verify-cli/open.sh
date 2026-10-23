#!/bin/bash
# verify-cli scenario for `workbench open`: a thread's worktree opened in an editor, or its path printed. On a clone of
# this repository in the temp folder, with a HOME of its own (for ~/.workbench/config.toml) and no real editor: a fake
# `zed` and a fake custom command on PATH write the arguments they get to a file. No turn is run, so it costs nothing.
#   bash scripts/verify-cli/open.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/open.sh   (the same, on a branch that contains origin/main)
# Steps: with no editor set `open` exits 6, says what to do and launches nothing; `--print` prints only the worktree path
# and launches nothing; `--print --editor` exits 2; `--editor zed` and a named thread open the worktree (`opened <path> in
# zed`, the launcher got the path); `editor` in the global config is used, the project's wins over it and `--editor` over
# both; a thread whose worktree is gone exits 6 and an unknown id 7, launching nothing; `--goal` opens that same
# thread's goal.md anyway (`--print --goal` prints its path). Exit 0 only when every step
# passed, 1 when one failed, 2 when it refused to start (nothing changed). VERIFY_CLI_SABOTAGE=1 sets `editor` in the
# global config before the first step, so the steps that expect "no editor set" (exit 6, the message, nothing launched)
# must FAIL, and deletes the thread's goal.md before the `--goal` steps, so those must FAIL too. The frame is in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

P="$SCRATCH/project"
FAKE_HOME="$SCRATCH/home"
BIN="$SCRATCH/bin"
OPENED="$SCRATCH/opened.txt"
g clone -q "$ROOT" "$P" || die "git clone failed"
g -C "$P" checkout -q -B main "$BASE_SHA" || die "could not check out main in the clone"
mkdir -p "$FAKE_HOME/.workbench" "$BIN" || die "could not make the scratch folders"
for name in zed rec; do
    printf '#!/bin/sh\nfor a in "$@"; do echo "$a"; done > "%s"\n' "$OPENED" >"$BIN/$name"
    chmod +x "$BIN/$name"
done
echo "==> clone at $P, HOME $FAKE_HOME, fake editors in $BIN"

RC=0
wbp() { # <out> args...: a workbench command in the clone, stdout and stderr apart; sets RC
    local o=$1; shift
    echo "workbench $*   (in the clone)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    rm -f "$OPENED"
    ( cd "$P" && export HOME="$FAKE_HOME" PATH="$BIN:$PATH" && with_timeout "$T_WB" "$WB" "$@" >"$o" 2>"$o.err" )
    RC=$?
}
shown() { cat "$1" "$1.err" | sed 's/^/    /' | head -${2:-6}; }
launched_nothing() { test ! -e "$OPENED"; }
launched_with() { test -e "$OPENED" && test "$(cat "$OPENED")" = "$1"; }

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
wbp "$SCRATCH/new.out" goal new open-probe
check "goal new: exit 0" "workbench goal new exited $RC" test "$RC" = 0
ID=$(sed -n 's/^created //p' "$SCRATCH/new.out")
# No turn: the thread's worktree and branch are made here, as a run would.
g -C "$P" worktree add -q -b "workbench/$ID" "$P/.workbench/worktrees/$ID" main || die "could not add the thread's worktree"
# The path as the project spells it, with doubled slashes removed (a TMPDIR ending in "/" makes them), which is what `open`
# prints and passes on: it resolves symlinks only to check the path, not to print it.
WTP=$(cd "$P/.workbench/worktrees/$ID" && pwd)

# --- c2: no editor set, and c5: --print -----------------------------------------------------------------------

if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: the global config sets editor before the 'no editor set' steps"
    echo 'editor = "zed"' >"$FAKE_HOME/.workbench/config.toml"
fi
wbp "$SCRATCH/none.out" open
shown "$SCRATCH/none.out"
check "no editor set: exit 6 (refused)" "workbench open exited $RC" test "$RC" = 6
check "the refusal says to pass --editor, set editor or use --print" "the message lacks one of them" \
    bash -c 'grep -q -- "--editor" "$1" && grep -q "editor" "$1" && grep -q -- "--print" "$1"' _ "$SCRATCH/none.out.err"
check "no editor set: nothing was launched" "the fake editor ran" launched_nothing
rm -f "$FAKE_HOME/.workbench/config.toml"

wbp "$SCRATCH/print.out" open --print
check "--print: exit 0 and only the worktree path" "exit $RC, printed: $(head -c 300 "$SCRATCH/print.out")" \
    bash -c 'test "$1" = 0 && test "$(cat "$2")" = "$3"' _ "$RC" "$SCRATCH/print.out" "$WTP"
check "--print: nothing was launched" "the fake editor ran" launched_nothing
wbp "$SCRATCH/both.out" open --print --editor zed
check "--print with --editor: exit 2 (usage)" "workbench open exited $RC" test "$RC" = 2

# --- c1: open the active and a named thread --------------------------------------------------------------------

wbp "$SCRATCH/flag.out" open --editor zed
shown "$SCRATCH/flag.out"
check "open --editor zed: exit 0, 'opened <path> in zed'" "exit $RC, printed: $(head -c 300 "$SCRATCH/flag.out")" \
    bash -c 'test "$1" = 0 && test "$(cat "$2")" = "opened $3 in zed"' _ "$RC" "$SCRATCH/flag.out" "$WTP"
check "the launcher got the worktree path" "it got: $(cat "$OPENED" 2>/dev/null)" launched_with "$WTP"
wbp "$SCRATCH/named.out" open "$ID" --editor "rec --new-window"
check "open <id> with a custom command: exit 0" "workbench open exited $RC" test "$RC" = 0
check "the custom command got its argument, then the path" "it got: $(cat "$OPENED" 2>/dev/null)" \
    launched_with "$(printf -- '--new-window\n%s' "$WTP")"

# --- c2: the global config, then the project's ------------------------------------------------------------------

echo 'editor = "rec --from-global"' >"$FAKE_HOME/.workbench/config.toml"
wbp "$SCRATCH/global.out" open
check "editor in ~/.workbench/config.toml is used" "exit $RC, it got: $(cat "$OPENED" 2>/dev/null)" \
    launched_with "$(printf -- '--from-global\n%s' "$WTP")"
{ echo 'editor = "zed"'; cat "$P/.workbench/config.toml"; } >"$SCRATCH/config.toml" && cp "$SCRATCH/config.toml" "$P/.workbench/config.toml"
wbp "$SCRATCH/project.out" open
check "the project's editor wins over the global one" "exit $RC, printed: $(head -c 300 "$SCRATCH/project.out")" \
    bash -c 'test "$1" = 0 && grep -q " in zed$" "$2"' _ "$RC" "$SCRATCH/project.out"
wbp "$SCRATCH/over.out" open --editor "rec --from-flag"
check "--editor wins over both" "it got: $(cat "$OPENED" 2>/dev/null)" launched_with "$(printf -- '--from-flag\n%s' "$WTP")"

# --- c1: refusals ------------------------------------------------------------------------------------------------

wbp "$SCRATCH/unknown.out" open g-2000-01-01-nope --editor zed
check "an unknown thread: exit 7 (not found), nothing launched" "exit $RC" \
    bash -c 'test "$1" = 7 && test ! -e "$2"' _ "$RC" "$OPENED"
g -C "$P" worktree remove --force "$P/.workbench/worktrees/$ID" || die "could not remove the thread's worktree"
wbp "$SCRATCH/gone.out" open --editor zed
shown "$SCRATCH/gone.out"
check "a thread whose worktree is gone: exit 6 (refused) with the reason" "exit $RC" \
    bash -c 'test "$1" = 6 && grep -q "has no worktree" "$2"' _ "$RC" "$SCRATCH/gone.out.err"
check "a thread whose worktree is gone: nothing launched" "the fake editor ran" launched_nothing
check "the refusal points to --goal" "the message lacks --goal" grep -q -- "--goal" "$SCRATCH/gone.out.err"

# --- --goal: the goal file, which needs no worktree ----------------------------------------------------------------

GOAL="$(cd "$P/.workbench/threads/$ID" && pwd)/goal.md"
if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: the goal file is deleted before the --goal steps"
    rm -f "$GOAL"
fi
wbp "$SCRATCH/goalprint.out" open --goal --print
check "--goal --print: exit 0 and only the goal file's path" "exit $RC, printed: $(head -c 300 "$SCRATCH/goalprint.out")" \
    bash -c 'test "$1" = 0 && test "$(cat "$2")" = "$3"' _ "$RC" "$SCRATCH/goalprint.out" "$GOAL"
wbp "$SCRATCH/goal.out" open "$ID" --goal --editor zed
shown "$SCRATCH/goal.out"
check "--goal with no worktree: exit 0, 'opened <goal.md> in zed'" "exit $RC, printed: $(head -c 300 "$SCRATCH/goal.out")" \
    bash -c 'test "$1" = 0 && test "$(cat "$2")" = "opened $3 in zed"' _ "$RC" "$SCRATCH/goal.out" "$GOAL"
check "the launcher got the goal file's path" "it got: $(cat "$OPENED" 2>/dev/null)" launched_with "$GOAL"
finish
