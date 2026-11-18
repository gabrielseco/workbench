#!/bin/bash
# verify-cli scenario for the unrunnable-proof check under `permissions = "auto"`, on a clone of this repository. `claude` is never
# started, so it costs nothing.
#   bash scripts/verify-cli/proof-check-auto.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/proof-check-auto.sh   (the same, on a branch that contains origin/main)
# The clone's config has `permissions = "auto"`, a narrow `[tools] allowed` (file tools and `swift test`) and `git push` denied. A goal
# has one criterion whose proof names `scripts/seed-onboarding.ts` (a repository path no entry allows) and one that names
# `git push origin main` (denied). `goal approve` must refuse (exit 6) naming only the denied command; the same goal without the denied
# proof must be approved; under `permissions = "allowlist"` the seed script is refused too (the default is unchanged). Exit 0 only when
# every step passed, 1 when one failed, 2 when it refused to start. VERIFY_CLI_SABOTAGE=1 leaves `permissions` out of the config, so the
# allowlist rules: the step that the refusal does not name the seed script and the approval of the goal without the denied proof must FAIL. The frame
# and the other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: permissions is left out of the config"

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
setconfig() { # <mode>: a narrow allowlist, git push denied, no claude to start
    local cfg="$P/.workbench/config.toml"
    { [ "$1" = auto ] && [ "$SABOTAGE" != 1 ] && echo 'permissions = "auto"'
      echo 'claude_path = "/nonexistent/claude"'
      printf '[tools]\navailable = ["Read", "Grep", "Glob", "Edit", "Write", "Bash"]\n'
      printf 'allowed = ["Read", "Grep", "Glob", "Edit", "Write", "Bash(swift test:*)"]\n'
      printf 'denied = ["Bash(git push:*)"]\n'; } >"$cfg"
}
goalfile() { # <id> <second proof>
    cat <<GOAL
---
id: $1
title: verify-cli proof check under auto
base: $BASE
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

A throwaway thread for the proof check; nothing is run.

## Criteria

- [c1] The seed script runs.
  - proof: \`scripts/seed-onboarding.ts\` exits 0
$2

## Out of scope

- Everything else.
GOAL
}

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
setconfig auto

goalfile verify-cli-auto-denied '- [c2] Nothing is pushed.
  - proof: `git push origin main` was not run' >"$SCRATCH/denied.md"
wbp "$SCRATCH/new1.out" goal new verify-cli-auto-denied --base "$BASE" --from "$SCRATCH/denied.md"
ID1=$(sed -n 's/^created //p' "$SCRATCH/new1.out")
[[ $ID1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id ($(head -3 "$SCRATCH/new1.out"))"
wbp "$SCRATCH/approve1.out" goal approve "$ID1"
RC1=$RC
shown "$SCRATCH/approve1.out" 6
check "approve is refused (6) for the denied command" "goal approve exited $RC1" test "$RC1" = 6
check "the refusal names the denied command" "no 'denied by' line for git push" grep -q "git push origin main.*denied by" "$SCRATCH/approve1.out"
check "and not the seed script, which auto lets run" "the refusal names scripts/seed-onboarding.ts" \
    bash -c '! grep -q "seed-onboarding.ts. *, which a run cannot" "$1"' _ "$SCRATCH/approve1.out"

goalfile verify-cli-auto-ok '- [c2] Tests pass.
  - proof: `swift test` passes' >"$SCRATCH/ok.md"
wbp "$SCRATCH/new2.out" goal new verify-cli-auto-ok --base "$BASE" --from "$SCRATCH/ok.md"
ID2=$(sed -n 's/^created //p' "$SCRATCH/new2.out")
[[ $ID2 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id ($(head -3 "$SCRATCH/new2.out"))"
wbp "$SCRATCH/approve2.out" goal approve "$ID2"
RC2=$RC
shown "$SCRATCH/approve2.out" 6
check "approve goes ahead for the seed script under auto" "goal approve exited $RC2" test "$RC2" = 0

# The default is unchanged: the same goal under the allowlist is refused for the seed script.
setconfig allowlist
wbp "$SCRATCH/approve3.out" goal approve "$ID1"
check "under allowlist the seed script is refused" "no 'not in [tools] allowed' line" \
    grep -q "seed-onboarding.ts.*not in \[tools\] allowed" "$SCRATCH/approve3.out"
finish
