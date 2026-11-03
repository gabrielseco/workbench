#!/bin/bash
# verify-cli scenario for `workbench chat` (P22 slice 6a), on a clone of this repository. The goal agent is a fake `codex` script the
# scenario writes, so no real agent is started and it costs nothing.
#   bash scripts/verify-cli/chat.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/chat.sh   (the same, on a branch that contains origin/main)
# With no [agents.goal] the command is refused (exit 6) and nothing is created. With a goal agent a first message starts a chat thread
# (no goal file, no worktree, no branch; the log says it is a chat), the reply is printed, a later message with the thread's id
# continues the conversation (the earlier messages reach the agent as quoted data), and `workbench chat <id>` prints it. A turn whose
# agent fails ends with exit 1 and the log says how it ended; a chat is the active thread (a second chat is refused, exit 6, until
# --abandon-active), and `status --json` says `kind: chat`.
# Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start. VERIFY_CLI_SABOTAGE=1 makes the fake agent fail
# every turn, so the steps that expect a reply, a continued conversation and a chat thread with a reply in its log must FAIL. The frame
# and the other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the fake agent fails every turn"

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
cfg="$P/.workbench/config.toml"

# The fake Codex: writes $FAKE/answer to the file after -o, keeps every run's arguments (the last is the prompt) and counts its runs.
# A file $FAKE/fail makes it exit 1 with that file's text on stderr. It refuses a folder outside a git repository unless it is given
# --skip-git-repo-check, as the real CLI does.
FAKE="$SCRATCH/fake-codex"
mkdir -p "$FAKE"
cat >"$FAKE/codex" <<FAKE_SCRIPT
#!/bin/sh
out=""; prev=""; tree=""
for a in "\$@"; do [ "\$prev" = "-o" ] && out="\$a"; [ "\$prev" = "-C" ] && tree="\$a"; prev="\$a"; done
echo run >> "$FAKE/runs"
n=\$(wc -l < "$FAKE/runs" | tr -d ' ')
printf '%s\n' "\$@" > "$FAKE/args_\$n"
case " \$* " in
  *" --skip-git-repo-check "*) ;;
  *) git -C "\$tree" rev-parse --git-dir >/dev/null 2>&1 || {
       echo "Not inside a trusted directory and --skip-git-repo-check was not specified." >&2
       exit 1
     } ;;
esac
if [ -f "$FAKE/fail" ]; then cat "$FAKE/fail" >&2; exit 1; fi
cat "$FAKE/answer" > "\$out"
echo "fake codex"
FAKE_SCRIPT
chmod +x "$FAKE/codex"
runs() { if [ -f "$FAKE/runs" ]; then wc -l <"$FAKE/runs" | tr -d ' '; else echo 0; fi; }
threads() { ls "$P/.workbench/threads" 2>/dev/null | wc -l | tr -d ' '; }
setgoal() { # <"-" for no goal agent>: rewrites the config with a Codex goal agent
    grep -v -e '^model = ' -e '^claude_path = ' "$SCRATCH/config.base" >"$SCRATCH/config.rest"
    { echo 'claude_path = "/usr/bin/false"'; cat "$SCRATCH/config.rest"
      if [ "$1" != "-" ]; then
          printf '\n[providers.codex]\nexecutable = "%s"\n\n[agents.goal]\nprovider = "codex"\n' "$FAKE/codex"
      fi; } >"$cfg"
}

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
cp "$cfg" "$SCRATCH/config.base"
echo "What should happen after the fifth try?" >"$FAKE/answer"
[ "$SABOTAGE" = 1 ] && echo "boom: the model is not available to this account" >"$FAKE/fail"

# --- 1. no [agents.goal] ------------------------------------------------------------------------------------

setgoal -
wbp "$SCRATCH/none.out" chat idea --message "could uploads retry?"
shown "$SCRATCH/none.out" 3
check "no [agents.goal]: chat is refused, exit 6" "workbench chat exited $RC" test "$RC" = 6
check "the refusal says to write the goal by hand" "no mention of goal new" grep -q "goal new" "$SCRATCH/none.out"
check "nothing was created and nothing ran" "threads: $(threads), runs: $(runs)" test "$(threads)$(runs)" = 00

# --- 2. a first message starts a chat thread ----------------------------------------------------------------

setgoal ""
wbp "$SCRATCH/first.out" chat idea --message "could uploads retry?"
shown "$SCRATCH/first.out" 6
check "the first message: exit 0" "workbench chat exited $RC" test "$RC" = 0
check "the reply is printed" "reply missing" grep -q "What should happen after the fifth try?" "$SCRATCH/first.out"
ID=$(sed -n 's/^chat \([^ ]*\) .*/\1/p' "$SCRATCH/first.out")
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "chat printed no thread id ($(head -3 "$SCRATCH/first.out"))"
check "a chat thread has no goal file" "goal.md exists" test ! -e "$P/.workbench/threads/$ID/goal.md"
check "and no worktree and no branch" "worktree or branch exists" \
    bash -c 'test ! -e "$1/.workbench/worktrees/$2" && ! git -C "$1" branch --list | grep -q "$2"' _ "$P" "$ID"
wbp "$SCRATCH/log1.out" log
shown "$SCRATCH/log1.out" 8
check "the log has the messages and how the turn ended" "log is not as expected" \
    bash -c 'grep -c "chat.message" "$1" | grep -q 2 && grep -q "chat.ended" "$1"' _ "$SCRATCH/log1.out"
wbp "$SCRATCH/status.json" status "$ID" --json
check "status --json says it is a chat and counts its turn" "status says otherwise" \
    py "assert d['kind']=='chat' and d['chat']['turns']==1 and d['chat']['last_end']=='ok' and d['chat']['open'] is False, d" <"$SCRATCH/status.json"

# --- 3. a later message continues it ------------------------------------------------------------------------

echo "Then say that, and I can make it a goal." >"$FAKE/answer"
wbp "$SCRATCH/second.out" chat "$ID" --message "give up and keep the file"
check "the second message: exit 0" "workbench chat exited $RC" test "$RC" = 0
check "the earlier messages reached the agent, quoted" "the prompt does not hold the conversation" \
    bash -c 'grep -q "^> could uploads retry?" "$1" && grep -q "^> What should happen after the fifth try?" "$1" && grep -q "^> give up and keep the file" "$1"' _ "$FAKE/args_2"
check "it is the same thread" "threads: $(threads)" test "$(threads)" = 1
wbp "$SCRATCH/show.out" chat "$ID"
shown "$SCRATCH/show.out" 12
check "chat <id> prints the conversation in order" "conversation is not as expected" \
    bash -c 'test "$(grep -c "^you:" "$1")" = 2 && test "$(grep -c "^agent:" "$1")" = 2 && grep -q "2 turn" "$1"' _ "$SCRATCH/show.out"

# --- 4. a turn that fails ends, and says how ----------------------------------------------------------------

echo "boom: the model is not available to this account" >"$FAKE/fail"
wbp "$SCRATCH/failed.out" chat "$ID" --message "and a third thing"
shown "$SCRATCH/failed.out" 4
rm -f "$FAKE/fail"
check "a failing agent: exit 1" "workbench chat exited $RC" test "$RC" = 1
check "it says why in the CLI's own words and that the log has the rest" "message is not as expected" \
    bash -c 'grep -q "boom: the model is not available" "$1" && grep -q "in the log" "$1"' _ "$SCRATCH/failed.out"
wbp "$SCRATCH/status2.json" status "$ID" --json
check "status: the last turn failed and none is open" "status says otherwise" \
    py "assert d['chat']['last_end']=='failed' and d['chat']['open'] is False and d['ended'] is None, d['chat']" <"$SCRATCH/status2.json"

# --- 5. one active thread -----------------------------------------------------------------------------------

wbp "$SCRATCH/second-chat.out" chat other --message "a second idea"
check "a chat is the active thread: another is refused, exit 6" "exit $RC" test "$RC" = 6
check "it names the active thread" "no thread named" grep -q "$ID" "$SCRATCH/second-chat.out"
wbp "$SCRATCH/abandon.out" chat other --message "a second idea" --abandon-active
check "--abandon-active ends the old chat and starts the new one" "exit $RC" test "$RC" = 0
wbp "$SCRATCH/all.json" status --all --json
check "the old chat is abandoned and the new one is a chat" "listing is not as expected" \
    py "t={x['thread']:x for x in d['threads']}; assert t['$ID']['ended']=='abandoned' and all(x['kind']=='chat' for x in t.values()) and len(t)==2, t" <"$SCRATCH/all.json"
finish
