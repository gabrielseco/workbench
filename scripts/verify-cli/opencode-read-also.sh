#!/bin/bash
# verify-cli scenario for `read_also` on an OpenCode coding turn, with the REAL `opencode` through a real OpenAI-compatible gateway, on a
# clone of this repository with a second repository beside it.
#   VERIFY_CLI_OPENCODE_BASE_URL=https://gateway.example/v1 LITELLM_API_KEY=... scripts/verify-cli/from-branch.sh opencode-read-also
# Needs macOS, `opencode` on PATH, the key in $LITELLM_API_KEY (or the variable $VERIFY_CLI_OPENCODE_KEY_ENV names) and the gateway's URL
# in VERIFY_CLI_OPENCODE_BASE_URL; $VERIFY_CLI_OPENCODE_MODEL is the gateway's model name (default sonnet-claude). One real coding turn
# (a few cents): `workbench run` exits 0 and does not say read_also is unused; the first prompt names the other repository; the config
# written for the turn allows file tools into it and nowhere else outside; opencode's own `read` tool returned a file of it; the value is
# in the worktree; and the other repository is unchanged. Exit 0 only when every step passed, 1 when one failed, 2 when it refused to
# start. VERIFY_CLI_SABOTAGE=1 leaves `read_also` out of the config, so the steps about the prompt, the rule and the read must FAIL. The
# frame and the other switches are in lib.sh. Run by hand, not by CI.
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
OTHER="$SCRATCH/verify-cli-backend"
VALUE="contract-$RANDOM$RANDOM"
mkdir -p "$OTHER" && git -C "$OTHER" init -q && echo "$VALUE" >"$OTHER/contract.txt" && git -C "$OTHER" add -A \
    && git -C "$OTHER" -c user.name=verify-cli -c user.email=verify@example.invalid commit -qm "the contract" || die "could not make the other repository"
echo "==> clone at $P, other repository at $OTHER"
[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: read_also is left out of the config"

RC=0
wbp() { # <out> <seconds> args...: a workbench command in the clone, stdout and stderr together; sets RC
    local o=$1 secs=$2; shift 2
    echo "workbench $*   (in the clone)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    ( cd "$P" && with_timeout "$secs" "$WB" "$@" >"$o" 2>&1 )
    RC=$?
}
shown() { sed 's/^/    /' "$1" | head -${2:-10}; }

wbp "$SCRATCH/init.out" "$T_WB" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
cfg="$P/.workbench/config.toml"
{ [ "$SABOTAGE" != 1 ] && echo 'read_also = ["../verify-cli-backend"]'
  grep -v -e '^model = ' -e '^read_also' -e '^check_command' -e '^setup_command' "$cfg"
  printf '\n[providers.opencode]\nbase_url = "%s"\napi_key_env = "%s"\n' "$OC_URL" "$KEY_ENV"
  printf '\n[agents.run]\nprovider = "opencode"\nmodel = "%s"\n[verifier]\nenabled = false\n' "$OC_MODEL"; } >"$cfg.new" && mv "$cfg.new" "$cfg"

cat >"$SCRATCH/goal.md" <<GOAL
---
id: verify-cli-opencode-read-also
title: verify-cli opencode read_also scenario
base: $BASE
spend_policy: timeout_only
turn_timeout_min: 10
---

## Request

A throwaway thread. Another repository, in the folder $OTHER, holds the file contract.txt with a single line. Read that file with your
\`read\` tool and write the same line into the new file scratch/copied.txt here. Do not commit.

## Criteria

- [c1] scratch/copied.txt holds the line of the other repository's contract.txt.
  - proof: cat scratch/copied.txt

## Out of scope

- Any other file, and committing.
GOAL
wbp "$SCRATCH/new.out" "$T_WB" goal new read-also --base "$BASE" --from "$SCRATCH/goal.md"
ID=$(sed -n 's/^created \([^ ]*\).*/\1/p' "$SCRATCH/new.out")
[ -n "$ID" ] || die "goal new printed no thread id: $(head -3 "$SCRATCH/new.out" | tr '\n' ' ')"
wbp "$SCRATCH/approve.out" "$T_WB" goal approve "$ID"
check "the goal is approved" "workbench goal approve exited $RC; $(tail -1 "$SCRATCH/approve.out")" test "$RC" = 0

wbp "$SCRATCH/run.out" "$T_RUN" run "$ID"
shown "$SCRATCH/run.out" 8
check "run on opencode: exit 0" "workbench run exited $RC; $(tail -1 "$SCRATCH/run.out")" test "$RC" = 0
check "the run does not say read_also is unused" "it does" bash -c '! grep -q "read_also is not used" "$1"' _ "$SCRATCH/run.out"
THREAD="$P/.workbench/threads/$ID"
check "the first prompt names the other repository" "no 'Other repositories' section naming it" \
    bash -c 'grep -q "^## Other repositories" "$1" && grep -q "verify-cli-backend" "$1"' _ "$THREAD/prompts/turn-1.md"
rule() {
    python3 -I - "$THREAD/prompts/opencode/opencode.json" <<'PY'
import json, sys
rule = json.load(open(sys.argv[1]))['permission']['external_directory']
print('    external_directory: %s' % (rule if isinstance(rule, str) else sorted(k.rsplit('/', 1)[-1] + '=' + v for k, v in rule.items())))
sys.exit(0 if isinstance(rule, dict) and rule.get('*') == 'deny' and any(k.endswith('/verify-cli-backend/**') for k in rule) else 1)
PY
}
check "the turn's config allows file tools into it and denies everything else outside" "see above" rule
wbp "$SCRATCH/transcript.json" "$T_WB" log "$ID" --transcript
read_tool() {
    py "
hits=[x for x in lines if x.get('type')=='tool_use' and x['part'].get('tool')=='read'
      and 'verify-cli-backend' in str(x['part']['state'].get('input')) and x['part']['state'].get('status')=='completed']
print('    completed reads of the other repository: %d' % len(hits))
sys.exit(0 if hits else 1)" <"$SCRATCH/transcript.json"
}
check "opencode's read tool returned a file of the other repository" "see above" read_tool
check "the value is in the worktree" "scratch/copied.txt does not hold it" \
    grep -qx "$VALUE" "$P/.workbench/worktrees/$ID/scratch/copied.txt"
check "the other repository is unchanged" "it has changes" test -z "$(git -C "$OTHER" status --porcelain --untracked-files=all)"
finish
