#!/bin/bash
# verify-cli scenario for screenshots in `workbench chat --attach`, on a clone of this repository. The goal agent is a fake `codex` script
# the scenario writes, so no real agent is started and it costs nothing.
#   bash scripts/verify-cli/chat-attach.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/chat-attach.sh   (the same, on a branch that contains origin/main)
# A message sent with --attach reaches the agent as images (`-i`) and is kept in the thread's chat-attachments/ folder (not the goal's
# attachments/), the log and `status --json` count it, and the next message shows the agent the earlier screenshot again as well as the new
# one, in the order sent, with the prompt saying which message sent which. A file that is not an image is refused (exit 6) before the
# agent runs. A chat holds 10 screenshots: the one after is refused (exit 6) and says so, nothing run. `abandon` removes the folder.
# Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start. VERIFY_CLI_SABOTAGE=1 sends the messages without
# --attach, so the steps that expect images at the agent, kept files, counts, the carried-over screenshot and the cap must FAIL.
# The frame and the other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the messages are sent without --attach"

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
echo "That is the upload dialog." >"$FAKE/answer"
setgoal ""

# Real PNG files: the core checks the bytes, not the name.
python3 -I - "$SCRATCH" <<'PY' || die "could not write the test images"
import struct, sys, zlib
def png(path, grey):
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    rows = b"".join(b"\x00" + bytes([grey]) * 4 for _ in range(4))
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 4, 4, 8, 0, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
png(sys.argv[1] + "/first.png", 40)
png(sys.argv[1] + "/second.png", 200)
PY
echo "this is not a picture" >"$SCRATCH/fake.png"
A1=(--attach "$SCRATCH/first.png"); A2=(--attach "$SCRATCH/second.png")
if [ "$SABOTAGE" = 1 ]; then A1=(); A2=(); fi

# --- 1. a first message with a screenshot --------------------------------------------------------------------

wbp "$SCRATCH/one.out" chat shots --message "what is this dialog?" ${A1[@]+"${A1[@]}"}
shown "$SCRATCH/one.out" 4
check "a message with a screenshot: exit 0 and the reply is printed" "exit $RC" \
    bash -c 'test "$1" = 0 && grep -q "upload dialog" "$2"' _ "$RC" "$SCRATCH/one.out"
ID=$(ls "$P/.workbench/threads" | head -1)
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "the first message made no thread ($(head -3 "$SCRATCH/one.out"))"
check "the agent was sent the image" "args: $(tr '\n' ' ' <"$FAKE/args_1" | cut -c1-160)" \
    bash -c 'grep -qx -e "-i" "$1" && grep -q "images/1.png" "$1"' _ "$FAKE/args_1"
check "the prompt says the first message came with screenshot 1.png" "prompt is not as expected" \
    grep -q "says now (with screenshot 1.png)" "$FAKE/args_1"
check "the screenshot is kept in the chat's own folder, byte for byte" "no copy" \
    cmp -s "$SCRATCH/first.png" "$P/.workbench/threads/$ID/chat-attachments/1.png"
check "and not in the goal's attachments folder" "attachments/ exists" test ! -e "$P/.workbench/threads/$ID/attachments"
wbp "$SCRATCH/log1.out" log
check "the log says the message came with a screenshot" "log is not as expected" grep -q "chat you \[+1 screenshot(s)\]" "$SCRATCH/log1.out"
wbp "$SCRATCH/status1.json" status "$ID" --json
check "status --json counts the screenshot" "status says otherwise" py "assert d['chat']['images']==1, d['chat']" <"$SCRATCH/status1.json"

# --- 2. a later message: the agent sees both ------------------------------------------------------------------

wbp "$SCRATCH/two.out" chat "$ID" --message "and this second one?" ${A2[@]+"${A2[@]}"}
check "a second message with a screenshot: exit 0" "exit $RC" test "$RC" = 0
check "the agent gets the first screenshot again and the new one, in the order sent" "args: $(tr '\n' ' ' <"$FAKE/args_2" | cut -c1-200)" \
    bash -c 'a=$(grep -n "images/1.png" "$1" | head -1 | cut -d: -f1); b=$(grep -n "images/2.png" "$1" | head -1 | cut -d: -f1); test -n "$a" && test -n "$b" && test "$a" -lt "$b"' _ "$FAKE/args_2"
check "the prompt says which message sent which" "prompt is not as expected" \
    bash -c 'grep -q "said (with screenshot 1.png)" "$1" && grep -q "says now (with screenshot 2.png)" "$1"' _ "$FAKE/args_2"
wbp "$SCRATCH/show.out" chat "$ID"
check "chat <id> shows which messages came with screenshots" "conversation is not as expected" \
    bash -c 'test "$(grep -c "^you \[+1 screenshot(s)\]:" "$1")" = 2' _ "$SCRATCH/show.out"

# --- 3. a file that is not an image ----------------------------------------------------------------------------

before=$(runs)
wbp "$SCRATCH/bad.out" chat "$ID" --message "look at this" --attach "$SCRATCH/fake.png"
shown "$SCRATCH/bad.out" 2
check "a text file named .png is refused, exit 6" "exit $RC" test "$RC" = 6
check "it says it is not an image, and the agent did not run" "runs: $before -> $(runs)" \
    bash -c 'grep -q "not a PNG, JPEG, GIF or WebP" "$1" && test "$2" = "$3"' _ "$SCRATCH/bad.out" "$before" "$(runs)"

# --- 4. the cap --------------------------------------------------------------------------------------------------

five=(); three=(); one=()
if [ "$SABOTAGE" != 1 ]; then
    for _ in 1 2 3 4 5; do five+=(--attach "$SCRATCH/first.png"); done
    for _ in 1 2 3; do three+=(--attach "$SCRATCH/second.png"); done
    one=(--attach "$SCRATCH/first.png")
fi
wbp "$SCRATCH/five.out" chat "$ID" --message "five more" ${five[@]+"${five[@]}"}
wbp "$SCRATCH/three.out" chat "$ID" --message "three more" ${three[@]+"${three[@]}"}
before=$(runs)
wbp "$SCRATCH/cap.out" chat "$ID" --message "one too many" ${one[@]+"${one[@]}"}
shown "$SCRATCH/cap.out" 2
check "the eleventh screenshot is refused, exit 6" "exit $RC" test "$RC" = 6
check "the refusal names the cap and nothing ran" "message: $(head -1 "$SCRATCH/cap.out")" \
    bash -c 'grep -q "at most 10 screenshots" "$1" && test "$2" = "$3"' _ "$SCRATCH/cap.out" "$before" "$(runs)"
check "ten are kept" "files: $(ls "$P/.workbench/threads/$ID/chat-attachments" 2>/dev/null | wc -l)" \
    bash -c 'test "$(ls "$1" 2>/dev/null | wc -l | tr -d " ")" = 10' _ "$P/.workbench/threads/$ID/chat-attachments"

# --- 5. abandon removes them -----------------------------------------------------------------------------------

wbp "$SCRATCH/abandon.out" abandon
check "abandon ends the chat" "abandon exited $RC" test "$RC" = 0
check "and its screenshots are gone" "folder still there" test ! -e "$P/.workbench/threads/$ID/chat-attachments"
finish
