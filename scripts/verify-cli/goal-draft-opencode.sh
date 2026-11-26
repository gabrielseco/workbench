#!/bin/bash
# verify-cli scenario for `workbench goal draft` with the REAL `opencode` as the goal agent, through a real OpenAI-compatible gateway
# (P28 task 5), on a clone of this repository.
#   VERIFY_CLI_OPENCODE_BASE_URL=https://gateway.example/v1 LITELLM_API_KEY=... scripts/verify-cli/from-branch.sh goal-draft-opencode
# Needs `opencode` on PATH, the key in $LITELLM_API_KEY (or the variable $VERIFY_CLI_OPENCODE_KEY_ENV names) and the gateway's URL in
# VERIFY_CLI_OPENCODE_BASE_URL; $VERIFY_CLI_OPENCODE_MODEL is the gateway's model name (default sonnet-claude). One real draft (read-only,
# no dollar cap, a few cents): it must exit 0, say it drafted, and leave a draft thread (never approved, Workbench's own front matter, a
# title and at least one criterion, the log with a goal.draft pair on opencode with a cost, and no coding turn); its logged command names
# gateway/<model> and not --auto; the gateway key is in no file of the thread. Then, with the key unset, `chat --abandon-active` is refused (exit 6) naming the variable, the draft is not abandoned and no chat
# thread is made. (A draft with a screenshot is refused by name; that is the app's, and tested in GoalOpencodeTests.) Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start. VERIFY_CLI_SABOTAGE=1 leaves
# [providers.opencode] out of the clone's config, so the steps that expect a draft must FAIL. The frame and the other switches are in
# lib.sh. Run by hand, not by CI.
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

P="$SCRATCH/project"
g clone -q "$ROOT" "$P" || die "git clone failed"
BASE=verify-cli-base
git -C "$P" checkout -q -b "$BASE" || die "could not make the base branch in the clone"
echo "==> clone at $P, base $BASE"
[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: [providers.opencode] is left out of the clone's config"

RC=0
wbp() { # <out> args...: a workbench command in the clone, stdout and stderr together; sets RC
    local o=$1 secs=$2; shift 2
    echo "workbench $*   (in the clone)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    ( cd "$P" && with_timeout "$secs" "$WB" "$@" >"$o" 2>&1 )
    RC=$?
}
shown() { sed 's/^/    /' "$1" | head -${2:-12}; }
threads() { ls "$P/.workbench/threads" 2>/dev/null | wc -l | tr -d ' '; }
cfg="$P/.workbench/config.toml"

wbp "$SCRATCH/init.out" "$T_WB" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
grep -v -e '^model = ' "$cfg" >"$SCRATCH/config.rest"
{ echo "max_active_threads = 1"
  grep -v -e "^max_active_threads" "$SCRATCH/config.rest"
  [ "$SABOTAGE" != 1 ] && printf '\n[providers.opencode]\nbase_url = "%s"\napi_key_env = "%s"\n' "$OC_URL" "$KEY_ENV"
  printf '\n[agents.goal]\nprovider = "opencode"\nmodel = "%s"\n' "$OC_MODEL"; } >"$cfg"


before=$(threads)

# --- a real draft -------------------------------------------------------------------------------------------

wbp "$SCRATCH/ok.out" "$T_RUN" goal draft real-opencode --request "Add a short Troubleshooting section to the README that tells a reader to run workbench doctor first." --base "$BASE"
shown "$SCRATCH/ok.out" 8
check "the real opencode drafts: exit 0" "workbench goal draft exited $RC; $(tail -1 "$SCRATCH/ok.out")" test "$RC" = 0
ID=$(sed -n 's/^drafted \([^ ]*\) .*/\1/p' "$SCRATCH/ok.out")
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { ID=""; fail "a draft thread was made" "goal draft printed no thread id ($(head -2 "$SCRATCH/ok.out" | tr '\n' ' '))"; }
GOAL="$P/.workbench/threads/$ID/goal.md"
check "the goal is a draft with Workbench's own front matter" "front matter is not Workbench's" \
    bash -c 'grep -q "^status: draft" "$1" && grep -q "^base: $2" "$1" && grep -q "^id: $3" "$1" && ! grep -q -e "^approved" "$1"' _ "$GOAL" "$BASE" "$ID"
check "it has a title and at least one criterion with a proof" "the goal has none" \
    bash -c 'grep -q "^title: ." "$1" && grep -q "\[c1\]" "$1" && grep -q "proof:" "$1"' _ "$GOAL"
wbp "$SCRATCH/log.out" "$T_WB" log "$ID"
check "the log has the draft pair on opencode and no turn or approval" "log is not as expected" \
    bash -c 'grep -q "goal draft started on opencode" "$1" && grep -q "goal draft finished" "$1" && ! grep -q -e "turn 1" -e "approved" "$1"' _ "$SCRATCH/log.out"
wbp "$SCRATCH/log.json" "$T_WB" log "$ID" --json
draft_events() {
    py "
f=[e for e in lines if e['kind']=='goal.draft.finished']; s=[e for e in lines if e['kind']=='goal.draft.started']
if len(f)!=1 or len(s)!=1: sys.exit('    expected one goal.draft.started and one goal.draft.finished')
d=f[0]['data']
print('    goal.draft.finished: ok=%s provider=%s model=%s cost=%s' % (d.get('ok'), d.get('provider'), d.get('model'), d.get('cost_usd')))
sys.exit(0 if d.get('ok') is True and d.get('provider')=='opencode' and d.get('model')=='$OC_MODEL' and (d.get('cost_usd') or 0) > 0 else 1)" <"$SCRATCH/log.json"
}
check "goal.draft.finished is ok on opencode and the model, with a cost" "see above" draft_events
check "exactly one thread was made" "threads exist: $(threads)" test "$(threads)" = "$((before + 1))"

# The key was in the environment of the run; it must be in nothing the thread kept.
key_kept() {
    python3 -I - "$P/.workbench/threads/$ID" "$KEY_ENV" <<'PY'
import os, sys
root, name = sys.argv[1], sys.argv[2]
key = os.environ[name].encode()
hits = [os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs if key in open(os.path.join(d, f), 'rb').read()]
print('    the key is in %d file(s) of the thread' % len(hits))
sys.exit(1 if hits else 0)
PY
}
check "the gateway key is in no file of the thread" "see above" key_kept

# --- a chat that cannot be served costs nothing, not even the active thread ------------------------------------

# The draft is the one active thread (max_active_threads = 1), so a new chat would have to abandon it first. With the key unset it
# must be refused before that. No turn is started, so this costs nothing.
( unset "$KEY_ENV"; cd "$P" && with_timeout "$T_WB" "$WB" chat other --message "could uploads retry?" --abandon-active ) \
    >"$SCRATCH/chat.out" 2>&1; RC=$?
shown "$SCRATCH/chat.out" 3
check "a chat with the key unset is refused, exit 6, naming it" "exit $RC" \
    bash -c 'test "$1" = 6 && grep -q "$2" "$3"' _ "$RC" "$KEY_ENV" "$SCRATCH/chat.out"
wbp "$SCRATCH/after.json" "$T_WB" status "$ID" --json
check "the active draft was not abandoned" "status says it ended" \
    bash -c 'py=$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1])).get(\"ended\") or \"\")" "$1") && test -z "$py"' _ "$SCRATCH/after.json"
check "no chat thread was made" "threads: $(threads)" test "$(threads)" = "$((before + 1))"
finish
