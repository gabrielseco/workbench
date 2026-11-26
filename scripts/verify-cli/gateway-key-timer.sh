#!/bin/bash
# verify-cli scenario for the OpenCode gateway key of a run no terminal started (a timer's `workbench task tick`), on a clone of this
# repository. `opencode` is a stand-in, the gateway URL leads nowhere and the key is made up, so it costs nothing.
#   bash scripts/verify-cli/gateway-key-timer.sh      (macOS; in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/gateway-key-timer.sh   (the same, on a branch that contains origin/main)
# A `fix: report` task is due and its agent runs on OpenCode. The tick runs as launchd would: the key's variable is not in its
# environment, and only the .zshrc of a stand-in home exports it. The tick must run the agent, which is given the forwarder's
# placeholder; the key must be in no output and no file of the project. With a home whose shell does not export it, the tick must fail
# naming the variable and start nothing. Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start.
# VERIFY_CLI_SABOTAGE=1 leaves the export out of the first home's .zshrc, so the steps of the first tick must FAIL. The frame and the
# other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

ORIGIN="$SCRATCH/origin.git"
P="$SCRATCH/project"
g clone -q --bare "$ROOT" "$ORIGIN" || die "git clone --bare failed"
g -C "$ORIGIN" update-ref refs/heads/main "$BASE_SHA" || die "could not set main in the bare copy"
g -C "$ORIGIN" symbolic-ref HEAD refs/heads/main || die "could not point the bare copy's HEAD at main"
g clone -q "$ORIGIN" "$P" || die "git clone failed"
g -C "$P" checkout -q -B main origin/main || die "could not check out main in the clone"
echo "==> clone at $P"
[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the stand-in home's .zshrc does not export the key"

SECRET="verify-cli-made-up-key-$RANDOM$RANDOM"
HOME1="$SCRATCH/home-with-key"; HOME2="$SCRATCH/home-without-key"
mkdir -p "$HOME1" "$HOME2"
if [ "$SABOTAGE" = 1 ]; then : >"$HOME1/.zshrc"; else echo "export VERIFY_CLI_TICK_KEY=$SECRET" >"$HOME1/.zshrc"; fi
: >"$HOME2/.zshrc"

FAKE="$SCRATCH/opencode"
cat >"$FAKE" <<SH
#!/bin/sh
printf 'key=%s\\n' "\$VERIFY_CLI_TICK_KEY" >>"$SCRATCH/opencode.ran"
echo '{"type":"step_start","sessionID":"ses_1","part":{"type":"step-start"}}'
echo '{"type":"text","sessionID":"ses_1","part":{"type":"text","text":"Nothing changed."}}'
echo '{"type":"step_finish","sessionID":"ses_1","part":{"type":"step-finish","reason":"stop","cost":0.001,"tokens":{"input":1,"output":1}}}'
SH
chmod +x "$FAKE"

RC=0
wbp() { # <out> <home> args...: a workbench command in the clone as a timer would run it: that home, zsh, no key in the environment
    local o=$1 home=$2; shift 2
    echo "workbench $*   (in the clone, HOME=$home, no key in the environment)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    ( cd "$P" && with_timeout "$T_WB" env -u VERIFY_CLI_TICK_KEY HOME="$home" SHELL=/bin/zsh "$WB" "$@" >"$o" 2>&1 )
    RC=$?
}
shown() { sed 's/^/    /' "$1" | head -${2:-8}; }
TASK="$P/.workbench/tasks/nightly"
LOG="$TASK/runs.jsonl"
mkdir -p "$TASK"
printf -- '---\nevery: 5m\nfix: report\n---\nSay what changed.\n' >"$TASK/task.md"
backdate() { sed -E 's/"ts":"[^"]*"/"ts":"2025-01-01T00:00:00.000Z"/' "$LOG" >"$LOG.new" && mv "$LOG.new" "$LOG"; }

wbp "$SCRATCH/init.out" "$HOME1" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
cfg="$P/.workbench/config.toml"
{ grep -v -e '^model = ' "$cfg"
  printf '\n[providers.opencode]\nbase_url = "http://127.0.0.1:9/v1"\napi_key_env = "VERIFY_CLI_TICK_KEY"\nexecutable = "%s"\n' "$FAKE"
  printf '\n[agents.plan]\nprovider = "opencode"\nmodel = "none"\n'; } >"$cfg.new" && mv "$cfg.new" "$cfg"
wbp "$SCRATCH/approve.out" "$HOME1" task approve nightly
check "the task is approved" "exit $RC: $(head -c 200 "$SCRATCH/approve.out")" test "$RC" = 0
backdate

wbp "$SCRATCH/tick1.out" "$HOME1" task tick; shown "$SCRATCH/tick1.out"
check "a tick with no key in its environment runs the task: exit 0" "exit $RC: $(head -c 250 "$SCRATCH/tick1.out")" test "$RC" = 0
check "the agent ran and was given the forwarder's placeholder" "saw: $(cat "$SCRATCH/opencode.ran" 2>/dev/null | head -1 | cut -c1-20)" \
    bash -c 'grep -qx "key=forwarder" "$1"' _ "$SCRATCH/opencode.ran"
check "the run is on record as a report" "$(tail -1 "$LOG" | cut -c1-200)" \
    bash -c 'tail -1 "$1" | grep -q "\"kind\":\"task.run.ended\"" && tail -1 "$1" | grep -q "\"outcome\":\"report"' _ "$LOG"
check "the key is in no output and no file of the project" "found it" \
    bash -c '! grep -rqF "$1" "$2/.workbench" "$3"' _ "$SECRET" "$P" "$SCRATCH/tick1.out"

backdate
: >"$SCRATCH/opencode.ran"
wbp "$SCRATCH/tick2.out" "$HOME2" task tick; shown "$SCRATCH/tick2.out"
check "a home that does not export it: the tick fails and names the variable" "exit $RC: $(head -c 250 "$SCRATCH/tick2.out")" \
    bash -c '[ "$1" != 0 ] && grep -q "VERIFY_CLI_TICK_KEY" "$2"' _ "$RC" "$SCRATCH/tick2.out"
check "and starts no agent" "it ran" test ! -s "$SCRATCH/opencode.ran"
finish
