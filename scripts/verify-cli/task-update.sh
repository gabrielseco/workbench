#!/bin/bash
# verify-cli scenario for a `fix: update` task: it brings main into a pull request's own branch and pushes to it. A clone of this
# repository whose origin is a bare copy in the temp folder, a `claude` stand-in that runs the fake-claude test double and a `gh`
# stand-in that knows one open pull request. Nothing real is contacted and no real turn runs, so it costs nothing.
#   bash scripts/verify-cli/task-update.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/task-update.sh   (the same, on a branch that contains origin/main)
# Origin has `feature/pr`, one commit off main, and main then moves by a commit to a file the branch never touched. `task run`
# must end pr-opened with "updated feature/pr with origin/main", the branch on origin must then hold main's new commit and the
# commit it had, origin must hold no `workbench/` branch (the thread's own branch is never pushed) and `gh pr create` must not
# have been called. A second pull request whose branch and main both changed the same file, with an agent that resolves
# nothing, must end needs-you (exit 0) naming the file, with the branch on origin where it was. The same unit is not offered
# again for the same main (nothing-pending).
# A third pull request whose conflict the agent resolves to exactly the branch's own content (a tree equal to the branch's) must still
# land main's history on the branch: pr-opened, and the branch on origin holds main's new commit. A task that mixes `fix: update` with `labels` or `batch: 2` must be refused.
# VERIFY_CLI_SABOTAGE=1 makes the stand-in agent also write a file main never touched: "the update is pushed", "the branch on
# origin holds main's new commit and the commit it had" and "the same unit is not offered again" must FAIL, because the guard refuses a resolution that went past what main changed.
# Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start (nothing changed).
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

# The agent: it resolves nothing. Sabotaged, it also writes a file that main never touched.
WRITE=""
[ "$SABOTAGE" = 1 ] && WRITE="write=update-probe.txt"
cat >"$BIN/claude" <<STUB
#!/bin/sh
R=""; [ -f "$SCRATCH/resolve" ] && R="resolve=keep.txt"
FAKE_CLAUDE=\$R\${R:+,}$WRITE exec '$FAKE' "\$@"
STUB
# A gh that is logged in and knows the open pull requests of feature/pr and feature/clash.
cat >"$BIN/gh" <<STUB
#!/bin/sh
echo "\$@" >>"$GHDIR/calls"
head=""; prev=""
for a in "\$@"; do [ "\$prev" = "--head" ] && head=\$a; prev=\$a; done
case "\$1 \$2" in
"auth status") exit 0 ;;
"pr list")
    case "\$head" in
    feature/pr) echo '[{"number":1,"url":"https://github.com/o/r/pull/1","headRefName":"feature/pr","baseRefName":"main","title":"t","body":"b"}]' ;;
    feature/keep) echo '[{"number":3,"url":"https://github.com/o/r/pull/3","headRefName":"feature/keep","baseRefName":"main","title":"t","body":"b"}]' ;;
    feature/clash) echo '[{"number":2,"url":"https://github.com/o/r/pull/2","headRefName":"feature/clash","baseRefName":"main","title":"t","body":"b"}]' ;;
    *) echo '[]' ;;
    esac
    exit 0 ;;
esac
echo "verify-cli stand-in gh: \$*" >&2
exit 2
STUB
chmod +x "$BIN/claude" "$BIN/gh"
[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the stand-in agent also writes a file main never touched"
echo "==> clone at $P, stand-ins in $BIN"

# Two branches on origin, each one commit off main, then main moves.
W="$SCRATCH/work"
g clone -q "$ORIGIN" "$W" || die "git clone for the setup failed"
g -C "$W" config user.email t@example.com; g -C "$W" config user.name t
g -C "$W" checkout -q -b feature/pr origin/main && echo "pr work" >"$W/pr-work.txt" && g -C "$W" add pr-work.txt && g -C "$W" commit -q -m "pr work" \
    && g -C "$W" push -q origin feature/pr || die "could not make feature/pr"
g -C "$W" checkout -q -b feature/clash origin/main && echo "branch side" >"$W/clash.txt" && g -C "$W" add clash.txt && g -C "$W" commit -q -m "clash on the branch" \
    && g -C "$W" push -q origin feature/clash || die "could not make feature/clash"
g -C "$W" checkout -q -b feature/keep origin/main && echo "keep side" >"$W/keep.txt" && g -C "$W" add keep.txt && g -C "$W" commit -q -m "keep on the branch" \
    && g -C "$W" push -q origin feature/keep || die "could not make feature/keep"
g -C "$W" checkout -q main && echo "main side" >"$W/clash.txt" && echo "main keep" >"$W/keep.txt" && echo "from main" >"$W/from-main.txt" \
    && g -C "$W" add clash.txt keep.txt from-main.txt \
    && g -C "$W" commit -q -m "main moves" && g -C "$W" push -q origin main || die "could not move main"
MAIN_TIP=$(g -C "$ORIGIN" rev-parse refs/heads/main)
PR_BEFORE=$(g -C "$ORIGIN" rev-parse refs/heads/feature/pr)
CLASH_BEFORE=$(g -C "$ORIGIN" rev-parse refs/heads/feature/clash)

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

task() { # <name> <front matter lines> <unit json>
    local dir="$P/.workbench/tasks/$1"
    mkdir -p "$dir"
    printf '#!/bin/sh\necho '"'"'%s'"'"'\n' "$3" >"$dir/pending.sh"
    chmod +x "$dir/pending.sh"
    printf -- '---\n%s\npending: .workbench/tasks/%s/pending.sh\n---\nBring main into the pull request.\n' "$2" "$1" >"$dir/task.md"
}
task sync "fix: update" '[{"id":"1-main","title":"a pull request","branch":"feature/pr"}]'
task keep "fix: update" '[{"id":"3-main","title":"resolved for the branch","branch":"feature/keep"}]'
task clash "fix: update" '[{"id":"2-main","title":"a clashing pull request","branch":"feature/clash"}]'
wbp "$SCRATCH/approve1.out" task approve sync
check "approve warns what an update task does" "exit $RC: $(head -c 300 "$SCRATCH/approve1.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "fix: update" "$2"' _ "$RC" "$SCRATCH/approve1.out"
wbp "$SCRATCH/approve2.out" task approve clash
wbp "$SCRATCH/approve3.out" task approve keep

# --- 1. a clean merge --------------------------------------------------------------------------------------

wbp "$SCRATCH/run1.out" task run sync; shown "$SCRATCH/run1.out"
check "the update is pushed" "exit $RC: $(head -c 400 "$SCRATCH/run1.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "^sync: pr-opened" "$2" && grep -q "updated feature/pr with origin/main" "$2" && grep -q "pull request: https://github.com/o/r/pull/1" "$2"' _ "$RC" "$SCRATCH/run1.out"
check "the branch on origin holds main's new commit and the commit it had" "main $MAIN_TIP, branch was $PR_BEFORE" \
    bash -c 'git -C "$1" merge-base --is-ancestor "$2" refs/heads/feature/pr && git -C "$1" merge-base --is-ancestor "$3" refs/heads/feature/pr' _ "$ORIGIN" "$MAIN_TIP" "$PR_BEFORE"
check "origin has no workbench/ branch and no pull request was created" "branches: $(g -C "$ORIGIN" for-each-ref --format='%(refname)' refs/heads | tr '\n' ' ')" \
    bash -c '! git -C "$1" for-each-ref --format="%(refname)" refs/heads | grep -q "refs/heads/workbench/" && ! grep -q "pr create" "$2"' _ "$ORIGIN" "$GHDIR/calls"
wbp "$SCRATCH/run1b.out" task run sync
check "the same unit is not offered again for the same main" "exit $RC: $(head -c 300 "$SCRATCH/run1b.out")" \
    bash -c 'grep -q "nothing-pending" "$1"' _ "$SCRATCH/run1b.out"

# --- 2. a conflict the agent leaves ----------------------------------------------------------------------

wbp "$SCRATCH/run2.out" task run clash; shown "$SCRATCH/run2.out"
check "a conflict left open ends needs-you and names the file" "exit $RC: $(head -c 400 "$SCRATCH/run2.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "^clash: needs-you" "$2" && grep -q "clash.txt" "$2"' _ "$RC" "$SCRATCH/run2.out"
check "the branch on origin is where it was" "was $CLASH_BEFORE, now $(g -C "$ORIGIN" rev-parse refs/heads/feature/clash)" \
    test "$(g -C "$ORIGIN" rev-parse refs/heads/feature/clash)" = "$CLASH_BEFORE"

# --- 3. a conflict resolved to the branch's own content --------------------------------------------------

touch "$SCRATCH/resolve"
wbp "$SCRATCH/run3.out" task run keep; shown "$SCRATCH/run3.out"
rm -f "$SCRATCH/resolve"
check "a resolution equal to the branch's tree is pushed and carries main's history" "exit $RC: $(head -c 400 "$SCRATCH/run3.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "^keep: pr-opened" "$2" && git -C "$3" merge-base --is-ancestor "$4" refs/heads/feature/keep' _ "$RC" "$SCRATCH/run3.out" "$ORIGIN" "$MAIN_TIP"

# --- 4. what the task file may say -----------------------------------------------------------------------

task bad "fix: update
batch: 2
labels: [x]" '[]'
wbp "$SCRATCH/bad.out" task approve bad
check "a task that mixes fix: update with labels or batch 2 is refused" "exit $RC: $(head -c 300 "$SCRATCH/bad.out")" \
    bash -c '[ "$1" != 0 ] && grep -q "labels" "$2" && grep -q "batch" "$2"' _ "$RC" "$SCRATCH/bad.out"

finish
