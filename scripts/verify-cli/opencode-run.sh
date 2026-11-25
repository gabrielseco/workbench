#!/bin/bash
# verify-cli scenario for the coding and judge roles on OpenCode (P28 task 5), with the real `opencode` through a real OpenAI-compatible gateway.
#   VERIFY_CLI_OPENCODE_BASE_URL=https://gateway.example/v1 LITELLM_API_KEY=... scripts/verify-cli/from-branch.sh opencode-run
#   (or directly, in the main checkout, on a clean origin/main with no active thread; VERIFY_CLI_FROM_BRANCH=1 on a branch)
# Needs macOS (the turn runs under `sandbox-exec`), `opencode` on PATH, the key in $LITELLM_API_KEY (or the variable
# $VERIFY_CLI_OPENCODE_KEY_ENV names) and the gateway's URL in VERIFY_CLI_OPENCODE_BASE_URL; $VERIFY_CLI_OPENCODE_MODEL is the gateway's
# model name (default sonnet-claude). The project's .workbench/config.toml gets [providers.opencode] and [agents.run] while it runs and is
# put back when it ends.
# Without a turn: doctor must accept the coding role on OpenCode, naming the provider, the model, the missing dollar cap and the stated
# limit that a coding turn can read files outside its worktree; `goal approve` must refuse a goal with budget_usd, naming opencode and
# `spend_policy: timeout_only`; and `run` with the key's variable unset must be refused, naming it, before a worktree or a turn exists.
# With one real coding turn (a few cents): `workbench run` exits 0; the logged command starts with /usr/bin/sandbox-exec and names
# gateway/<model>, with no `--auto`; turn.ended says succeeded with a cost above 0 and names no session; the transcript holds
# OpenCode's own stream; the file the goal asked for is in the worktree, uncommitted (the sandbox cannot commit: `accept` does); the
# main checkout is untouched; the key is in no file of the thread; no process of the worktree is left; there is one turn.started and one
# turn.ended. Then `workbench judge` runs on the same thread, also on OpenCode: it exits 0, judge.ran is ok with provider opencode
# and the model and a verdict that names the goal's criterion, its logged command names gateway/<model> and not the prompt, no process of
# the worktree is left, and the key is still in no file of the thread. Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start. VERIFY_CLI_SABOTAGE=1 leaves
# [providers.opencode] out, so the doctor, the budget refusal, the unset-key refusal, every step of the real turn and of the judge must FAIL. The frame and
# the other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$(uname)" = Darwin ] || die "a coding turn on OpenCode runs under macOS's sandbox-exec; this is not macOS"
KEY_ENV=${VERIFY_CLI_OPENCODE_KEY_ENV:-LITELLM_API_KEY}
OC_MODEL=${VERIFY_CLI_OPENCODE_MODEL:-sonnet-claude}
OC_URL=${VERIFY_CLI_OPENCODE_BASE_URL:-}
[[ $KEY_ENV =~ ^[A-Z][A-Z0-9_]*$ ]] || die "VERIFY_CLI_OPENCODE_KEY_ENV is not an environment variable name: '$KEY_ENV'"
[[ $OC_MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] || die "VERIFY_CLI_OPENCODE_MODEL is not a model name: '$OC_MODEL'"
[[ $OC_URL =~ ^https?://[^[:space:]\"]+$ ]] || die "set VERIFY_CLI_OPENCODE_BASE_URL to the gateway's http(s) URL (its OpenAI-compatible /v1)"
[ -n "${!KEY_ENV:-}" ] || die "$KEY_ENV is not set: the gateway's key is read from it, and is never written anywhere"
command -v opencode >/dev/null || die "opencode is not on PATH"
export "$KEY_ENV"

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: [providers.opencode] is left out of the config"

# The project's own config is kept aside and put back, whatever happens.
CFG="$ROOT/.workbench/config.toml"
[ -f "$CFG" ] || die "no $CFG: run \`workbench init\` first"
BACKUP="$CFG.verify-cli-opencode-backup"
[ ! -e "$BACKUP" ] || die "$BACKUP exists: a previous run did not finish; put it back over $CFG first"
cp "$CFG" "$BACKUP" || die "could not back up the config"
restore_config() { [ -f "$BACKUP" ] && mv -f "$BACKUP" "$CFG"; }
trap restore_config EXIT

# <extra config text>: the original config without the tables this scenario writes (a project may already have them), then this text
config() {
    python3 -I - "$BACKUP" "$CFG" "$1" <<'PY'
import re, sys
src, dst, extra = sys.argv[1:4]
drop = {'agents.run', 'agents.judge', 'providers.opencode'}
out, skip = [], False
for line in open(src).read().split('\n'):
    m = re.match(r'^\s*\[([^\[\]]+)\]\s*(#.*)?$', line)
    if m:
        skip = m.group(1).strip() in drop
    if not skip:
        out.append(line)
open(dst, 'w').write('\n'.join(out).rstrip('\n') + '\n\n' + extra + '\n')
PY
}
GATEWAY="[providers.opencode]
base_url = \"$OC_URL\"
api_key_env = \"$KEY_ENV\""
[ "$SABOTAGE" = 1 ] && GATEWAY=""
RUN_ROLE="[agents.run]
provider = \"opencode\"
model = \"$OC_MODEL\"
[agents.judge]
provider = \"opencode\"
model = \"$OC_MODEL\""
RC=0

# --- doctor accepts the coding role on OpenCode -----------------------------------------------------------

config "$GATEWAY
$RUN_ROLE"
wb "$T_WB" doctor --base origin/main >"$SCRATCH/doctor.out" 2>&1; RC=$?
grep -E "^(agent run|problem|note)" "$SCRATCH/doctor.out" | head -6 | sed 's/^/    /'
check "the coding role on opencode: doctor exits 0" "workbench doctor exited $RC" test "$RC" = 0
check "doctor's run line names opencode and the model" "no 'agent run: opencode, model $OC_MODEL' line" \
    grep -q "^agent run: *opencode, model $OC_MODEL" "$SCRATCH/doctor.out"
check "doctor notes there is no dollar cap" "no 'no dollar cap' note" grep -qi "no dollar cap" "$SCRATCH/doctor.out"
check "doctor states that a coding turn can read outside its worktree" "no unconfined-reads note naming opencode" \
    bash -c 'grep -i "coding turn on opencode can read files outside" "$1" | grep -q .' _ "$SCRATCH/doctor.out"

# --- the thread: a budget goal is refused, then the goal is made timeout-only ------------------------------

GOAL_SRC="$SCRATCH/goal.md"
cat >"$GOAL_SRC" <<'GOAL'
---
id: verify-cli-opencode-run
title: verify-cli opencode run scenario
base: origin/main
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

This is a throwaway thread that tests `workbench run` on OpenCode; its branch is deleted afterwards. Create one new file,
`scratch/opencode-probe.txt`, holding the single line `opencode-probe`. Do not commit.

## Criteria

- [c1] `scratch/opencode-probe.txt` exists in the worktree with the line `opencode-probe`.
  - proof: the diff shows that one new file and nothing else

## Out of scope

- Any other file, and committing.
GOAL

created=$(wb "$T_WB" goal new verify-cli-opencode-run --base origin/main --from "$GOAL_SRC") || { echo "$created"; die "goal new failed"; }
ID=$(echo "$created" | sed -n 's/^created //p')
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id"
BRANCH="workbench/$ID"
THREAD_DIR="$ROOT/.workbench/threads/$ID"

wb "$T_WB" goal approve "$ID" >"$SCRATCH/approve-budget.out" 2>&1; RC=$?
head -3 "$SCRATCH/approve-budget.out" | sed 's/^/    /'
check "a goal with budget_usd is refused by goal approve" "workbench goal approve exited $RC" test "$RC" != 0
check "the refusal names opencode and spend_policy: timeout_only" "see above" \
    bash -c 'grep -q "opencode cannot enforce a dollar limit" "$1" && grep -q "spend_policy: timeout_only" "$1"' _ "$SCRATCH/approve-budget.out"

perl -pi -e 's/^budget_usd: .*/spend_policy: timeout_only/; s/^turn_timeout_min: .*/turn_timeout_min: 10/' "$THREAD_DIR/goal.md"
wb "$T_WB" goal approve "$ID" >"$SCRATCH/approve.out" 2>&1; RC=$?
head -3 "$SCRATCH/approve.out" | sed 's/^/    /'
check "the goal, made spend_policy: timeout_only, is approved" "workbench goal approve exited $RC" test "$RC" = 0

# --- a run with the key's variable unset is refused before anything exists -----------------------------------

( unset "$KEY_ENV"; wb "$T_RUN" run "$ID" >"$SCRATCH/run-nokey.out" 2>&1 ); RC=$?
head -3 "$SCRATCH/run-nokey.out" | sed 's/^/    /'
check "run with the key variable unset is refused" "workbench run exited $RC" test "$RC" != 0
check "the refusal names \$$KEY_ENV" "see above" grep -qF "\$$KEY_ENV" "$SCRATCH/run-nokey.out"
no_turn() {
    local log started
    log=$(wb "$T_WB" log "$ID" --json) || return 1
    started=$(echo "$log" | py "print(len([e for e in lines if e['kind']=='turn.started']))")
    [ "$started" = 0 ] && [ -z "$(g worktree list --porcelain | grep "threads/$ID\|worktrees/$ID")" ]
}
check "nothing was started: no turn, no worktree" "a turn or a worktree exists" no_turn

# --- one real coding turn ---------------------------------------------------------------------------------------

wb "$T_RUN" run "$ID" >"$SCRATCH/run.out" 2>&1
run_exit=$?
head -12 "$SCRATCH/run.out" | sed 's/^/    /'
check "run on opencode: exit 0" "workbench run exited $run_exit" test "$run_exit" = 0

LOG1=$(wb "$T_WB" log "$ID" --json)
turn_events() {
    echo "$LOG1" | py "
s=[e for e in lines if e['kind']=='turn.started']; n=[e for e in lines if e['kind']=='turn.ended']
if len(s)!=1 or len(n)!=1 or s[0]['seq']>n[0]['seq']: sys.exit('    expected one turn.started, then one turn.ended')
e=n[0]['data']
if e.get('result')!='succeeded': sys.exit('    turn.ended: result %s, error %s' % (e.get('result'), e.get('error')))
if not (e.get('cost_usd') or 0) > 0: sys.exit('    turn.ended carries no cost: opencode reports one per step')
if s[0]['data'].get('session_id') is not None: sys.exit('    a fresh process each turn: no session id expected')
print('    turn.ended succeeded, cost %s, %s ms' % (e['cost_usd'], e.get('duration_ms')))"
}
check "one turn.started then one turn.ended: succeeded, with a cost, no session" "see above" turn_events

turn_argv() {
    echo "$LOG1" | py "
a=next(e['data']['argv'] for e in lines if e['kind']=='turn.started')
print('    argv: %s' % ' '.join(a[:9]))
ok=(a[0]=='/usr/bin/sandbox-exec' and a[1]=='-f' and 'gateway/$OC_MODEL' in a and '--standalone' in a and '--auto' not in a)
sys.exit(0 if ok else 1)"
}
check "the logged command is sandbox-exec around opencode on gateway/$OC_MODEL, without --auto" "see above" turn_argv

stream_lines() {
    local n
    n=$(wb "$T_WB" log "$ID" --transcript | py "print(len([x for x in lines if isinstance(x, dict) and x.get('type')=='step_finish']))")
    echo "    opencode step_finish lines in the transcript: $n"
    [ "${n:-0}" -gt 0 ]
}
check "the transcript holds opencode's own stream" "no step_finish line" stream_lines

WT=$(wb "$T_WB" status "$ID" --json | py "print(d['worktree']['path'] or '')")
probe_file() {
    [ -n "$WT" ] && [ -f "$WT/scratch/opencode-probe.txt" ] || { echo "    no $WT/scratch/opencode-probe.txt"; return 1; }
    echo "    file: $(cat "$WT/scratch/opencode-probe.txt")"
    grep -qx "opencode-probe" "$WT/scratch/opencode-probe.txt"
}
check "the file the goal asked for is in the worktree" "see above" probe_file

left_uncommitted() {
    local ahead dirty
    ahead=$(git -C "$WT" rev-list --count "origin/main..HEAD" 2>/dev/null || echo "?")
    dirty=$(git -C "$WT" status --porcelain --untracked-files=all | grep -c "scratch/opencode-probe.txt")
    echo "    commits ahead of the base: $ahead; the file is listed as changed: $dirty"
    [ "$ahead" = 0 ] && [ "$dirty" = 1 ]
}
check "the change is left uncommitted: the sandbox cannot commit" "see above" left_uncommitted

main_untouched() { [ -z "$(g status --porcelain)" ]; }
check "the main checkout is untouched" "git status shows changes" main_untouched

# --- the judge on the same thread, also on OpenCode ---------------------------------------------------------------

wb "$T_RUN" judge "$ID" >"$SCRATCH/judge.out" 2>&1
judge_exit=$?
head -8 "$SCRATCH/judge.out" | sed 's/^/    /'
check "judge on opencode: exit 0" "workbench judge exited $judge_exit" test "$judge_exit" = 0

LOG2=$(wb "$T_WB" log "$ID" --json)
judge_events() {
    echo "$LOG2" | py "
r=[e for e in lines if e['kind']=='judge.ran']
if len(r)!=1: sys.exit('    expected one judge.ran, found %d' % len(r))
d=r[0]['data']
if d.get('ok') is not True: sys.exit('    judge.ran: ok=%s, reason %s' % (d.get('ok'), d.get('reason')))
if d.get('provider')!='opencode' or d.get('model')!='$OC_MODEL': sys.exit('    judge.ran names %s / %s' % (d.get('provider'), d.get('model')))
ids=[c.get('id') for c in d.get('criteria', [])]
print('    judge.ran ok on opencode, criteria %s, cost %s' % (ids, d.get('cost_usd')))
sys.exit(0 if ids==['c1'] else 1)"
}
check "judge.ran is ok on opencode with a verdict on c1" "see above" judge_events

judge_argv() {
    echo "$LOG2" | py "
a=next(e['data']['argv'] for e in lines if e['kind']=='judge.started')
print('    argv: %s' % ' '.join(a[:9]))
ok=('gateway/$OC_MODEL' in a and '--standalone' in a and '--auto' not in a
    and not any('opencode-probe' in v or 'Criteria' in v for v in a))
sys.exit(0 if ok else 1)"
}
check "the judge's logged command names gateway/$OC_MODEL and not the prompt" "see above" judge_argv

left=$( [ -n "$WT" ] && pgrep -fl "$WT")
check "no process of the worktree left after the judge" "$left" test -z "$left"

# The key was in the runner's environment; it must be in nothing the thread kept, nor in the argv.
key_kept() {
    python3 -I - "$THREAD_DIR" "$KEY_ENV" <<'PY'
import gzip, os, sys
root, name = sys.argv[1], sys.argv[2]
key = os.environ[name].encode()
hits = []
for d, _, fs in os.walk(root):
    for f in fs:
        p = os.path.join(d, f)
        data = open(p, 'rb').read()
        if p.endswith('.gz'):
            try:
                data = gzip.decompress(data)
            except Exception:
                pass
        if key in data:
            hits.append(p)
print('    the key is in %d file(s) of the thread' % len(hits))
sys.exit(1 if hits else 0)
PY
}
check "the gateway key is in no file of the thread" "see above" key_kept

left=$( [ -n "$WT" ] && pgrep -fl "$WT")
check "no process of the worktree left" "$left" test -z "$left"

echo "cost of the turn: $(echo "$LOG1" | py "e=[x['data'] for x in lines if x['kind']=='turn.ended']
print('%.4f USD over %d turn(s)' % (sum(x.get('cost_usd') or 0 for x in e), len(e)))") (model $OC_MODEL)"

# The thread is ended here, not left active: abandon keeps the branch and saves the changes.
wb "$T_WB" abandon "$ID" >/dev/null
ended=$(wb "$T_WB" status "$ID" --json | py "print(d['ended'] or '')")
check "thread ended (abandon)" "thread $ID is still active" test -n "$ended"
branch_exists "$BRANCH" && remove_on_pass branch "$BRANCH"

restore_config
finish
