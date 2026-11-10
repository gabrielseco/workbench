#!/bin/bash
# verify-cli scenario for `workbench explain-thread`, on a clone of this repository whose origin is a bare copy in the temp folder.
# `gh` and `codex` are stand-ins on PATH and in [providers.codex]: no agent runs, so it costs nothing.
#   bash scripts/verify-cli/explain-thread.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/explain-thread.sh   (the same, on a branch that contains origin/main)
# Pull request #7 is a branch pushed to that origin whose head adds a 40-line file; review thread PRRT_probe1 is on its line 20.
# Steps: run from a subfolder of the clone, explain-thread exits 0 and its last stdout line is a JSON object with non-empty
# reasoning and proposed_fix; codex ran once, read-only, in the throwaway checkout; the brief has the title, both comments in
# order and line 20 marked; the clone, origin and worktrees are as they were; gh only read (pr view, api graphql, no
# mutation); an empty answer and one without proposed_fix exit 1 (workbench: failed:) with no object; an unknown thread, a
# thread on another pull request and a closed pull request exit 6 (workbench: refused:); no --thread exits 2; help lists it;
# an answer with a line of prose before the object is accepted; while one thread is being explained (the stand-in codex sleeps), a
# second thread is explained and exits 0, and the same thread again exits 6 (refused: busy), then the first finishes with 0.
# The output contract is docs/plan/explain-thread.md.
# VERIFY_CLI_SABOTAGE=1 rewrites the first run's output after it ran (the object line dropped from stdout, the thread taken out
# of the brief), so "the last stdout line is a JSON object ..." and "the brief has ..." must FAIL; it also drops the object from the
# second thread's output, so "a second thread is explained while the first runs" must FAIL.
# Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the first run's stdout and brief are rewritten after it ran"

SCRATCH=$(printf '%s' "$SCRATCH" | tr -s /)
P="$SCRATCH/project"
BARE="$SCRATCH/origin.git"
BIN="$SCRATCH/bin"
mkdir -p "$BIN"
g clone -q --bare "$ROOT" "$BARE" || die "git clone --bare failed"
g clone -q "$BARE" "$P" || die "git clone failed"
echo "==> clone at $P, origin $BARE"

START=$(g -C "$P" rev-parse --abbrev-ref HEAD) || die "no branch checked out in the clone"
g -C "$P" checkout -q -b thread/probe || die "git checkout failed"
mkdir -p "$P/probe"
for i in $(seq 1 40); do echo "probe line $i"; done >"$P/probe/calc.txt"
g -C "$P" add probe/calc.txt && g -C "$P" -c user.name=verify -c user.email=verify@example.com commit -q -m "probe" \
    || die "git commit failed"
g -C "$P" push -q origin thread/probe || die "git push failed"
g -C "$P" checkout -q "$START" || die "git checkout $START failed"
HEAD_SHA=$(g -C "$P" rev-parse thread/probe)

pr_json() { # <state>
    printf '{"headRefName":"thread/probe","baseRefName":"%s","title":"probe: add calc.txt","body":"Adds a file.","state":"%s","isCrossRepository":false}\n' \
        "$START" "$1" >"$SCRATCH/pr.json"
}
thread_json() { # <pr number>
    cat >"$SCRATCH/thread.json" <<JSON
{"data":{"node":{"__typename":"PullRequestReviewThread","isOutdated":false,"isResolved":false,"path":"probe/calc.txt","line":20,"originalLine":20,"startLine":null,"originalStartLine":null,"pullRequest":{"number":$1,"repository":{"nameWithOwner":"o/n"}},"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"author":{"login":"ana"},"body":"COMMENT-ONE: line 20 is off by one.","createdAt":"2026-11-01T10:00:00Z","diffHunk":"@@ -0,0 +1,20 @@","outdated":false},{"author":{"login":"bo"},"body":"COMMENT-TWO: agreed.","createdAt":"2026-11-01T11:00:00Z","diffHunk":"@@ -0,0 +1,20 @@","outdated":false}]}}}}
JSON
}
pr_json OPEN
thread_json 7

# The stand-in gh: one line per call in gh.calls; `pr view` answers pr.json, `api graphql` thread.json or fails with thread.fail.
cat >"$BIN/gh" <<EOF
#!/bin/sh
printf '%s|' "\$@" | tr '\n' ' ' >> "$SCRATCH/gh.calls"; echo >> "$SCRATCH/gh.calls"
case "\$1" in
  pr) cat "$SCRATCH/pr.json" ;;
  api) if [ -f "$SCRATCH/thread.fail" ]; then cat "$SCRATCH/thread.fail" >&2; exit 1; fi; cat "$SCRATCH/thread.json" ;;
  *) exit 9 ;;
esac
EOF
# The stand-in codex writes $SCRATCH/answer (if any) to the -o file, keeps its argv, its working directory and the brief.
cat >"$BIN/codex" <<EOF
#!/bin/sh
echo "\$@" >> "$SCRATCH/codex.calls"
pwd -P >> "$SCRATCH/codex.cwds"
cp "\$(pwd -P)/../round-1.brief.md" "$SCRATCH/brief.md" 2>/dev/null
case "\$(pwd -P)" in *thread-PRRT_probe1/*) [ -f "$SCRATCH/slow" ] && { : > "$SCRATCH/slow.started"; sleep 8; } ;; esac
out=""; prev=""
for a in "\$@"; do [ "\$prev" = "-o" ] && out="\$a"; prev="\$a"; done
[ -f "$SCRATCH/answer" ] && [ -n "\$out" ] && cat "$SCRATCH/answer" > "\$out"
exit 0
EOF
chmod +x "$BIN/gh" "$BIN/codex"
printf '{"reasoning":"Line 20 is off by one.","proposed_fix":"Count from 0."}\n' >"$SCRATCH/answer"

RC=0
wbp() { # <out> <folder> args...: a workbench command with the stand-ins first on PATH; stdout in <out>, stderr in <out>.err
    local o=$1 dir=$2; shift 2
    echo "workbench $*   (in $dir)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in $dir)" >&2
    ( cd "$dir" && PATH="$BIN:$PATH" with_timeout "$T_WB" "$WB" "$@" >"$o" 2>"$o.err" )
    RC=$?
}
shown() { sed 's/^/    /' "$1" | head -${2:-6}; }
runs() { [ -f "$SCRATCH/codex.calls" ] && wc -l <"$SCRATCH/codex.calls" | tr -d ' ' || echo 0; }
state() {
    g -C "$P" for-each-ref --format='%(refname) %(objectname)' refs/heads
    g -C "$BARE" for-each-ref --format='%(refname) %(objectname)'
    g -C "$P" rev-parse HEAD
    g -C "$P" status --porcelain --untracked-files=all
    g -C "$P" worktree list --porcelain
}
# The last line of <file> is a JSON object with non-empty `reasoning` and `proposed_fix` strings, of the head <sha>.
is_answer() {
    tail -1 "$1" | py "ok=isinstance(d,dict) and all(isinstance(d.get(k),str) and d[k].strip() for k in ('reasoning','proposed_fix'))
sys.exit(0 if ok and d.get('head_sha')=='$2' else 1)"
}
# The brief has the title, both comments in that order, and line 20 marked.
brief_ok() {
    py "t=raw
i=[t.find(s) for s in ('probe: add calc.txt','COMMENT-ONE','COMMENT-TWO','> 20 | probe line 20')]
sys.exit(0 if all(x>=0 for x in i) and i==sorted(i) else 1)" <"$SCRATCH/brief.md"
}

wbp "$SCRATCH/init.out" "$P" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
printf '\n[providers.codex]\nexecutable = "%s"\n' "$BIN/codex" >>"$P/.workbench/config.toml"
state >"$SCRATCH/state.before"

ARGS=(explain-thread --pr 7 --thread PRRT_probe1)
wbp "$SCRATCH/first.out" "$P/docs" "${ARGS[@]}"
shown "$SCRATCH/first.out"; shown "$SCRATCH/first.out.err"
if [ "$SABOTAGE" = 1 ]; then
    sed '$d' "$SCRATCH/first.out" >"$SCRATCH/k" && mv "$SCRATCH/k" "$SCRATCH/first.out"
    grep -v 'COMMENT-' "$SCRATCH/brief.md" >"$SCRATCH/k" && mv "$SCRATCH/k" "$SCRATCH/brief.md"
fi
check "explain-thread exits 0, run from a subfolder of the clone (docs/)" "exit $RC: $(cat "$SCRATCH/first.out.err")" \
    test "$RC" = 0
check "the last stdout line is a JSON object with non-empty reasoning and proposed_fix, of the head" \
    "last line: $(tail -1 "$SCRATCH/first.out")" is_answer "$SCRATCH/first.out" "$HEAD_SHA"
check "codex ran once, read-only (-s read-only), in the throwaway checkout under .workbench/explains/" \
    "calls: $(cat "$SCRATCH/codex.calls" 2>/dev/null); cwd: $(cat "$SCRATCH/codex.cwds" 2>/dev/null)" \
    sh -c "[ $(runs) = 1 ] && grep -q '^exec -s read-only ' '$SCRATCH/codex.calls' \
        && grep -q '/.workbench/explains/pr-7-thread-PRRT_probe1/round-1.tree\$' '$SCRATCH/codex.cwds'"
check "the brief has the title, both comments in order and line 20 marked" "brief: $(head -c 300 "$SCRATCH/brief.md" | tr '\n' '|')" \
    brief_ok
state >"$SCRATCH/state.after"
check "the clone, its branches, origin and the worktree list are as they were (no checkout left)" \
    "$(diff "$SCRATCH/state.before" "$SCRATCH/state.after" | head -5 | tr '\n' '|')" \
    cmp -s "$SCRATCH/state.before" "$SCRATCH/state.after"
check "gh was only asked to read: pr view and api graphql, no mutation" "calls: $(cut -c1-60 "$SCRATCH/gh.calls" | tr '\n' '|')" \
    sh -c "! grep -v -e '^pr|view|7|' -e '^api|graphql|' '$SCRATCH/gh.calls' && ! grep -q mutation '$SCRATCH/gh.calls'"

printf '   \n' >"$SCRATCH/answer"
wbp "$SCRATCH/empty.out" "$P" "${ARGS[@]}"
check "an empty answer exits 1 with workbench: failed: and no object" "exit $RC: $(cat "$SCRATCH/empty.out.err")" \
    sh -c "[ $RC = 1 ] && grep -q '^workbench: failed: ' '$SCRATCH/empty.out.err' && ! grep -q '^{' '$SCRATCH/empty.out'"
printf '{"reasoning":"why"}\n' >"$SCRATCH/answer"
wbp "$SCRATCH/half.out" "$P" "${ARGS[@]}"
check "an answer without proposed_fix exits 1 with workbench: failed: and no object" "exit $RC: $(cat "$SCRATCH/half.out.err")" \
    sh -c "[ $RC = 1 ] && grep -q '^workbench: failed: ' '$SCRATCH/half.out.err' && ! grep -q '^{' '$SCRATCH/half.out'"
RAN=$(runs)

printf "GraphQL: Could not resolve to a node with the global id of 'PRRT_nope' (node)\n" >"$SCRATCH/thread.fail"
wbp "$SCRATCH/unknown.out" "$P" explain-thread --pr 7 --thread PRRT_nope
rm -f "$SCRATCH/thread.fail"
check "an unknown thread exits 6 with workbench: refused:" "exit $RC: $(cat "$SCRATCH/unknown.out.err")" \
    sh -c "[ $RC = 6 ] && grep -q '^workbench: refused: ' '$SCRATCH/unknown.out.err'"
thread_json 8
wbp "$SCRATCH/other.out" "$P" "${ARGS[@]}"
thread_json 7
check "a thread on another pull request exits 6 with workbench: refused:" "exit $RC: $(cat "$SCRATCH/other.out.err")" \
    sh -c "[ $RC = 6 ] && grep -q '^workbench: refused: .*pull request #8' '$SCRATCH/other.out.err'"
pr_json CLOSED
wbp "$SCRATCH/closed.out" "$P" "${ARGS[@]}"
pr_json OPEN
check "a closed pull request exits 6 with workbench: refused:" "exit $RC: $(cat "$SCRATCH/closed.out.err")" \
    sh -c "[ $RC = 6 ] && grep -q '^workbench: refused: .*not open' '$SCRATCH/closed.out.err'"
check "no refusal ran codex" "runs $(runs), was $RAN" test "$(runs)" = "$RAN"

# An answer with a line of prose before the object is still the answer.
printf 'I read the files, writing it up.\n\n{"reasoning":"Line 20 is off by one.","proposed_fix":"Count from 0."}\n' >"$SCRATCH/answer"
wbp "$SCRATCH/prose.out" "$P" "${ARGS[@]}"
check "an answer with a line of prose before the object is accepted" "exit $RC: $(cat "$SCRATCH/prose.out.err")" \
    sh -c "[ $RC = 0 ]" && check "... and the last stdout line is the object" "last line: $(tail -1 "$SCRATCH/prose.out")" \
    is_answer "$SCRATCH/prose.out" "$HEAD_SHA"
printf '{"reasoning":"Line 20 is off by one.","proposed_fix":"Count from 0."}\n' >"$SCRATCH/answer"

# Two threads at once: the first is slow (the stand-in codex sleeps), the second must not be refused as busy.
: > "$SCRATCH/slow"
rm -f "$SCRATCH/slow.started" "$SCRATCH/a.rc"
( cd "$P" && PATH="$BIN:$PATH" with_timeout "$T_WB" "$WB" "${ARGS[@]}" >"$SCRATCH/a.out" 2>"$SCRATCH/a.out.err"; echo $? >"$SCRATCH/a.rc" ) &
for _ in $(seq 1 100); do [ -f "$SCRATCH/slow.started" ] && break; sleep 0.2; done
echo "==> thread PRRT_probe1 is being explained; now PRRT_probe2 and PRRT_probe1 again" >&2
wbp "$SCRATCH/b.out" "$P" explain-thread --pr 7 --thread PRRT_probe2
[ "$SABOTAGE" = 1 ] && sed '$d' "$SCRATCH/b.out" >"$SCRATCH/k" && mv "$SCRATCH/k" "$SCRATCH/b.out"
RCB=$RC
wbp "$SCRATCH/again.out" "$P" "${ARGS[@]}"
RCAGAIN=$RC
check "a second thread is explained while the first runs (exit 0, an object)" "exit $RCB: $(cat "$SCRATCH/b.out.err"); last: $(tail -1 "$SCRATCH/b.out")" \
    sh -c "[ $RCB = 0 ] && tail -1 '$SCRATCH/b.out' | grep -q '^{'"
check "the same thread again exits 6 with workbench: refused:" "exit $RCAGAIN: $(cat "$SCRATCH/again.out.err")" \
    sh -c "[ $RCAGAIN = 6 ] && grep -q '^workbench: refused: ' '$SCRATCH/again.out.err'"
wait
rm -f "$SCRATCH/slow"
check "the first thread finished with exit 0 and an object" "exit $(cat "$SCRATCH/a.rc" 2>/dev/null): $(cat "$SCRATCH/a.out.err")" \
    sh -c "[ \"\$(cat '$SCRATCH/a.rc')\" = 0 ] && tail -1 '$SCRATCH/a.out' | grep -q '^{'"
check "no checkout is left by either" "$(g -C "$P" worktree list --porcelain | grep -c round-1.tree) left" \
    sh -c "! git -C '$P' worktree list --porcelain | grep -q round-1.tree"

wbp "$SCRATCH/nothread.out" "$P" explain-thread --pr 7
check "no --thread exits 2 (usage)" "exit $RC: $(cat "$SCRATCH/nothread.out.err")" \
    sh -c "[ $RC = 2 ] && grep -q '^workbench: usage: ' '$SCRATCH/nothread.out.err'"
wbp "$SCRATCH/help.out" "$P" help
check "workbench help lists explain-thread" "exit $RC" \
    sh -c "[ $RC = 0 ] && grep -q '^  explain-thread --pr <n> --thread <id>' '$SCRATCH/help.out'"

finish
