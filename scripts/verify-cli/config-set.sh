#!/bin/bash
# verify-cli scenario for `workbench config set` and `config unset` (P25 slice 2), on a clone of this repository. No turn is
# run, so it costs nothing.
#   bash scripts/verify-cli/config-set.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/config-set.sh   (the same, on a branch that contains origin/main)
# A config with a comment, a table and a trailing comment is edited: `set agents.goal.provider codex` appends the table and
# doctor's goal line says codex; `set agents.judge.model haiku` changes that one line (indent and comment kept) and nothing
# else; `unset agents.goal.provider` takes the table out again and doctor's goal line says none; a provider with no adapter
# and a key that is not an agent key are each refused (exit 6) with the file byte for byte as it was; with a thread active
# `set agents.run.model` still works and says the approval may need binding again; `config --help` names `config set`.
# Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start (nothing changed).
# VERIFY_CLI_SABOTAGE=1 sends a provider that exists and a key that is an agent key to the two refusals, so the two "refused"
# steps and the two "file untouched" steps must FAIL. The frame and the other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the refusals are sent values that are valid"

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
shown() { sed 's/^/    /' "$1" | head -${2:-6}; }
CFG="$P/.workbench/config.toml"

cat >"$CFG" <<'TOML'
# keep this comment
[tools]
available = ["Read"]
allowed = ["Read"]

[agents.judge]
  model = "sonnet"   # keep this one too
TOML
cp "$CFG" "$SCRATCH/before"

# --- 1. set creates a table, and doctor sees it ----------------------------------------------------------

wbp "$SCRATCH/s1.out" config set agents.goal.provider codex
shown "$SCRATCH/s1.out"
check "set: exits 0 and says old and new" "workbench config set exited $RC: $(head -c 200 "$SCRATCH/s1.out")" \
    bash -c 'test "$1" = 0 && grep -q "agents.goal.provider: (not set) -> codex" "$2"' _ "$RC" "$SCRATCH/s1.out"
check "set: the table is appended" "no [agents.goal] provider = codex at the end" \
    bash -c 'tail -2 "$1" | tr "\n" "|" | grep -q "^\[agents.goal\]|provider = \"codex\"|$"' _ "$CFG"
wbp "$SCRATCH/d1.out" doctor --base "$BASE"
check "set: doctor's goal line says codex" "no 'agent goal: codex' line" grep -q "^agent goal: *codex" "$SCRATCH/d1.out"

# --- 2. set changes one line and keeps the rest ----------------------------------------------------------

cp "$CFG" "$SCRATCH/mid"
wbp "$SCRATCH/s2.out" config set agents.judge.model haiku
shown "$SCRATCH/s2.out"
check "set: judge model changed, old value reported" "no 'sonnet -> haiku' line" grep -q "agents.judge.model: sonnet -> haiku" "$SCRATCH/s2.out"
check "set: the line keeps its indent and its comment" "no '  model = \"haiku\"   # keep this one too' line" \
    grep -qx '  model = "haiku"   # keep this one too' "$CFG"
check "set: exactly one line differs" "diff shows $(diff "$SCRATCH/mid" "$CFG" | grep -c '^[<>]') changed lines" \
    test "$(diff "$SCRATCH/mid" "$CFG" | grep -c '^[<>]')" = 2
check "set: the comment above is still there" "the first line changed" test "$(head -1 "$CFG")" = "# keep this comment"

# --- 3. unset takes the table out ------------------------------------------------------------------------

wbp "$SCRATCH/u1.out" config unset agents.goal.provider
shown "$SCRATCH/u1.out"
check "unset: exits 0 and says it is not set now" "workbench config unset exited $RC" \
    bash -c 'test "$1" = 0 && grep -q "agents.goal.provider: codex -> (not set)" "$2"' _ "$RC" "$SCRATCH/u1.out"
check "unset: the empty table is gone" "[agents.goal] is still in the config" bash -c '! grep -q "agents.goal" "$1"' _ "$CFG"
wbp "$SCRATCH/d2.out" doctor --base "$BASE"
check "unset: doctor's goal line says none" "no 'agent goal: none' line" grep -q "^agent goal: *none" "$SCRATCH/d2.out"

# --- 4. refusals leave the file alone --------------------------------------------------------------------

cp "$CFG" "$SCRATCH/pre-refusal"
PROVIDER=gemini; KEY=check_command
[ "$SABOTAGE" = 1 ] && { PROVIDER=claude; KEY=agents.ship.model; }
wbp "$SCRATCH/r1.out" config set agents.run.provider "$PROVIDER"
shown "$SCRATCH/r1.out"
RC1=$RC
check "a provider with no adapter is refused (exit 6)" "workbench exited $RC1: $(head -c 200 "$SCRATCH/r1.out")" test "$RC1" = 6
wbp "$SCRATCH/r2.out" config set "$KEY" make
shown "$SCRATCH/r2.out"
check "a key that is not an agent key is refused (exit 6)" "workbench exited $RC" test "$RC" = 6
check "the refused edits left the file byte for byte as it was" "the config changed" cmp -s "$CFG" "$SCRATCH/pre-refusal"
cp "$SCRATCH/pre-refusal" "$CFG"

# --- 5. allowed with a thread active, and the help -------------------------------------------------------

wbp "$SCRATCH/t1.out" goal new verify-cli-config-set --base "$BASE"
check "a thread is started" "workbench goal new exited $RC" test "$RC" = 0
wbp "$SCRATCH/s3.out" config set agents.run.model haiku
shown "$SCRATCH/s3.out"
check "set with a thread active: exits 0 and says the approval may need binding again" "exit $RC: $(head -c 200 "$SCRATCH/s3.out")" \
    bash -c 'test "$1" = 0 && grep -q "may have been approved for the old run settings" "$2"' _ "$RC" "$SCRATCH/s3.out"
wbp "$SCRATCH/h1.out" config --help
check "config --help names config set and config unset" "no 'config set' and 'config unset' in the help" \
    bash -c 'grep -q "config set <key> <value>" "$1" && grep -q "config unset <key>" "$1"' _ "$SCRATCH/h1.out"

finish
