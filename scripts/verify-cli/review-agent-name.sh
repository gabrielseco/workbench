#!/bin/bash
# verify-cli scenario for the review progress line naming the configured review agent, on a clone of this repository. The clone's
# claude is /usr/bin/false and its codex does not exist, so no review starts and it costs nothing.
#   bash scripts/verify-cli/review-agent-name.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/review-agent-name.sh   (the same, on a branch that contains origin/main)
# `pr-review --pr <n>` prints "asking <agent> to review pull request #<n> ..." before it starts the review: it must say Claude with
# `[agents.review] provider = "claude"`, Codex with "codex", and Codex with no [agents] table. The review itself fails (no agent),
# which is not what is checked. Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start.
# VERIFY_CLI_SABOTAGE=1 leaves the review on codex in the Claude step, so that step must FAIL. The frame and the other switches
# are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the review stays on codex in the Claude step"

P="$SCRATCH/project"
g clone -q "$ROOT" "$P" || die "git clone failed"
echo "==> clone at $P"

RC=0
wbp() { # <out> args...: a workbench command in the clone, stdout and stderr together; sets RC
    local o=$1; shift
    echo "workbench $*   (in the clone)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    ( cd "$P" && with_timeout "$T_WB" "$WB" "$@" >"$o" 2>&1 )
    RC=$?
}
shown() { sed 's/^/    /' "$1" | head -${2:-6}; }
cfg="$P/.workbench/config.toml"
setreview() { # <provider or empty>: rewrites the clone's config with the review agent on that provider
    grep -v -e '^model = ' -e '^claude_path = ' "$SCRATCH/config.base" >"$SCRATCH/config.rest"
    { echo 'claude_path = "/usr/bin/false"'; cat "$SCRATCH/config.rest"
      printf '\n[providers.codex]\nexecutable = "/nonexistent/codex"\n'
      [ -n "$1" ] && printf '\n[agents.review]\nprovider = "%s"\n' "$1"; } >"$cfg"
}

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
cp "$cfg" "$SCRATCH/config.base"

review_line() { grep -m1 '^asking .* to review pull request #1 ' "$SCRATCH/review.out"; }

[ "$SABOTAGE" = 1 ] && setreview codex || setreview claude
wbp "$SCRATCH/review.out" pr-review --pr 1
shown "$SCRATCH/review.out"
check "review agent claude: the line says Claude" "line: $(review_line)" \
    grep -q '^asking Claude to review pull request #1 (read-only; this can take several minutes)\.\.\.$' "$SCRATCH/review.out"

setreview codex
wbp "$SCRATCH/review.out" pr-review --pr 1
shown "$SCRATCH/review.out"
check "review agent codex: the line says Codex" "line: $(review_line)" \
    grep -q '^asking Codex to review pull request #1 (read-only; this can take several minutes)\.\.\.$' "$SCRATCH/review.out"

setreview ""
wbp "$SCRATCH/review.out" pr-review --pr 1
check "no [agents] table: the line says Codex, as before" "line: $(review_line)" \
    grep -q '^asking Codex to review pull request #1 (read-only; this can take several minutes)\.\.\.$' "$SCRATCH/review.out"

finish
