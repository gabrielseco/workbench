#!/bin/bash
# verify-cli scenario for `[providers.*]`, `[agents.*]` and `workbench doctor` (P9 PR 7), on a clone of this repository.
# No turn is run, so it costs nothing.
#   bash scripts/verify-cli/agents-config.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/agents-config.sh   (the same, on a branch that contains origin/main)
# Doctor must print one `agent <role>:` line each for goal, run, judge and review: with no tables the defaults (goal
# manual, run and judge on claude, review on codex); with `[agents.judge] model = "haiku"` the judge line must say haiku.
# A provider no adapter exists for (`[agents.run] provider = "gemini"`), a stage that sets both `reviewer` and
# `provider`, and an unknown provider table must each be refused by doctor with a message that names the problem.
# A coding turn takes `[agents.run]` `model` and `reasoning_effort`: doctor must accept them on codex and name both on the run line.
# Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start (nothing changed).
# VERIFY_CLI_SABOTAGE=1 leaves the haiku model out and writes valid values in the three refused configs, so the judge
# line step, the three "refused" steps and the coding effort step must FAIL. The frame and the other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the model is left out and the refused configs are made valid"

# A clone, so the project's own .workbench/config.toml and threads are never touched.
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
config() { # <extra config text>
    cat >"$P/.workbench/config.toml" <<TOML
[tools]
available = ["Read"]
allowed = ["Read"]

$1
TOML
}
shown() { sed 's/^/    /' "$1" | head -${2:-8}; }

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0

# --- 1. defaults -----------------------------------------------------------------------------------------

config ""
wbp "$SCRATCH/d1.out" doctor --base "$BASE"
shown "$SCRATCH/d1.out" 6
check "no tables: doctor exits 0" "workbench doctor exited $RC" test "$RC" = 0
check "no tables: goal drafting stays manual" "no 'agent goal: none' line" grep -q "^agent goal: *none" "$SCRATCH/d1.out"
check "no tables: run and judge on claude" "no claude lines for run and judge" bash -c \
    'grep -q "^agent run: *claude, model the provider.s default" "$1" && grep -q "^agent judge: *claude, model" "$1"' _ "$SCRATCH/d1.out"
check "no tables: review on codex" "no 'agent review: codex' line" grep -q "^agent review: *codex," "$SCRATCH/d1.out"

# --- 2. a configured model -------------------------------------------------------------------------------

MODEL=haiku
[ "$SABOTAGE" = 1 ] && MODEL=""
if [ -n "$MODEL" ]; then config "[agents.judge]
model = \"$MODEL\""; else config "[agents.judge]
provider = \"claude\""; fi
wbp "$SCRATCH/d2.out" doctor --base "$BASE"
shown "$SCRATCH/d2.out" 6
check "[agents.judge] model: the judge line says haiku" "no 'agent judge: claude, model haiku' line" \
    grep -q "^agent judge: *claude, model haiku" "$SCRATCH/d2.out"

# --- 3. refused ------------------------------------------------------------------------------------------

RUNPROVIDER=gemini
[ "$SABOTAGE" = 1 ] && RUNPROVIDER=claude
config "[agents.run]
provider = \"$RUNPROVIDER\""
wbp "$SCRATCH/d3.out" doctor --base "$BASE"
shown "$SCRATCH/d3.out" 4
check "an unknown run provider: doctor is refused" "workbench doctor exited $RC" test "$RC" != 0
check "an unknown run provider: the message names the choices" "no '\"claude\" or \"codex\"' message" \
    grep -q "'provider' must be \"claude\" or \"codex\"" "$SCRATCH/d3.out"

REVIEWER='reviewer = "codex"
provider = "codex"'
[ "$SABOTAGE" = 1 ] && REVIEWER='provider = "codex"'
config "[review.stage.design]
prompt = \"docs/REVIEW.md\"
$REVIEWER"
wbp "$SCRATCH/d4.out" doctor --base "$BASE"
shown "$SCRATCH/d4.out" 4
check "reviewer and provider together: doctor is refused" "workbench doctor exited $RC" test "$RC" != 0
check "reviewer and provider together: the message names both keys" "no 'both choose the reviewer' message" \
    grep -q "'reviewer' and 'provider' both choose" "$SCRATCH/d4.out"

PROVIDER=gemini
[ "$SABOTAGE" = 1 ] && PROVIDER=codex
config "[providers.$PROVIDER]
executable = \"x\""
wbp "$SCRATCH/d5.out" doctor --base "$BASE"
shown "$SCRATCH/d5.out" 4
check "an unknown provider table: doctor is refused" "workbench doctor exited $RC" test "$RC" != 0
check "an unknown provider table: the message names it" "no 'unknown table [providers.gemini]' message" \
    grep -q "unknown table \[providers.gemini\]" "$SCRATCH/d5.out"

# --- 4. a coding model and effort ------------------------------------------------------------------------

EFFORT='reasoning_effort = "high"'
[ "$SABOTAGE" = 1 ] && EFFORT=""
config "[agents.run]
provider = \"codex\"
model = \"gpt-6-astra\"
$EFFORT"
wbp "$SCRATCH/d6.out" doctor --base "$BASE"
shown "$SCRATCH/d6.out" 6
check "run on codex with a model and an effort: doctor accepts it" "workbench doctor exited $RC" test "$RC" = 0
check "the run line names the model and the effort" "no 'agent run: codex, model gpt-6-astra, effort high' line" \
    grep -q "^agent run: *codex, model gpt-6-astra, effort high" "$SCRATCH/d6.out"
finish
