#!/bin/bash
# verify-cli scenario: a read-only OpenCode turn is not started in a checkout that links outside itself (OpenCode's file tools follow
# symlinks whatever its permissions say), on a clone of this repository. `opencode` is a stand-in that records that it was started and
# the gateway URL leads nowhere, so it costs nothing.
#   bash scripts/verify-cli/opencode-links.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/opencode-links.sh   (the same, on a branch that contains origin/main)
# With a committed symlink that points outside the repository: `workbench plan` fails, says OpenCode was not started and names the
# link and not its target, the stand-in never ran, and plan.ended is not ok. Exit 0 only when every step passed, 1 when one failed, 2
# when it refused to start. VERIFY_CLI_SABOTAGE=1 commits no link, so the stand-in is started and the steps that expect the refusal
# must FAIL. The frame and the other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

P="$SCRATCH/project"
g clone -q "$ROOT" "$P" || die "git clone failed"
BASE=verify-cli-base
git -C "$P" checkout -q -b "$BASE" || die "could not make the base branch in the clone"
mkdir -p "$SCRATCH/private" && echo "not for the model" >"$SCRATCH/private/secret-notes.txt"
if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: no outward link is committed"
else
    ln -s "$SCRATCH/private/secret-notes.txt" "$P/verify-cli-link" || die "could not make the link"
    git -C "$P" add verify-cli-link && git -C "$P" -c user.name=verify-cli -c user.email=verify@example.invalid commit -qm "test: a link" \
        || die "could not commit the link"
fi
echo "==> clone at $P, base $BASE"

RC=0
wbp() { # <out> args...: a workbench command in the clone, stdout and stderr together; sets RC
    local o=$1; shift
    echo "workbench $*   (in the clone)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    ( cd "$P" && VERIFY_CLI_FAKE_KEY=verify-cli-not-a-real-key with_timeout "$T_WB" "$WB" "$@" >"$o" 2>&1 )
    RC=$?
}
shown() { sed 's/^/    /' "$1" | head -${2:-8}; }

FAKE="$SCRATCH/opencode"
cat >"$FAKE" <<SH
#!/bin/sh
echo started >>"$SCRATCH/opencode.ran"
exit 1
SH
chmod +x "$FAKE"

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
cfg="$P/.workbench/config.toml"
{ cat "$cfg"
  printf '\n[providers.opencode]\nbase_url = "http://127.0.0.1:9/v1"\napi_key_env = "VERIFY_CLI_FAKE_KEY"\nexecutable = "%s"\n' "$FAKE"
  printf '\n[agents.plan]\nprovider = "opencode"\nmodel = "none"\n'; } >"$cfg.new" && mv "$cfg.new" "$cfg"

cat >"$SCRATCH/goal.md" <<GOAL
---
id: verify-cli-opencode-links
title: verify-cli opencode links scenario
base: $BASE
spend_policy: timeout_only
turn_timeout_min: 5
---

## Request

A throwaway thread: nothing is to be changed.

## Criteria

- [c1] Nothing changes.
  - proof: git status shows no change

## Out of scope

- Everything.
GOAL
wbp "$SCRATCH/new.out" goal new links --base "$BASE" --from "$SCRATCH/goal.md"
ID=$(sed -n 's/^created \([^ ]*\).*/\1/p' "$SCRATCH/new.out")
[ -n "$ID" ] || die "goal new printed no thread id: $(head -3 "$SCRATCH/new.out" | tr '\n' ' ')"
wbp "$SCRATCH/approve.out" goal approve "$ID"
check "the goal is approved" "workbench goal approve exited $RC; $(tail -1 "$SCRATCH/approve.out")" test "$RC" = 0

wbp "$SCRATCH/plan.out" plan "$ID"
shown "$SCRATCH/plan.out"
check "plan fails" "workbench plan exited $RC" test "$RC" != 0
check "it says OpenCode was not started and names the link" "no such refusal" \
    bash -c 'grep -q "OpenCode was not started: verify-cli-link is a symlink" "$1"' _ "$SCRATCH/plan.out"
check "the link's target is not repeated" "the output names the private file" \
    bash -c '! grep -q "secret-notes" "$1"' _ "$SCRATCH/plan.out"
check "opencode was never started" "the stand-in ran" test ! -e "$SCRATCH/opencode.ran"
wbp "$SCRATCH/log.json" log "$ID" --json
ended() {
    py "
e=[x['data'] for x in lines if x['kind']=='plan.ended']
if len(e)!=1: sys.exit('    expected one plan.ended, found %d' % len(e))
print('    plan.ended: ok=%s reason=%s' % (e[0].get('ok'), str(e[0].get('reason'))[:90]))
sys.exit(0 if e[0].get('ok') is False and 'symlink' in str(e[0].get('reason')) else 1)" <"$SCRATCH/log.json"
}
check "plan.ended is not ok and its reason names the symlink" "see above" ended
finish
