#!/bin/bash
# verify-cli scenario for `workbench goal draft` (P9 PR 14), on a clone of this repository. The goal agent is a fake `codex`
# script the scenario writes, so no real agent is started and it costs nothing.
#   bash scripts/verify-cli/goal-draft.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/goal-draft.sh   (the same, on a branch that contains origin/main)
# With no [agents.goal] the command is refused (exit 6) and says to use `goal new`. With a Codex goal agent and
# `allow_unpriced = false` it is refused before the fake is started, naming the key, and doctor reports the same problem. With no
# `allow_unpriced` (choosing Codex is the consent) doctor notes the draft has no dollar cap and is bounded by its 300 s timeout, an
# answer that is not a goal fails (exit 1) and leaves no thread; a valid one creates a draft thread (never approved,
# its front matter Workbench's own, the log with a goal.draft pair and no coding turn); `--replace` over an approved goal returns
# it to draft and the approval has to be given again.
# Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start. VERIFY_CLI_SABOTAGE=1 writes
# `allow_unpriced = true` in the first config and makes the fake always answer with a valid goal, so the steps that expect the
# refusal and the failed draft must FAIL. The frame and the other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the draft is not forbidden and the fake always answers with a valid goal"

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
shown() { sed 's/^/    /' "$1" | head -${2:-12}; }
cfg="$P/.workbench/config.toml"

# The fake Codex: writes the contents of $FAKE/answer to the file after -o, and counts its runs.
FAKE="$SCRATCH/fake-codex"
mkdir -p "$FAKE"
cat >"$FAKE/codex" <<FAKE_SCRIPT
#!/bin/sh
out=""; prev=""
for a in "\$@"; do [ "\$prev" = "-o" ] && out="\$a"; prev="\$a"; done
echo run >> "$FAKE/runs"
cat "$FAKE/answer" > "\$out"
echo "fake codex"
FAKE_SCRIPT
chmod +x "$FAKE/codex"
GOOD='{"title": "Add retry", "request": "Retry uploads with exponential backoff.", "criteria": [{"text": "Delay grows exponentially.", "proof": "cat retry.txt"}, {"text": "It gives up after five tries.", "proof": "cat retry.txt"}], "out_of_scope": ["Changing the request timeout."]}'
runs() { if [ -f "$FAKE/runs" ]; then wc -l <"$FAKE/runs" | tr -d ' '; else echo 0; fi; }
threads() { ls "$P/.workbench/threads" 2>/dev/null | wc -l | tr -d ' '; }
setgoal() { # <extra lines for [agents.goal]>: rewrites the config with a Codex goal agent (none when the argument is "-")
    grep -v -e '^model = ' -e '^claude_path = ' "$SCRATCH/config.base" >"$SCRATCH/config.rest"
    { echo 'claude_path = "/usr/bin/false"'; cat "$SCRATCH/config.rest"
      if [ "$1" != "-" ]; then
          printf '\n[providers.codex]\nexecutable = "%s"\n\n[agents.goal]\nprovider = "codex"\n%s\n' "$FAKE/codex" "$1"
      fi; } >"$cfg"
}

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
cp "$cfg" "$SCRATCH/config.base"
echo "$GOOD" >"$FAKE/answer"

# --- 1. no [agents.goal]: manual authoring only -------------------------------------------------------------

setgoal -
wbp "$SCRATCH/none.out" goal draft retry --request "retry uploads"
shown "$SCRATCH/none.out" 3
check "no [agents.goal]: goal draft is refused, exit 6" "workbench goal draft exited $RC" test "$RC" = 6
check "the refusal says to write the goal by hand" "no mention of goal new" grep -q "goal new" "$SCRATCH/none.out"
check "nothing was created" "threads exist: $(threads)" test "$(threads)" = 0

# --- 2. a Codex goal agent forbidden with allow_unpriced = false --------------------------------------------

OPTIN='allow_unpriced = false'
[ "$SABOTAGE" = 1 ] && OPTIN='allow_unpriced = true'
setgoal "$OPTIN"
wbp "$SCRATCH/unpriced.out" goal draft retry --request "retry uploads"
shown "$SCRATCH/unpriced.out" 3
check "Codex with allow_unpriced = false: refused before it starts, exit 6" "workbench goal draft exited $RC" test "$RC" = 6
check "the refusal names allow_unpriced and [agents.goal]" "no such message" \
    bash -c 'grep -q "allow_unpriced" "$1" && grep -q "\[agents.goal\]" "$1"' _ "$SCRATCH/unpriced.out"
check "the fake was not started" "the fake ran $(runs) time(s)" test "$(runs)" = 0
check "still nothing created" "threads exist: $(threads)" test "$(threads)" = 0
wbp "$SCRATCH/doctor.json" doctor --json
check "doctor --json: an unpriced_not_allowed problem for the goal agent, on codex" "no such problem" \
    py "assert any(p['role']=='goal' and p['kind']=='unpriced_not_allowed' for p in d['problems']), d['problems']; assert d['agents'][0]['provider']=='codex', d['agents'][0]" <"$SCRATCH/doctor.json"

# --- 3. without the key, timeout-only: an answer that is not a goal ----------------------------------------

setgoal ""
wbp "$SCRATCH/doctor3.json" doctor --json
check "doctor --json: a timeout_only note for the goal agent and no unpriced_not_allowed" "the goal agent's issues are not as expected" \
    py "g=d['agents'][0]; assert any(i['kind']=='timeout_only' and '300 s' in i['message'] for i in g['issues']), g; assert not any(p['kind']=='unpriced_not_allowed' for p in d['problems']), d['problems']" <"$SCRATCH/doctor3.json"
[ "$SABOTAGE" = 1 ] || echo "I would rather not." >"$FAKE/answer"
wbp "$SCRATCH/bad.out" goal draft retry --request "retry uploads"
shown "$SCRATCH/bad.out" 3
check "an answer that is not a goal: exit 1" "workbench goal draft exited $RC" test "$RC" = 1
check "it says why and that nothing was written" "no such message" \
    bash -c 'grep -q "not usable" "$1" && grep -q "Nothing was written" "$1"' _ "$SCRATCH/bad.out"
check "the failed draft left no thread" "threads exist: $(threads)" test "$(threads)" = 0
check "the fake did run (the refusal was not the reason)" "the fake ran $(runs) time(s)" test "$(runs)" -ge 1

# --- 4. a valid answer: a draft thread ----------------------------------------------------------------------

echo "$GOOD" >"$FAKE/answer"
wbp "$SCRATCH/ok.out" goal draft retry --request "retry uploads with backoff" --base "$BASE"
shown "$SCRATCH/ok.out" 8
check "a valid answer: exit 0" "workbench goal draft exited $RC" test "$RC" = 0
ID=$(sed -n 's/^drafted \([^ ]*\) .*/\1/p' "$SCRATCH/ok.out")
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal draft printed no thread id ($(head -3 "$SCRATCH/ok.out"))"
GOAL="$P/.workbench/threads/$ID/goal.md"
check "the goal is a draft with Workbench's own front matter" "front matter is not Workbench's" \
    bash -c 'grep -q "^status: draft" "$1" && grep -q "^base: $2" "$1" && grep -q "^id: $3" "$1" && ! grep -q -e "^approved" -e "^model:" "$1"' _ "$GOAL" "$BASE" "$ID"
check "the title, criteria and out of scope are the agent's" "the goal does not hold the proposal" \
    bash -c 'grep -q "^title: Add retry" "$1" && grep -q "\[c1\] Delay grows" "$1" && grep -q "\[c2\] It gives up" "$1" && grep -q "Changing the request timeout" "$1"' _ "$GOAL"
wbp "$SCRATCH/log.out" log
shown "$SCRATCH/log.out" 10
check "the log has the draft pair and an attempt, and no turn or approval" "log is not as expected" \
    bash -c 'grep -q "goal draft started on codex" "$1" && grep -q "goal draft finished" "$1" && grep -q "attempt .*: goal on codex" "$1" && ! grep -q -e "turn 1" -e "approved" "$1"' _ "$SCRATCH/log.out"
wbp "$SCRATCH/status.json" status --json
check "status: not approved, no turn" "status says otherwise" \
    py "assert d['goal']['approval']=='draft' and d['turns']==0, d['goal']" <"$SCRATCH/status.json"

# --- 5. --replace over an approved goal ---------------------------------------------------------------------

wbp "$SCRATCH/approve.out" goal approve "$ID" --allow-unrunnable-proofs
check "the draft can be approved by the person" "goal approve exited $RC" test "$RC" = 0
grep -q "^status: approved" "$GOAL" || die "the goal was not approved"
echo '{"title": "Add retry v2", "request": "Retry with jitter.", "criteria": [{"text": "Jitter is applied.", "proof": "cat retry.txt"}], "out_of_scope": []}' >"$FAKE/answer"
wbp "$SCRATCH/norep.out" goal draft "$ID" --request "again"
check "without --replace an existing thread's name is a new draft, refused while it is active" "exit $RC" test "$RC" = 6
wbp "$SCRATCH/rep.out" goal draft "$ID" --replace --request "retry with jitter"
shown "$SCRATCH/rep.out" 6
check "--replace: exit 0 and it says the goal needs approving again" "exit $RC or no notice" \
    bash -c 'test "$1" = 0 && grep -q "needs .workbench goal approve" "$2"' _ "$RC" "$SCRATCH/rep.out"
check "the goal is a draft again with the new text and no approval" "goal file is not redrafted" \
    bash -c 'grep -q "^status: draft" "$1" && grep -q "^title: Add retry v2" "$1" && ! grep -q "^approved" "$1" && grep -q "^base: $2" "$1"' _ "$GOAL" "$BASE"
wbp "$SCRATCH/status2.json" status --json
check "status shows it is not approved" "status says approved" py "assert d['goal']['approval']=='draft', d['goal']" <"$SCRATCH/status2.json"
echo "I would rather not." >"$FAKE/answer"
cp "$GOAL" "$SCRATCH/goal.before"
wbp "$SCRATCH/repfail.out" goal draft "$ID" --replace --request "break it"
check "a failed replacement: exit 1" "exit $RC" test "$RC" = 1
check "a failed replacement leaves the goal byte-identical" "goal.md changed" cmp -s "$SCRATCH/goal.before" "$GOAL"
finish
