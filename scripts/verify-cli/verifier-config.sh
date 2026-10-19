#!/bin/bash
# verify-cli scenario for `[verifier]` in the config and `workbench doctor` (P10 PR 1), on a clone of this repository.
# No turn is run, so it costs nothing.
#   bash scripts/verify-cli/verifier-config.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/verifier-config.sh   (the same, on a branch that contains origin/main)
# Doctor must read the skill from the base commit and print its path, size, sha256, model and tools; the
# sha256 must equal the one computed here from `git show`; an edit in the working tree must not change it; a missing
# skill and a symlinked one must be a warning (the symlink naming the real path); a bare `Bash` in `tools` must be
# refused at config load; `enabled = false` must print nothing, and no table at all must print the default skill path. Exit 0 only when every step passed, 1 when one failed,
# 2 when it refused to start (nothing changed). VERIFY_CLI_SABOTAGE=1 points the skill at a path that does not exist, so
# the steps that need the skill read (path and sha256 printed, equal to git's, unchanged by an edit) must FAIL. The frame
# and the other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

SKILL=.agents/skills/deliver/SKILL.md
LINKED=.claude/skills/deliver/SKILL.md
[ "$SABOTAGE" = 1 ] && { echo "    VERIFY_CLI_SABOTAGE=1: the skill path points at a file that does not exist"; SKILL=.agents/skills/no-such/SKILL.md; }

# A clone, so the project's own .workbench/config.toml and threads are never touched.
P="$SCRATCH/project"
g clone -q "$ROOT" "$P" || die "git clone failed"
# A branch of its own, since HEAD may be detached or a branch doctor's --base would not take.
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
config() { # <verifier table text>
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

# --- 1. the skill at the base ---------------------------------------------------------------------------

config "[verifier]
skill = \"$SKILL\"
model = \"sonnet\"
tools = [\"Read\", \"Bash(scripts/check-changed.sh:*)\"]"
wbp "$SCRATCH/d1.out" doctor --base "$BASE"
shown "$SCRATCH/d1.out"
check "doctor with a [verifier]: exit 0" "workbench doctor exited $RC" test "$RC" = 0
check "doctor prints the skill path at the base" "no 'verifier: $SKILL at $BASE' line" grep -q "^verifier: $SKILL at $BASE (" "$SCRATCH/d1.out"
check "doctor prints the model and tools" "model/tools lines are wrong" bash -c \
    'grep -q "^  model:  sonnet$" "$1" && grep -q "^  tools:  Read, Bash(scripts/check-changed.sh:\*)$" "$1"' _ "$SCRATCH/d1.out"

# The sha256 doctor prints is that of the text the model is given: the blob, trimmed.
want=$(git -C "$P" show "$BASE:$SKILL" 2>/dev/null | python3 -I -c "import hashlib,sys
t=sys.stdin.read().replace('\r\n','\n').strip()
print(hashlib.sha256(t.encode()).hexdigest()[:12], len(t.encode()))")
printed=$(sed -n "s/^verifier: .* (\([0-9]*\) bytes, sha256 \([0-9a-f]*\).*/\2 \1/p" "$SCRATCH/d1.out")
check "doctor's sha256 and size equal git's" "git says '$want', doctor says '$printed'" test -n "$want" -a "$want" = "$printed"

# --- 2. the working tree is not read --------------------------------------------------------------------

[ "$SABOTAGE" = 1 ] || echo "edited by the coding run, never committed" >>"$P/$SKILL"
wbp "$SCRATCH/d2.out" doctor --base "$BASE"
printed2=$(sed -n "s/^verifier: .* (\([0-9]*\) bytes, sha256 \([0-9a-f]*\).*/\2 \1/p" "$SCRATCH/d2.out")
check "an uncommitted edit does not change what doctor reads" "before '$printed', after '$printed2'" \
    test -n "$printed2" -a "$printed" = "$printed2"
[ "$SABOTAGE" = 1 ] || git -C "$P" checkout -q -- "$SKILL"

# --- 3. a skill that cannot be used is a warning --------------------------------------------------------

config "[verifier]
skill = \".claude/skills/none/SKILL.md\""
wbp "$SCRATCH/d3.out" doctor --base "$BASE"
shown "$SCRATCH/d3.out" 6
check "a missing skill: doctor still exits 0" "workbench doctor exited $RC" test "$RC" = 0
check "a missing skill: a warning names the path" "no warning naming .claude/skills/none/SKILL.md" \
    grep -q "warning: .*\.claude/skills/none/SKILL\.md" "$SCRATCH/d3.out"

config "[verifier]
skill = \"$LINKED\""
wbp "$SCRATCH/d4.out" doctor --base "$BASE"
shown "$SCRATCH/d4.out" 6
check "a symlinked skill: the warning names the real path" "no warning ending in : $(dirname "$LINKED" | sed 's/^.claude/.agents/')/SKILL.md" \
    grep -q "warning: .*symlink.*: \.agents/skills/deliver/SKILL\.md$" "$SCRATCH/d4.out"

# --- 4. refused at config load, and absent ---------------------------------------------------------------

config "[verifier]
skill = \"$SKILL\"
tools = [\"Read\", \"Bash\"]"
wbp "$SCRATCH/d5.out" doctor --base "$BASE"
shown "$SCRATCH/d5.out" 4
check "a bare Bash in tools: doctor is refused" "workbench doctor exited $RC" test "$RC" != 0
check "a bare Bash in tools: the message names the entry" "no ''tools' entry 'Bash'' in the output" grep -q "'tools' entry 'Bash'" "$SCRATCH/d5.out"

config "[verifier]
enabled = false"
wbp "$SCRATCH/d6.out" doctor --base "$BASE"
check "enabled = false: nothing about a verifier is printed" "a verifier line was printed" bash -c '! grep -q "verifier" "$1"' _ "$SCRATCH/d6.out"

config ""
wbp "$SCRATCH/d7.out" doctor --base "$BASE"
check "no [verifier]: the default skill is looked for" "no line naming .claude/skills/verify/SKILL.md" grep -q "^verifier: .claude/skills/verify/SKILL.md" "$SCRATCH/d7.out"
finish
