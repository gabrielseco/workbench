#!/bin/bash
# verify-cli scenario for `[run]` (P16), with the real `claude`, on a clone of this repository.
#   bash scripts/verify-cli/run.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/run.sh   (the same, on a branch that contains origin/main)
# In the clone, a throwaway base commit adds a probe app (a static file server on $WORKBENCH_PORT), a probe skill and a
# helper that fetches the app's page into the proof folder. `[run]` starts the app. A real coding turn writes one file,
# then the verifier (on by default) runs the probe skill on the real claude with only the helper and Read allowed. The
# helper can only succeed against the app Workbench started: it must be up before the verifier, answer on the port
# `run.started` names, be handed to the verifier as WORKBENCH_PORT, and be gone with the turn. Costs at most two turns
# at the cap ($VERIFY_CLI_BUDGET_USD, default 0.50, on $VERIFY_CLI_MODEL, default haiku), usually a few cents. Exit 0
# only when every step passed, 1 when one failed, 2 when it refused to start (nothing changed). VERIFY_CLI_SABOTAGE=1
# makes the helper ignore the app, so the steps that need the app's page in the proof (the marker, the port) must FAIL.
# The frame and the other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

SKILL=.agents/skills/run-probe/SKILL.md
[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the helper does not ask the app"

P="$SCRATCH/project"
g clone -q "$ROOT" "$P" || die "git clone failed"
cd "$P" || die "cannot enter the clone"
BASE=verify-cli-base
g checkout -q -b "$BASE" || die "could not make the base branch in the clone"
mkdir -p "$(dirname "$SKILL")" scripts scratch app
cat >"$SKILL" <<'SKILLTEXT'
# Probe verifier

You are checking a Workbench feature, not an app. Do exactly this, with no extra steps:

1. Run `scripts/fetch-page.sh` with the Bash tool. It asks the running app for its page and writes probe.txt into the proof folder.
2. Read `scratch/run-probe.txt` in the working directory with the Read tool.
3. Reply with one line per criterion: its id, `holds` or `does not hold`, and what you saw. Nothing else.
SKILLTEXT
echo "run-probe-app-marker" >app/index.html
cat >scripts/probe-app.sh <<'APP'
#!/bin/sh
# verify-cli probe app: serves ./app on the port Workbench picked, and says when it is up.
echo "probe app serving on $WORKBENCH_PORT"
cd app || exit 1
exec python3 -m http.server "$WORKBENCH_PORT" --bind 127.0.0.1
APP
cat >scripts/fetch-page.sh <<'HELPER'
#!/bin/sh
# verify-cli probe helper: the app's page, and the port it was fetched from, in the proof folder.
if [ "${PROBE_IGNORE_APP:-0}" = 1 ]; then
    printf 'port=none\nno app asked\n' >"$WORKBENCH_PROOF_DIR/probe.txt"
else
    { printf 'port=%s\n' "$WORKBENCH_PORT"; curl -fsS "http://127.0.0.1:$WORKBENCH_PORT/"; } >"$WORKBENCH_PROOF_DIR/probe.txt"
fi
HELPER
[ "$SABOTAGE" = 1 ] && sed -i.bak 's/PROBE_IGNORE_APP:-0/PROBE_IGNORE_APP:-1/' scripts/fetch-page.sh && rm -f scripts/fetch-page.sh.bak
chmod +x scripts/probe-app.sh scripts/fetch-page.sh
g add -A
g -c user.name=verify-cli -c user.email=verify-cli@example.invalid commit -q -m "verify-cli: probe app, skill and helper" \
    || die "could not commit the probe in the clone"
echo "==> clone at $P, base $BASE"

ROOT=$P
BASE_SHA=$(g rev-parse "$BASE")
wb "$T_WB" init >/dev/null
cat >"$P/.workbench/config.toml" <<TOML
default_budget_usd = $BUDGET_USD
model = "$MODEL"

[tools]
available = ["Read", "Edit", "Write"]
allowed = ["Read", "Edit", "Write"]

[run]
command = "scripts/probe-app.sh"
ready_url = "http://127.0.0.1:{port}/"
ready_timeout_s = 60

[verifier]
skill = "$SKILL"
model = "$MODEL"
tools = ["Read", "Bash(scripts/fetch-page.sh:*)"]
budget_usd = $BUDGET_USD
timeout_min = 5
TOML

GOAL_SRC="$SCRATCH/goal.md"
cat >"$GOAL_SRC" <<GOAL
---
id: verify-cli-run
title: verify-cli run scenario
base: $BASE
budget_usd: $BUDGET_USD
turn_timeout_min: 5
---

## Request

This is a throwaway thread that tests \`[run]\`. Create one new file, \`scratch/run-probe.txt\`, holding the single line
\`run-probe\`. Do not commit and do nothing else.

## Criteria

- [c1] \`scratch/run-probe.txt\` exists with the line \`run-probe\`.
  - proof: the diff shows that one new file and nothing else

## Out of scope

- Any other file, and committing.
GOAL

created=$(wb "$T_WB" goal new verify-cli-run --base "$BASE" --from "$GOAL_SRC") || { echo "$created"; die "goal new failed"; }
echo "$created"
ID=$(echo "$created" | sed -n 's/^created //p')
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id"
THREAD_DIR="$P/.workbench/threads/$ID"
perl -pi -e "s/^budget_usd: .*/budget_usd: $BUDGET_USD/; s/^turn_timeout_min: .*/turn_timeout_min: 5/; s/^# model: .*/model: $MODEL/" \
    "$THREAD_DIR/goal.md"
wb "$T_WB" goal approve "$ID"

# --- 0. doctor knows the command -----------------------------------------------------------------------------

wb "$T_WB" doctor >"$SCRATCH/doctor.out" 2>&1
sed -n '/^run:/,/^$/p' "$SCRATCH/doctor.out" | sed 's/^/    /' | head -5
check "doctor reports the run command and its ready check" "no 'run: scripts/probe-app.sh' / 'ready:' in doctor" \
    bash -c 'grep -q "^run: scripts/probe-app.sh" "$1" && grep -q "ready:  http://127.0.0.1:{port}/ answers" "$1"' _ "$SCRATCH/doctor.out"

# --- 1. the coding turn, then the verifier with the app ---------------------------------------------------------

run_thread

LOG="$SCRATCH/log.json"
wb "$T_WB" log "$ID" --json >"$LOG"
marks=$(py "print(' '.join(e['kind'] for e in lines if e['kind'].startswith(('verifier.', 'run.'))))" <"$LOG")
check "the app is started after verifier.started and ended before verifier.ended, once each" "events: '$marks'" \
    test "$marks" = "verifier.started run.started run.ended verifier.ended"
check "the log says it in words" "no 'app starting' / 'app stopped' line in workbench log" \
    bash -c 'wb_out=$("$1" log "$2" 2>&1); [[ $wb_out == *"app starting: scripts/probe-app.sh"* && $wb_out == *"app stopped"* ]]' _ "$WB" "$ID"
ended_ok=$(py "e=[x['data'] for x in lines if x['kind']=='verifier.ended']; print(e[-1].get('ok') if e else None)" <"$LOG")
check "verifier.ended is ok" "ok is '$ended_ok': $(py "e=[x['data'] for x in lines if x['kind']=='verifier.ended']; print(e[-1].get('reason') if e else '')" <"$LOG")" \
    test "$ended_ok" = True
run_ready=$(py "e=[x['data'] for x in lines if x['kind']=='run.ended']; print(e[-1].get('ready'), e[-1].get('exited_early') if e else '')" <"$LOG")
check "run.ended: it was ready and was still running when it was stopped" "got: $run_ready" test "$run_ready" = "True False"
PORT=$(py "s=[x['data'] for x in lines if x['kind']=='run.started']; print(s[-1].get('port') if s else '')" <"$LOG")
check "run.started names a port" "port '$PORT'" bash -c '[[ $1 =~ ^[0-9]+$ && $1 -gt 1023 ]]' _ "${PORT:-}"

# The helper can only have fetched the page from the app Workbench started, on the port it picked.
PROOF="$THREAD_DIR/proof/turn-1/probe.txt"
check "probe.txt is in the turn's proof folder" "no $PROOF" test -f "$PROOF"
check "the page the helper fetched is the app's" "content: $(cat "$PROOF" 2>/dev/null)" grep -q '^run-probe-app-marker$' "$PROOF"
check "the verifier's tools had the app's port (the one run.started names)" "content: $(head -1 "$PROOF" 2>/dev/null), port $PORT" \
    grep -qx "port=$PORT" "$PROOF"

# --- 2. gone with the turn ---------------------------------------------------------------------------------------

sleep 1
leftover=$(ps -axo command= | grep -c "[h]ttp.server ${PORT:-0} " || true)
check "the app is not running after the turn" "$leftover process(es) still serving on $PORT" test "${leftover:-0}" = 0
check "nothing answers on the port" "something still answers on $PORT" \
    bash -c '! curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$1/"' _ "${PORT:-0}"
check "no runner.json is left" "the thread still has a runner" test ! -e "$THREAD_DIR/runner.json"

wb "$T_WB" abandon "$ID" >/dev/null 2>&1
ended=$(wb "$T_WB" status "$ID" --json | py "print(d['ended'])")
check "abandon ends the thread" "status says ended: $ended" test "$ended" = abandoned
finish
