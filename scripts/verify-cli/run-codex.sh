#!/bin/bash
# verify-cli scenario for `run` and `send-back` on Codex (P9 PR 16), on a clone of this repository. The coding agent is a fake
# `codex` script the scenario writes (it edits AGENTS.md in the worktree it is started in, leaves it uncommitted and records the
# prompt it was given), and `claude` is /usr/bin/false, so no real agent is started and it costs nothing.
#   bash scripts/verify-cli/run-codex.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/run-codex.sh   (the same, on a branch that contains origin/main)
# With `[agents.run] provider = "codex"`: a goal with budget_usd is refused by `goal approve` (naming spend_policy: timeout_only) before
# the fake is started; after the goal is changed to `spend_policy: timeout_only` and approved again, `run` succeeds, the turn is on
# record as codex with no session and an unknown cost, the fake's prompt starts with the standing rules, `grant` is refused, a
# `send-back` starts a fresh process whose prompt holds the previous turn, the diff and the note, and `accept` commits what the
# fake left uncommitted. Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start. VERIFY_CLI_SABOTAGE=1
# leaves `[agents.run]` on Claude (/usr/bin/false), so the steps that expect Codex must FAIL. The frame and the other switches are
# in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the run stays on Claude (/usr/bin/false)"

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

# The fake Codex: one JSONL turn, an uncommitted edit of AGENTS.md in its working directory, the prompt kept per run.
FAKE="$SCRATCH/fake-codex"
mkdir -p "$FAKE"
cat >"$FAKE/codex" <<FAKE_SCRIPT
#!/bin/sh
n=\$(cat "$FAKE/n" 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > "$FAKE/n"
for a in "\$@"; do p="\$a"; done
printf '%s' "\$p" > "$FAKE/prompt_\$n"
echo "\$@" > "$FAKE/args_\$n"
echo '{"type":"thread.started","thread_id":"thread-'\$n'"}'
echo "codex turn \$n" >> AGENTS.md
echo '{"type":"item.completed","item":{"id":"i","type":"agent_message","text":"edited AGENTS.md in turn '\$n'"}}'
echo '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}'
FAKE_SCRIPT
chmod +x "$FAKE/codex"
runs() { if [ -f "$FAKE/n" ]; then tr -d ' \n' <"$FAKE/n"; else echo 0; fi; }

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
grep -v -e '^model = ' -e '^claude_path = ' "$cfg" >"$SCRATCH/config.rest"
{ echo 'claude_path = "/usr/bin/false"'; cat "$SCRATCH/config.rest"
  if [ "$SABOTAGE" != 1 ]; then
      printf '\n[providers.codex]\nexecutable = "%s"\n\n[agents.run]\nprovider = "codex"\n' "$FAKE/codex"
  fi; } >"$cfg"

cat >"$SCRATCH/goal.md" <<'GOAL'
---
id: verify-cli-codex
title: verify-cli run on codex scenario
base: verify-cli-base
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

A throwaway thread for a run on Codex; the agent is a fake.

## Criteria

- [c1] AGENTS.md gains a line.
  - proof: the log

## Out of scope

- Everything else.
GOAL
wbp "$SCRATCH/new.out" goal new verify-cli-codex --base "$BASE" --from "$SCRATCH/goal.md"
ID=$(sed -n 's/^created //p' "$SCRATCH/new.out")
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id ($(head -3 "$SCRATCH/new.out"))"
GOAL_FILE="$P/.workbench/threads/$ID/goal.md"
# --- 1. a goal with a dollar budget is not approved on Codex ----------------------------------------------------

wbp "$SCRATCH/approve1.out" goal approve "$ID"
shown "$SCRATCH/approve1.out" 3
check "a budget_usd goal on Codex: approve is refused" "goal approve exited $RC" test "$RC" != 0
check "the refusal says to use spend_policy: timeout_only" "no such message" \
    bash -c 'grep -q "spend_policy: timeout_only" "$1" && grep -q "budget_usd" "$1"' _ "$SCRATCH/approve1.out"
check "the goal stays a draft" "the goal was approved" bash -c '! grep -q "^status: approved" "$1"' _ "$GOAL_FILE"
check "the fake was not started" "the fake ran $(runs) time(s)" test "$(runs)" = 0
check "no worktree was made" "the thread's worktree exists" bash -c '! git -C "$1" worktree list | grep -q "$2"' _ "$P" "$ID"

# --- 2. the goal changed to timeout_only, approved again --------------------------------------------------------

perl -pi -e 's/^budget_usd: .*/spend_policy: timeout_only/' "$GOAL_FILE"
wbp "$SCRATCH/approve2.out" goal approve "$ID"
check "the changed goal is approved again" "goal approve exited $RC" test "$RC" = 0
wbp "$SCRATCH/run1.out" run
shown "$SCRATCH/run1.out" 6
check "run on Codex succeeds: exit 0" "workbench run exited $RC" test "$RC" = 0
check "the fake ran once" "the fake ran $(runs) time(s)" test "$(runs)" = 1
check "the fake's prompt starts with the standing rules and holds the goal" "prompt_1 is not as expected" \
    bash -c 'head -c 60 "$1" | grep -q "isolated git worktree" && grep -q "AGENTS.md gains a line" "$1" && grep -q "cannot commit" "$1"' _ "$FAKE/prompt_1"
wbp "$SCRATCH/log.json" log
wbp "$SCRATCH/status.json" status --json
check "status: one turn, an unknown cost (null), not approved-for-claude" "status says otherwise" \
    py "assert d['turns']==1 and d['cost_usd'] is None, (d['turns'], d['cost_usd'])" <"$SCRATCH/status.json"
wbp "$SCRATCH/logv.out" log -v
check "the log has the turn on codex and normalized activity, no claude lines" "log is not as expected" \
    bash -c 'grep -qi "codex" "$1" && ! grep -q "claude" "$1"' _ "$SCRATCH/logv.out"
check "the turn's events: provider codex, no session_id, null denials" "events are not as expected" \
    bash -c 'f="$1/.workbench/threads/$2/events.jsonl"; grep "\"kind\":\"turn.started\"" "$f" | grep -q "\"provider\":\"codex\"" && ! grep "\"kind\":\"turn.started\"" "$f" | grep -q session_id && grep "\"kind\":\"turn.ended\"" "$f" | grep -q "\"permission_denials\":null" && ! grep "\"kind\":\"turn.ended\"" "$f" | grep -q cost_usd' _ "$P" "$ID"

# --- 3. grants and send-back ------------------------------------------------------------------------------------

wbp "$SCRATCH/grant.out" grant
shown "$SCRATCH/grant.out" 3
check "grant on a Codex thread is refused, exit 6" "workbench grant exited $RC" test "$RC" = 6
check "it says Codex takes no tool grants" "no such message" grep -q "takes no tool grants" "$SCRATCH/grant.out"

wbp "$SCRATCH/send.out" send-back "also handle the empty list"
shown "$SCRATCH/send.out" 4
check "send-back on Codex succeeds: exit 0" "workbench send-back exited $RC" test "$RC" = 0
check "a fresh process ran (not a resume)" "the fake ran $(runs) time(s) or was resumed" \
    bash -c 'test "$1" = 2 && ! grep -q resume "$2"' _ "$(runs)" "$FAKE/args_2"
check "its prompt holds the goal, the previous turn, the diff and the note" "prompt_2 is not self-contained" \
    bash -c 'grep -q "AGENTS.md gains a line" "$1" && grep -q "you do not remember" "$1" && grep -q "edited AGENTS.md in turn 1" "$1" && grep -q "+codex turn 1" "$1" && grep -q "also handle the empty list" "$1"' _ "$FAKE/prompt_2"
check "turn 2 records how it continued" "no continuation record" \
    bash -c 'grep "\"kind\":\"turn.started\"" "$1/.workbench/threads/$2/events.jsonl" | tail -1 | grep -q "fresh_with_context"' _ "$P" "$ID"

# --- 4. accept commits what Codex left uncommitted -------------------------------------------------------------

wbp "$SCRATCH/accept.out" accept --yes -m "verify-cli: codex edit"
shown "$SCRATCH/accept.out" 4
check "accept: exit 0" "workbench accept exited $RC" test "$RC" = 0
check "the branch has the commit with Codex's edit" "no commit on the branch" \
    bash -c 'git -C "$1" log -1 --format=%s "workbench/$2" | grep -q "verify-cli: codex edit" && git -C "$1" show "workbench/$2":AGENTS.md | grep -q "codex turn 2"' _ "$P" "$ID"
finish
