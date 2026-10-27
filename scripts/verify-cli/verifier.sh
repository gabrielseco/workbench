#!/bin/bash
# verify-cli scenario for `workbench verifier` (P10 PR 2 and 3), with the real `claude`, on a clone of this repository.
#   bash scripts/verify-cli/verifier.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/verifier.sh   (the same, on a branch that contains origin/main)
# In the clone, a throwaway base commit adds a probe skill and a helper that writes probe.txt and probe.png into the proof
# folder. A
# real coding turn writes one file, then the verifier (on by default) runs the probe skill on the real claude by itself, with only the
# helper and Read allowed. It must end in exactly one verifier.ended with ok, name the skill and its sha256 (equal to
# git's), run with the flags and tools the config names and no prompt in the log, leave probe.txt in the turn's proof
# folder, record the PNG as proof.added and show it, with the verifier's note, in `review` (the criterion `screenshot:
# probe` reads "see screenshot", the report claiming success changes no other row, and `review --json` lists the proof),
# record a cost, be refused a second time without --again, and leave no runner.json. Costs at most two turns
# at the cap ($VERIFY_CLI_BUDGET_USD, default 0.50, on $VERIFY_CLI_MODEL, default haiku), usually a few cents. Exit 0
# only when every step passed, 1 when one failed, 2 when it refused to start (nothing changed). VERIFY_CLI_SABOTAGE=1
# takes the helper out of the verifier's tools, so it cannot leave the files: the steps that need them (probe.txt in the
# proof folder, listed in files, with the helper's text; probe.png recorded as proof and shown by review) must FAIL. The frame and the other switches are in
# lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

TOOLS='"Read", "Bash(scripts/write-proof.sh:*)"'
[ "$SABOTAGE" = 1 ] && { echo "    VERIFY_CLI_SABOTAGE=1: the helper is not among the verifier's tools"; TOOLS='"Read"'; }
SKILL=.agents/skills/verifier-probe/SKILL.md

# A clone is the project: its own .workbench, threads and worktrees, all removed with the scratch folder.
P="$SCRATCH/project"
g clone -q "$ROOT" "$P" || die "git clone failed"
cd "$P" || die "cannot enter the clone"
BASE=verify-cli-base
g checkout -q -b "$BASE" || die "could not make the base branch in the clone"
mkdir -p "$(dirname "$SKILL")" scripts scratch
cat >"$SKILL" <<'SKILLTEXT'
# Probe verifier

You are checking a Workbench feature, not an app. Do exactly this, with no extra steps:

1. Run `scripts/write-proof.sh probe` with the Bash tool. It writes probe.txt and probe.png into the proof folder.
2. Read `scratch/verifier-probe.txt` in the working directory with the Read tool.
3. Reply with one line per criterion: its id, `holds` or `does not hold`, and what you saw. Nothing else.
SKILLTEXT
cat >scripts/write-proof.sh <<'HELPER'
#!/bin/sh
# verify-cli probe helper: leaves a text file and a PNG in the proof folder.
printf 'verifier probe %s\n' "$1" >"$WORKBENCH_PROOF_DIR/probe.txt"
cp scripts/probe.png "$WORKBENCH_PROOF_DIR/probe.png"
HELPER
PNG_HEX=89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c6360000002000001e221bc330000000049454e44ae426082
python3 -I -c "import sys; sys.stdout.buffer.write(bytes.fromhex(sys.argv[1]))" "$PNG_HEX" >scripts/probe.png
chmod +x scripts/write-proof.sh
g add -A
g -c user.name=verify-cli -c user.email=verify-cli@example.invalid commit -q -m "verify-cli: probe skill" \
    || die "could not commit the probe skill in the clone"
echo "==> clone at $P, base $BASE"

ROOT=$P
BASE_SHA=$(g rev-parse "$BASE")
wb "$T_WB" init >/dev/null
cat >"$P/.workbench/config.toml" <<TOML
default_budget_usd = $BUDGET_USD

[agents.run]
model = "$MODEL"

[tools]
available = ["Read", "Edit", "Write"]
allowed = ["Read", "Edit", "Write"]

[verifier]
skill = "$SKILL"
model = "$MODEL"
tools = [$TOOLS]
budget_usd = $BUDGET_USD
timeout_min = 5
TOML

GOAL_SRC="$SCRATCH/goal.md"
cat >"$GOAL_SRC" <<GOAL
---
id: verify-cli-verifier
title: verify-cli verifier scenario
base: $BASE
budget_usd: $BUDGET_USD
turn_timeout_min: 5
---

## Request

This is a throwaway thread that tests \`workbench verifier\`. Create one new file, \`scratch/verifier-probe.txt\`, holding
the single line \`verifier-probe\`. Do not commit and do nothing else.

## Criteria

- [c1] \`scratch/verifier-probe.txt\` exists with the line \`verifier-probe\`.
  - proof: the diff shows that one new file and nothing else
- [c2] The probe screenshot exists.
  - proof: screenshot: probe

## Out of scope

- Any other file, and committing.
GOAL

created=$(wb "$T_WB" goal new verify-cli-verifier --base "$BASE" --from "$GOAL_SRC") || { echo "$created"; die "goal new failed"; }
echo "$created"
ID=$(echo "$created" | sed -n 's/^created //p')
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id"
THREAD_DIR="$P/.workbench/threads/$ID"
perl -pi -e "s/^budget_usd: .*/budget_usd: $BUDGET_USD/; s/^turn_timeout_min: .*/turn_timeout_min: 5/; s/^# model: .*/model: $MODEL/" \
    "$THREAD_DIR/goal.md"
wb "$T_WB" goal approve "$ID"
approval=$(wb "$T_WB" status "$ID" --json | py "print(d['goal']['approval'])")
check "goal approved" "approval is '${approval:-?}'" test "${approval:-}" = approved

# --- 1. the coding turn, then the verifier ----------------------------------------------------------------

run_thread

# The verifier is on by default, so the run above started it after the turn; nothing here starts it by hand.
wb "$T_WB" log "$ID" >"$SCRATCH/verifier.out" 2>&1
sed 's/^/    /' "$SCRATCH/verifier.out" | grep -i verifier | head -6
check "the run started the verifier by itself and the log says it finished" "no 'verifier finished' line in workbench log" \
    grep -q "verifier finished" "$SCRATCH/verifier.out"

LOG="$SCRATCH/log.json"
wb "$T_WB" log "$ID" --json >"$LOG"
marks=$(py "print(' '.join(e['kind'] for e in lines if e['kind'].startswith('verifier.')))" <"$LOG")
check "the log has exactly one verifier.started then one verifier.ended" "verifier events: '$marks'" \
    test "$marks" = "verifier.started verifier.ended"
ended_ok=$(py "e=[x['data'] for x in lines if x['kind']=='verifier.ended']; print(e[-1].get('ok') if e else None)" <"$LOG")
check "verifier.ended is ok" "ok is '$ended_ok': $(py "e=[x['data'] for x in lines if x['kind']=='verifier.ended']; print(e[-1].get('reason') if e else '')" <"$LOG")" \
    test "$ended_ok" = True

# The command line the real claude got, from the log (the prompt is not in it).
argv=$(py "s=[x['data'] for x in lines if x['kind']=='verifier.started']; print(' '.join(s[-1]['argv']) if s else '')" <"$LOG")
echo "    argv: $argv"
check "argv: the model, safe mode, restricted and no slash commands" "argv is: $argv" \
    bash -c '[[ $1 == *"--model $2"* && $1 == *"--safe-mode"* && $1 == *"--restricted"* && $1 == *"--disable-slash-commands"* ]]' _ "$argv" "$MODEL"
check "argv: exactly the configured tools" "argv is: $argv" \
    bash -c '[[ $1 == *"--tools Read Bash"* && $1 == *"--allowedTools Read Bash(scripts/write-proof.sh:*)"* ]] || [[ $2 = 1 && $1 == *"--tools Read --allowedTools Read"* ]]' _ "$argv" "$SABOTAGE"
check "argv: the turn's proof folder is added, so the run can Read its screenshots" "argv is: $argv" \
    bash -c '[[ $1 == *"--add-dir "*"/threads/$2/proof/turn-1 "* ]]' _ "$argv" "$ID"
check "the log holds no prompt" "the argv contains the skill text" bash -c '[[ $1 != *"Probe verifier"* && $1 != *" -- "* ]]' _ "$argv"

# The skill the log names is the one at the base commit, byte for byte (trimmed).
want=$(g show "$BASE:$SKILL" | python3 -I -c "import hashlib,sys
t=sys.stdin.read().replace('\r\n','\n').strip()
print(hashlib.sha256(t.encode()).hexdigest())")
got=$(py "s=[x['data'] for x in lines if x['kind']=='verifier.started']; print(s[-1].get('skill'), s[-1].get('sha256')) if s else print('')" <"$LOG")
check "verifier.started names the skill and its sha256 as git has it" "git: $SKILL $want; log: $got" test "$got" = "$SKILL $want"

# What it left behind.
PROOF="$THREAD_DIR/proof/turn-1/probe.txt"
check "probe.txt is in the turn's proof folder" "no $PROOF" test -f "$PROOF"
check "probe.txt has the helper's text" "content: $(cat "$PROOF" 2>/dev/null)" grep -q '^verifier probe probe$' "$PROOF"
check "probe.png is in the turn's proof folder" "no probe.png" test -f "$THREAD_DIR/proof/turn-1/probe.png"
listed=$(py "e=[x['data'] for x in lines if x['kind']=='verifier.ended']; print(' '.join(sorted(f['name'] for f in e[-1].get('files', []))) if e else '')" <"$LOG")
check "verifier.ended lists probe.png and probe.txt" "files: '$listed'" test "$listed" = "probe.png probe.txt"
added=$(py "print(' '.join(x['data']['name']+':'+str(x['data'].get('source')) for x in lines if x['kind']=='proof.added'))" <"$LOG")
check "only the PNG is recorded as proof, as the verifier's" "proof.added: '$added'" test "$added" = "probe.png:verifier"
cost=$(py "e=[x['data'] for x in lines if x['kind']=='verifier.ended']; print(e[-1].get('cost_usd', '') if e else '')" <"$LOG")
check "a cost within the cap is recorded" "cost '$cost', cap $BUDGET_USD" \
    python3 -I -c "import sys; c=float(sys.argv[1]); sys.exit(0 if 0 < c <= float(sys.argv[2]) else 1)" "${cost:-0}" "$BUDGET_USD"
report=$(py "e=[x['data'] for x in lines if x['kind']=='verifier.ended']; print(len(e[-1].get('report', '')) if e else 0)" <"$LOG")
check "the report is stored" "report length '$report'" test "${report:-0}" -gt 0

# --- 2. review shows it ------------------------------------------------------------------------------------

wb "$T_WB" review "$ID" >"$SCRATCH/review.out" 2>&1
sed -n '/^Criteria/,/^Denied/p' "$SCRATCH/review.out" | sed 's/^/    /' | head -24
check "review shows the verifier as advisory with its screenshot" "no 'Verifier   advisory' line / probe.png" \
    bash -c 'grep -q "^Verifier   advisory · finished · turn 1" "$1" && grep -q "proof/turn-1/probe.png" "$1"' _ "$SCRATCH/review.out"
check "review shows the verifier's words as a note, not a pass" "no note lines" \
    bash -c 'grep -q "^  note: " "$1" && grep -q "not a pass" "$1"' _ "$SCRATCH/review.out"
check "the screenshot criterion reads see screenshot" "c2 is not 'see screenshot'" \
    bash -c 'grep -q "\[c2\] see screenshot" "$1"' _ "$SCRATCH/review.out"
check "the other criterion is still yours to check (the report passes nothing)" "c1 is not 'you check'" \
    bash -c 'grep -q "\[c1\] you check" "$1" && ! grep -q "✔ passed" "$1"' _ "$SCRATCH/review.out"
wb "$T_WB" review "$ID" --json >"$SCRATCH/review.json" 2>/dev/null
rj=$(py "v=d['verifier']; c={x['id']:x for x in d['criteria']}; print(v['ok'], v['stale'], ' '.join(f['name'] for f in v['proof']), c['c2']['status'], ' '.join(c['c2']['files']), c['c1']['status'])" <"$SCRATCH/review.json")
check "review --json lists the verifier, its proof and the criteria" "got: $rj" \
    test "$rj" = "True False probe.png evidence proof/turn-1/probe.png manual"

# --- 3. once per turn, and nothing left ---------------------------------------------------------------------

wb "$T_WB" verifier >"$SCRATCH/verifier2.out" 2>&1
code=$?
sed 's/^/    /' "$SCRATCH/verifier2.out" | head -3
check "a second verifier without --again is refused (exit 6)" "workbench verifier exited $code" test "$code" = 6
check "the refusal names --again" "no --again in the message" grep -q -- '--again' "$SCRATCH/verifier2.out"
check "no runner.json is left" "the thread still has a runner" test ! -e "$THREAD_DIR/runner.json"
leftover=$(ps -axo command= | grep -c "[-]-allowedTools Read Bash(scripts/write-proof.sh" || true)
check "no verifier claude is still running" "$leftover claude process(es) with the verifier's tools" test "${leftover:-0}" = 0

wb "$T_WB" abandon "$ID" >/dev/null 2>&1
ended=$(wb "$T_WB" status "$ID" --json | py "print(d['ended'])")
check "abandon ends the thread" "status says ended: $ended" test "$ended" = abandoned
finish
