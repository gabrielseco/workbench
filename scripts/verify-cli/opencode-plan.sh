#!/bin/bash
# verify-cli scenario for the plan role on OpenCode (P28 task 5), with the real `opencode` through a real OpenAI-compatible gateway.
#   VERIFY_CLI_OPENCODE_BASE_URL=https://gateway.example/v1 LITELLM_API_KEY=... bash scripts/verify-cli/opencode-plan.sh
#   (in the main checkout, on a clean origin/main, no active thread; VERIFY_CLI_FROM_BRANCH=1 on a branch that contains origin/main;
#    scripts/verify-cli/from-branch.sh opencode-plan runs both on a temp clone, which also keeps the project's config out of it)
# Needs `opencode` on PATH, the key in $LITELLM_API_KEY (or $VERIFY_CLI_OPENCODE_KEY_ENV names another variable) and the gateway's
# URL in VERIFY_CLI_OPENCODE_BASE_URL; $VERIFY_CLI_OPENCODE_MODEL is the gateway's model name (default sonnet-claude). The project's
# .workbench/config.toml gets [providers.opencode] and [agents.plan] while it runs and is put back when it ends.
# Without a turn: doctor must accept `plan` and `ship` on OpenCode and name the provider, the model and the missing dollar cap on their
# lines, with no "can read files outside" note (a read-only OpenCode turn cannot); and must refuse, naming the problem, a judge on
# OpenCode (not yet proven), an agent naming OpenCode with no [providers.opencode], and a base_url that is not http(s).
# With one read-only plan turn (a few cents): `workbench plan` exits 0, the logged command names gateway/<model> and `--standalone`
# and not `--auto` or the prompt, plan.ended is ok with a cost above 0 (OpenCode reports one), plans/plan-1.md is non-empty with no machine
# path, status says generated, the plan opened no numbered turn, and the key is in no file of the thread.
# Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start. VERIFY_CLI_SABOTAGE=1 leaves [providers.opencode]
# out, so the doctor steps for plan and ship, the plan exit, its events, argv, file, status and turn steps must FAIL. The frame and
# the other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

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
drop = {'agents.plan', 'agents.ship', 'agents.judge', 'providers.opencode'}
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
doctor() { wb "$T_WB" doctor --base origin/main >"$SCRATCH/$1.out" 2>&1; RC=$?; sed 's/^/    /' "$SCRATCH/$1.out" | grep -E "^    (agent|problem|note|.*opencode)" | head -8; }
RC=0

# --- plan and ship on OpenCode: doctor accepts them -------------------------------------------------------

config "$GATEWAY
[agents.plan]
provider = \"opencode\"
model = \"$OC_MODEL\"
[agents.ship]
provider = \"opencode\"
model = \"$OC_MODEL\""
doctor ok
check "plan and ship on opencode: doctor exits 0" "workbench doctor exited $RC" test "$RC" = 0
check "doctor's plan line names opencode and the model" "no 'agent plan: opencode, model $OC_MODEL' line" \
    grep -q "^agent plan: *opencode, model $OC_MODEL" "$SCRATCH/ok.out"
check "doctor's ship line names opencode and the model" "no 'agent ship: opencode, model $OC_MODEL' line" \
    grep -q "^agent ship: *opencode, model $OC_MODEL" "$SCRATCH/ok.out"
check "doctor notes there is no dollar cap" "no 'no dollar cap' note" grep -qi "no dollar cap" "$SCRATCH/ok.out"
check "doctor does not say a read-only opencode turn reads outside its folder" "an unconfined-reads note names opencode" \
    bash -c '! grep -i "can read files outside" "$1" | grep -qi opencode' _ "$SCRATCH/ok.out"

# --- what is refused, by name ----------------------------------------------------------------------------

config "$GATEWAY
[agents.judge]
provider = \"opencode\"
model = \"$OC_MODEL\""
doctor judge
check "a judge on opencode is refused" "workbench doctor exited $RC" test "$RC" != 0
check "the refusal says it cannot use opencode yet and what the judge runs on" "see above" \
    bash -c 'grep -q "cannot use \"opencode\" yet" "$1" && grep -q "\"claude\" or \"codex\"" "$1"' _ "$SCRATCH/judge.out"

config "[agents.plan]
provider = \"opencode\"
model = \"$OC_MODEL\""
doctor nogateway
check "an agent naming opencode with no [providers.opencode] is refused" "workbench doctor exited $RC" test "$RC" != 0
check "the refusal names [providers.opencode] and base_url" "see above" \
    bash -c 'grep -q "\[providers.opencode\]" "$1" && grep -q "base_url" "$1"' _ "$SCRATCH/nogateway.out"

config "[providers.opencode]
base_url = \"ftp://gateway.invalid/v1\"
[agents.plan]
provider = \"opencode\"
model = \"$OC_MODEL\""
doctor badurl
check "a base_url that is not http or https is refused" "workbench doctor exited $RC" test "$RC" != 0
check "the refusal names base_url" "see above" grep -q "base_url" "$SCRATCH/badurl.out"

# --- one real read-only plan turn -------------------------------------------------------------------------

config "$GATEWAY
[agents.plan]
provider = \"opencode\"
model = \"$OC_MODEL\""

GOAL_SRC="$SCRATCH/goal.md"
cat >"$GOAL_SRC" <<'GOAL'
---
id: verify-cli-opencode-plan
title: verify-cli opencode plan scenario
base: origin/main
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

This is a throwaway thread that tests `workbench plan` on OpenCode; its branch is deleted afterwards. Create one new file,
`scratch/plan-probe.txt`, holding the single line `plan-probe`. Do not commit.

## Criteria

- [c1] `scratch/plan-probe.txt` exists in the worktree with the line `plan-probe`.
  - proof: the diff shows that one new file and nothing else

## Out of scope

- Any other file, and committing.
GOAL

start_thread verify-cli-opencode-plan "$GOAL_SRC"
PLANS="$THREAD_DIR/plans"

wb "$T_RUN" plan "$ID" --model "$OC_MODEL" >"$SCRATCH/plan.out" 2>&1
plan_exit=$?
head -12 "$SCRATCH/plan.out" | sed 's/^/    /'
check "plan on opencode: exit 0" "workbench plan exited $plan_exit" test "$plan_exit" = 0

LOG1=$(wb "$T_WB" log "$ID" --json)
plan_events() {
    echo "$LOG1" | py "
s=[e for e in lines if e['kind']=='plan.started']; n=[e for e in lines if e['kind']=='plan.ended']
if len(s)!=1 or len(n)!=1 or s[0]['seq']>n[0]['seq']: sys.exit('    expected one plan.started, then one plan.ended')
e=n[0]['data']
miss=[k for k in ('plan_ref','sha256','goal_hash','base_commit') if not e.get(k)]
if e.get('ok') is not True or miss: sys.exit('    plan.ended: ok=%s, missing %s, reason %s' % (e.get('ok'), miss, e.get('reason')))
if not (e.get('cost_usd') or 0) > 0: sys.exit('    plan.ended carries no cost: opencode reports one per step')
print('    plan.ended ok: %s, %s bytes, cost %s' % (e['plan_ref'], e.get('bytes'), e.get('cost_usd')))"
}
check "plan.started then plan.ended ok, with ref, hashes, base_commit and a cost above 0" "see above" plan_events

plan_argv() {
    echo "$LOG1" | py "
a=next(e['data']['argv'] for e in lines if e['kind']=='plan.started')
print('    argv: %s' % ' '.join(a[:10]))
ok=('gateway/$OC_MODEL' in a and '--standalone' in a and '--format' in a and '--auto' not in a
    and not any('plan-probe' in v or 'Create one new file' in v for v in a))
sys.exit(0 if ok else 1)"
}
check "the logged command names gateway/$OC_MODEL and --standalone, not --auto and not the prompt" "see above" plan_argv

turns=$(echo "$LOG1" | py "print(len([e for e in lines if e['kind']=='turn.started']))")
check "the plan opened no numbered turn" "$turns turn.started event(s)" test "$turns" = 0

PLAN1="$PLANS/plan-1.md"
plan_file_ok() {
    [ -s "$PLAN1" ] || { echo "    $PLAN1 is missing or empty"; return 1; }
    echo "    plan-1.md: $(wc -c <"$PLAN1" | tr -d ' ') bytes, first line: $(grep -m1 . "$PLAN1" | cut -c1-70)"
    ! grep -qE '/Users/|/home/' "$PLAN1"
}
check "plans/plan-1.md is non-empty and holds no machine path" "see above" plan_file_ok

plan_status() {
    wb "$T_WB" status "$ID" --json | py "
p=d.get('plan')
print('    plan: %s; plan_cost_usd %s' % (json.dumps(p) if p is None else '%s stale=%s' % (p['source'], p['stale']), d.get('plan_cost_usd')))
sys.exit(0 if p is not None and p['source']=='generated' and p['stale'] is False and (d.get('plan_cost_usd') or 0) > 0 else 1)"
}
check "status --json: plan generated, not stale, plan_cost_usd above 0" "see above" plan_status

# The key was in the environment of the run; it must not be in anything the thread kept.
key_kept() {
    python3 -I - "$THREAD_DIR" "$KEY_ENV" <<'PY'
import os, sys
root, name = sys.argv[1], sys.argv[2]
key = os.environ[name].encode()
hits = [os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs
        if key in open(os.path.join(d, f), 'rb').read()]
print('    the key is in %d file(s) of the thread' % len(hits))
sys.exit(1 if hits else 0)
PY
}
check "the gateway key is in no file of the thread" "see above" key_kept

plan_cost=$(wb "$T_WB" log "$ID" --json | py "e=[x['data'] for x in lines if x['kind']=='plan.ended']
print('%.4f USD over %d plan turn(s)' % (sum(x.get('cost_usd') or 0 for x in e), len(e)))")
echo "cost of the plan turn: $plan_cost (model $OC_MODEL)"

# The thread is ended here, not left active: abandon keeps the branch and saves the changes.
wb "$T_WB" abandon "$ID" >/dev/null
ended=$(wb "$T_WB" status "$ID" --json | py "print(d['ended'] or '')")
check "thread ended (abandon)" "thread $ID is still active" test -n "$ended"

# A plan turn makes no branch (a coding turn does), so there is only one to remove if something made it.
branch_exists "$BRANCH" && remove_on_pass branch "$BRANCH"

restore_config
finish
