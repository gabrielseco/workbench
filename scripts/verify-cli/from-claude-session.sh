#!/bin/bash
# verify-cli scenario for `workbench goal draft <name> --from-claude-session [<id>]`, on a clone of this repository. The goal
# agent is a fake `codex` script that records its prompt, so no real agent is started and it costs nothing.
#   bash scripts/verify-cli/from-claude-session.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/from-claude-session.sh   (the same, on a branch that contains origin/main)
# The session is a real one: the newest Claude Code session of this repository on this machine (VERIFY_CLI_SESSION=<file>
# names another), copied into a scratch Claude config folder under the clone's project folder name, with two lines added at
# its end: a tool result and a message of the person's, each carrying a marker. Workbench runs with a scratch HOME and no
# CLAUDE_CONFIG_DIR, as from the Dock. With nothing configured it is refused (exit 6), naming ~/.claude and claude_config_dir;
# with claude_config_dir in the global config it drafts a draft thread from the newest session, the prompt holding the person's
# marker quoted and not the tool result's; an unknown id, an unsafe id and --request with the flag are refused.
# Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start. VERIFY_CLI_SABOTAGE=1 points
# claude_config_dir at an empty folder and puts the tool result's marker in the person's message, so the steps "a draft thread
# from the newest session", "the person's words reach the drafter, quoted", "a tool result does not reach the drafter" and "an
# id that names the session drafts too" must FAIL. The frame and the other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: claude_config_dir names an empty folder, and the tool result is said by the person"

folder_of() { python3 -I -c 'import os,re,sys; print(re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(sys.argv[1])))' "$1"; }

# --- the real session --------------------------------------------------------------------------------------------------------

REAL=${VERIFY_CLI_SESSION:-}
if [ -z "$REAL" ]; then
    # Where Claude Code may keep this repository's sessions on this machine: the newest file of a project folder named for it.
    REAL=$(python3 -I - "$HOME" "${CLAUDE_CONFIG_DIR:-}" <<'PY'
import glob, os, sys
home, env = sys.argv[1], sys.argv[2]
dirs = ([env] if env else []) + [os.path.join(home, ".claude")] + glob.glob(os.path.join(home, ".claude-*"))
files = [f for d in dirs for f in glob.glob(os.path.join(d, "projects", "*-workbench", "*.jsonl"))]
print(max(files, key=os.path.getmtime) if files else "")
PY
)
fi
[ -n "$REAL" ] && [ -f "$REAL" ] || die "no Claude Code session of this repository found; name one with VERIFY_CLI_SESSION=<file>"
echo "==> session $(basename "$REAL") ($(wc -c <"$REAL" | tr -d ' ') bytes)"

P="$SCRATCH/project"
g clone -q "$ROOT" "$P" || die "git clone failed"
BASE=verify-cli-base
git -C "$P" checkout -q -b "$BASE" || die "could not make the base branch in the clone"
echo "==> clone at $P, base $BASE"

H="$SCRATCH/home"
CC="$SCRATCH/claude-config"
ID=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
SESSIONS="$CC/projects/$(folder_of "$P")"
mkdir -p "$H/.workbench" "$SESSIONS" "$SCRATCH/empty-config"
SAID="PERSON-MARKER-$$ please make retries back off"
TOOL="TOOL-RESULT-MARKER-$$"
[ "$SABOTAGE" = 1 ] && SAID="$SAID $TOOL"
{ cat "$REAL"; echo
  python3 -I -c 'import json,sys; print(json.dumps({"type":"user","toolUseResult":{"stdout":sys.argv[1]},"message":{"role":"user","content":[{"type":"tool_result","content":sys.argv[1]}]}}))' "$TOOL"
  python3 -I -c 'import json,sys; print(json.dumps({"type":"user","message":{"role":"user","content":sys.argv[1]}}))' "$SAID"
} >"$SESSIONS/$ID.jsonl"
# An older session beside it: without an id the newest is the one drafted from.
echo '{"type":"user","message":{"role":"user","content":"OLDER-SESSION"}}' >"$SESSIONS/11111111-2222-3333-4444-555555555555.jsonl"
touch -t 202001010000 "$SESSIONS/11111111-2222-3333-4444-555555555555.jsonl"

RC=0
wbp() { # <out> args...: a workbench command in the clone with the scratch HOME and no CLAUDE_CONFIG_DIR; sets RC
    local o=$1; shift
    echo "workbench $*   (in the clone, HOME=$H)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    ( cd "$P" && unset CLAUDE_CONFIG_DIR && export HOME="$H" && with_timeout "$T_WB" "$WB" "$@" >"$o" 2>&1 )
    RC=$?
}
shown() { sed 's/^/    /' "$1" | head -${2:-12}; }
threads() { ls "$P/.workbench/threads" 2>/dev/null | wc -l | tr -d ' '; }

# The fake Codex: records its arguments (the prompt is one of them), writes $FAKE/answer to the file after -o.
FAKE="$SCRATCH/fake-codex"
mkdir -p "$FAKE"
cat >"$FAKE/codex" <<FAKE_SCRIPT
#!/bin/sh
out=""; prev=""
for a in "\$@"; do [ "\$prev" = "-o" ] && out="\$a"; prev="\$a"; done
printf '%s\n' "\$@" > "$FAKE/prompt"
cat "$FAKE/answer" > "\$out"
echo "fake codex"
FAKE_SCRIPT
chmod +x "$FAKE/codex"
echo '{"title": "Back off retries", "request": "Retry uploads with backoff.", "criteria": [{"text": "Delay grows.", "proof": "cat retry.txt"}], "out_of_scope": []}' >"$FAKE/answer"

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
cfg="$P/.workbench/config.toml"
printf '\n[providers.codex]\nexecutable = "%s"\n\n[agents.goal]\nprovider = "codex"\n' "$FAKE/codex" >>"$cfg"

# --- 1. nothing configured: refused, naming where it looked ------------------------------------------------------------------

wbp "$SCRATCH/none.out" goal draft backoff --from-claude-session
shown "$SCRATCH/none.out" 8
check "no claude_config_dir and no CLAUDE_CONFIG_DIR: refused, exit 6" "exit $RC" test "$RC" = 6
check "the refusal names ~/.claude of this HOME and says to set claude_config_dir" "no such message" \
    bash -c 'grep -q "$2/.claude/projects" "$1" && grep -q "claude_config_dir" "$1"' _ "$SCRATCH/none.out" "$H"
check "nothing was created" "threads exist: $(threads)" test "$(threads)" = 0

# --- 2. claude_config_dir in the global config: a draft from the newest session ---------------------------------------------

DIR="$CC"; [ "$SABOTAGE" = 1 ] && DIR="$SCRATCH/empty-config"
printf 'claude_config_dir = "%s"\n' "$DIR" >"$H/.workbench/config.toml"
wbp "$SCRATCH/ok.out" goal draft backoff --from-claude-session --base "$BASE"
shown "$SCRATCH/ok.out" 10
THREAD=$(sed -n 's/^drafted \([^ ]*\) .*/\1/p' "$SCRATCH/ok.out")
check "a draft thread from the newest session" "exit $RC, thread '$THREAD'" \
    bash -c 'test "$1" = 0 && test -n "$2" && grep -q "$3" "$4" && grep -q "^status: draft" "$5/.workbench/threads/$2/goal.md" && grep -q "^base: $6" "$5/.workbench/threads/$2/goal.md"' \
    _ "$RC" "$THREAD" "$ID" "$SCRATCH/ok.out" "$P" "$BASE"
check "the person's words reach the drafter, quoted" "the marker is not in the prompt as a quoted line" \
    bash -c 'test -f "$1" && grep -q "^> PERSON-MARKER-" "$1" && ! grep -q "OLDER-SESSION" "$1"' _ "$FAKE/prompt"
check "a tool result does not reach the drafter" "the tool result's marker is in the prompt" \
    bash -c 'test -f "$1" && ! grep -q "$2" "$1"' _ "$FAKE/prompt" "$TOOL"
rm -f "$FAKE/prompt"

# --- 3. an id: that session; unknown and unsafe ids, and --request with it, are refused ---------------------------------------

wbp "$SCRATCH/byid.out" goal draft backoff2 --from-claude-session "$ID" --base "$BASE"
shown "$SCRATCH/byid.out" 4
check "an id that names the session drafts too" "exit $RC" \
    bash -c 'test "$1" = 0 && grep -q "^> PERSON-MARKER-" "$2"' _ "$RC" "$FAKE/prompt"
wbp "$SCRATCH/unknown.out" goal draft backoff3 --from-claude-session 99999999-0000-0000-0000-000000000000
shown "$SCRATCH/unknown.out" 4
check "an unknown id is refused, exit 6, naming where it looked" "exit $RC" \
    bash -c 'test "$1" = 6 && grep -q "Looked in" "$2"' _ "$RC" "$SCRATCH/unknown.out"
wbp "$SCRATCH/unsafe.out" goal draft backoff3 --from-claude-session ../../etc/passwd
check "an id that is not one is refused before it becomes a path, exit 6" "exit $RC" \
    bash -c 'test "$1" = 6 && grep -q "not a Claude Code session id" "$2"' _ "$RC" "$SCRATCH/unsafe.out"
wbp "$SCRATCH/both.out" goal draft backoff3 --from-claude-session --request "x"
check "--request with it is a usage error, exit 2" "exit $RC" test "$RC" = 2
finish
