#!/bin/bash
# verify-cli scenario for `workbench explain-pr`, on a clone of this repository whose origin is a bare copy in the temp folder.
# `gh` and `codex` are stand-ins on PATH and in [providers.codex]: no agent runs, so it costs nothing.
#   bash scripts/verify-cli/explain-pr.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/explain-pr.sh   (the same, on a branch that contains origin/main)
# Pull request #7 is a branch pushed to that origin. Steps: the first explain exits 0 and its last stdout line is the absolute
# path of .workbench/explains/pr-7-<head7>.md; the file is the body only (the stand-in's front matter dropped); codex ran
# read-only in the throwaway checkout; the clone, its branches and origin are as they were and no checkout is left; gh was
# only asked to read; a second run reuses the file without running codex; --again runs it; --out writes there and prints that
# path; a moved head is explained afresh into its own file; an empty answer exits 1 and prints no path; no --pr and a
# non-numeric --pr exit 2; help names the command. The output contract is docs/plan/explain-pr.md.
# VERIFY_CLI_SABOTAGE=1 rewrites the first run's output after it ran (front matter put back in the file, the path line dropped
# from stdout), so "last stdout line is the absolute path" and "the file is the body only" must FAIL.
# Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the first run's file and stdout are rewritten after it ran"

# Without a doubled slash (TMPDIR often ends in one), as workbench prints a path.
SCRATCH=$(printf '%s' "$SCRATCH" | tr -s /)
P="$SCRATCH/project"
BARE="$SCRATCH/origin.git"
BIN="$SCRATCH/bin"
mkdir -p "$BIN"
g clone -q --bare "$ROOT" "$BARE" || die "git clone --bare failed"
g clone -q "$BARE" "$P" || die "git clone failed"
echo "==> clone at $P, origin $BARE"

# Pull request #7: one commit on a branch of its own, on origin, based on the branch the clone starts on (main, or the branch
# under test when run from one).
START=$(g -C "$P" rev-parse --abbrev-ref HEAD) || die "no branch checked out in the clone"
g -C "$P" checkout -q -b explain/probe || die "git checkout failed"
echo "explain-pr probe" >"$P/explain-probe.txt"
g -C "$P" add explain-probe.txt && g -C "$P" -c user.name=verify -c user.email=verify@example.com commit -q -m "probe" \
    || die "git commit failed"
g -C "$P" push -q origin explain/probe || die "git push failed"
g -C "$P" checkout -q "$START" || die "git checkout $START failed"
HEAD7=$(g -C "$P" rev-parse --short=7 explain/probe)

cat >"$BIN/gh" <<EOF
#!/bin/sh
echo "\$@" >> "$SCRATCH/gh.calls"
cat <<'JSON'
{"headRefName":"explain/probe","baseRefName":"$START","title":"probe: add a file","body":"Adds explain-probe.txt.","state":"OPEN","isCrossRepository":false}
JSON
EOF
# The stand-in codex writes $SCRATCH/answer (if any) to the -o file, and keeps its argv and working directory.
cat >"$BIN/codex" <<EOF
#!/bin/sh
echo "\$@" >> "$SCRATCH/codex.calls"
pwd -P >> "$SCRATCH/codex.cwds"
out=""; prev=""
for a in "\$@"; do [ "\$prev" = "-o" ] && out="\$a"; prev="\$a"; done
[ -f "$SCRATCH/answer" ] && [ -n "\$out" ] && cat "$SCRATCH/answer" > "\$out"
exit 0
EOF
chmod +x "$BIN/gh" "$BIN/codex"
printf -- '---\ntitle: from the agent\n---\n\n# Probe\n\nAdds a file.\n\n' >"$SCRATCH/answer"
printf '# Probe\n\nAdds a file.\n' >"$SCRATCH/body.expected"

RC=0
wbp() { # <out> args...: a workbench command in the clone with the stand-ins first on PATH; stdout in <out>, stderr in <out>.err
    local o=$1; shift
    echo "workbench $*   (in the clone)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    ( cd "$P" && PATH="$BIN:$PATH" with_timeout "$T_WB" "$WB" "$@" >"$o" 2>"$o.err" )
    RC=$?
}
shown() { sed 's/^/    /' "$1" | head -${2:-6}; }
runs() { [ -f "$SCRATCH/codex.calls" ] && wc -l <"$SCRATCH/codex.calls" | tr -d ' ' || echo 0; }
state() { # branches and tips here and on origin, HEAD, the working tree and the registered checkouts
    g -C "$P" for-each-ref --format='%(refname) %(objectname)' refs/heads
    g -C "$BARE" for-each-ref --format='%(refname) %(objectname)'
    g -C "$P" rev-parse HEAD
    g -C "$P" status --porcelain --untracked-files=all
    g -C "$P" worktree list --porcelain
}

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
printf '\n[providers.codex]\nexecutable = "%s"\n' "$BIN/codex" >>"$P/.workbench/config.toml"
state >"$SCRATCH/state.before"

KEPT="$P/.workbench/explains/pr-7-$HEAD7.md"
wbp "$SCRATCH/first.out" explain-pr --pr 7
shown "$SCRATCH/first.out"; shown "$SCRATCH/first.out.err"
if [ "$SABOTAGE" = 1 ]; then
    printf -- '---\ntitle: x\n---\n' | cat - "$KEPT" >"$SCRATCH/k" && mv "$SCRATCH/k" "$KEPT"
    sed '$d' "$SCRATCH/first.out" >"$SCRATCH/k" && mv "$SCRATCH/k" "$SCRATCH/first.out"
fi
check "explain-pr --pr 7 exits 0" "exit $RC: $(cat "$SCRATCH/first.out.err")" test "$RC" = 0
check "the last stdout line is the absolute path of .workbench/explains/pr-7-$HEAD7.md" \
    "last line: $(tail -1 "$SCRATCH/first.out")" test "$(tail -1 "$SCRATCH/first.out")" = "$KEPT"
check "the file is the body only: the agent's front matter dropped, trimmed, one final newline" \
    "file: $(head -3 "$KEPT" 2>/dev/null | tr '\n' '|')" cmp -s "$KEPT" "$SCRATCH/body.expected"
check "codex ran once, read-only (-s read-only)" "calls: $(cat "$SCRATCH/codex.calls" 2>/dev/null)" \
    sh -c "[ $(runs) = 1 ] && grep -q '^exec -s read-only ' '$SCRATCH/codex.calls'"
check "codex ran in the throwaway checkout under .workbench/explains/" "cwd: $(cat "$SCRATCH/codex.cwds" 2>/dev/null)" \
    grep -q "/.workbench/explains/pr-7-$HEAD7/round-1.tree\$" "$SCRATCH/codex.cwds"
state >"$SCRATCH/state.after"
check "the clone, its branches, origin and the worktree list are as they were (no checkout left)" \
    "$(diff "$SCRATCH/state.before" "$SCRATCH/state.after" | head -5 | tr '\n' '|')" \
    cmp -s "$SCRATCH/state.before" "$SCRATCH/state.after"
check "gh was only asked to read the pull request" "calls: $(cat "$SCRATCH/gh.calls" 2>/dev/null | tr '\n' '|')" \
    sh -c "! grep -v '^pr view 7 --json ' '$SCRATCH/gh.calls'"

wbp "$SCRATCH/second.out" explain-pr --pr 7
check "an unmoved head reuses the file: exit 0, the same path, codex not run" "exit $RC, runs $(runs)" \
    sh -c "[ $RC = 0 ] && [ \"\$(tail -1 '$SCRATCH/second.out')\" = '$KEPT' ] && [ $(runs) = 1 ]"

printf '# Again\n\nAsked once more.\n' >"$SCRATCH/answer"
wbp "$SCRATCH/again.out" explain-pr --pr 7 --again
check "--again runs codex once more and replaces the file" "exit $RC, runs $(runs)" \
    sh -c "[ $RC = 0 ] && [ $(runs) = 2 ] && grep -q '^# Again' '$KEPT'"

NOTE="$SCRATCH/note.md"
wbp "$SCRATCH/out.out" explain-pr --pr 7 --out "$NOTE"
check "--out writes there and its path is the last stdout line" "exit $RC, last: $(tail -1 "$SCRATCH/out.out")" \
    sh -c "[ $RC = 0 ] && [ \"\$(tail -1 '$SCRATCH/out.out')\" = '$NOTE' ] && cmp -s '$NOTE' '$KEPT'"

g -C "$P" checkout -q explain/probe && echo more >>"$P/explain-probe.txt" \
    && g -C "$P" -c user.name=verify -c user.email=verify@example.com commit -q -am "move" \
    && g -C "$P" push -q origin explain/probe && g -C "$P" checkout -q "$START" || die "moving the branch failed"
MOVED7=$(g -C "$P" rev-parse --short=7 explain/probe)
wbp "$SCRATCH/moved.out" explain-pr --pr 7
check "a moved head is explained afresh into pr-7-$MOVED7.md" "exit $RC, runs $(runs), last: $(tail -1 "$SCRATCH/moved.out")" \
    sh -c "[ $RC = 0 ] && [ $(runs) = 3 ] && [ \"\$(tail -1 '$SCRATCH/moved.out')\" = '$P/.workbench/explains/pr-7-$MOVED7.md' ]"

printf '   \n\n' >"$SCRATCH/answer"
wbp "$SCRATCH/empty.out" explain-pr --pr 7 --again
shown "$SCRATCH/empty.out.err"
check "an empty answer exits 1, says so and prints no path" "exit $RC, stdout: $(tr '\n' '|' <"$SCRATCH/empty.out")" \
    sh -c "[ $RC = 1 ] && grep -q 'no explanation of pull request #7' '$SCRATCH/empty.out.err' && ! grep -q '^/' '$SCRATCH/empty.out'"

wbp "$SCRATCH/nopr.out" explain-pr
check "no --pr exits 2 (usage)" "exit $RC: $(cat "$SCRATCH/nopr.out.err")" test "$RC" = 2
wbp "$SCRATCH/word.out" explain-pr --pr seven
check "a --pr that is not a number exits 2 (usage)" "exit $RC: $(cat "$SCRATCH/word.out.err")" test "$RC" = 2
wbp "$SCRATCH/help.out" help explain-pr
check "help explain-pr shows the synopsis" "exit $RC" \
    sh -c "[ $RC = 0 ] && grep -q 'explain-pr --pr <n> \[--out <file>\] \[--spec <file>\] \[--again\]' '$SCRATCH/help.out'"

finish
