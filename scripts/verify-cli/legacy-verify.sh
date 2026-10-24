#!/bin/bash
# verify-cli scenario for an old log's verify step no longer being read. On a clone of this repository with a `claude`
# stand-in that runs the fake-claude test double: the coding turn writes one file and the verifier's turn leaves home.png.
# The thread's log then gets the verify step an older Workbench wrote (`verify.started`, a `proof.added` without `source`
# for step.png, `verify.ended`), as a log from before 19 Oct 2026 has. No real turn is run, so it costs nothing.
#   bash scripts/verify-cli/legacy-verify.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/legacy-verify.sh   (the same, on a branch that contains origin/main)
# `status`, `review` and `log` (text and `--json`) must all load that log; `status --json` and `review --json` must have
# no `verify` field, the proof must be the verifier's alone (home.png, not step.png), and `review` must print no Verify
# line. Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start (nothing changed).
# VERIFY_CLI_SABOTAGE=1 puts the old fields back into what the commands printed, after they ran: the steps
# "status --json has no verify field", "review --json has no verify field" and "review prints no Verify line" must
# FAIL. The frame is in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

echo "==> building fake-claude"
with_timeout "$T_BUILD" swift build --product fake-claude || die "swift build --product fake-claude failed"
FAKE="$ROOT/.build/debug/fake-claude"
[ -x "$FAKE" ] || die "no $FAKE after the build"

P="$SCRATCH/project"
BIN="$SCRATCH/bin"
PNG="$SCRATCH/home.png"
REPORT="$SCRATCH/verifier-report.txt"
SKILL=.claude/skills/verify/SKILL.md
BASE=verify-cli-base
g clone -q "$ROOT" "$P" || die "git clone failed"
g -C "$P" checkout -q -b "$BASE" || die "could not make the base branch in the clone"
# The verifier reads its skill from the thread's base commit, so it is committed on the base.
mkdir -p "$P/$(dirname "$SKILL")" || die "could not make the skill's folder"
printf '# Legacy verify probe\n\nLeave home.png in the proof folder, then say c1 holds.\n' >"$P/$SKILL"
g -C "$P" add -f "$SKILL" || die "could not add the skill"
g -C "$P" -c user.name=verify-cli -c user.email=verify-cli@example.com commit -q -m "verify-cli: verifier skill" \
    || die "could not commit the skill in the clone"

mkdir -p "$BIN" || die "could not make $BIN"
PNG_HEX=89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c6360000002000001e221bc330000000049454e44ae426082
python3 -I -c "import sys; sys.stdout.buffer.write(bytes.fromhex(sys.argv[1]))" "$PNG_HEX" >"$PNG" || die "could not write the PNG"
printf 'VERIFY-CLI REPORT: c1 holds, home.png shows it.\n' >"$REPORT"
# `--output-format json` is the verifier's turn; the coding turn streams.
cat >"$BIN/claude" <<STUB
#!/bin/sh
mode=""; prev=""
for a in "\$@"; do [ "\$prev" = --output-format ] && mode=\$a; prev=\$a; done
if [ "\$mode" = json ]; then
    [ -n "\${WORKBENCH_PROOF_DIR:-}" ] && cp '$PNG' "\$WORKBENCH_PROOF_DIR/home.png"
    FAKE_CLAUDE='answer=$REPORT' exec '$FAKE' "\$@"
fi
FAKE_CLAUDE=write=legacy-verify-probe.txt exec '$FAKE' "\$@"
STUB
chmod +x "$BIN/claude"
echo "==> clone at $P, base $BASE, stand-in in $BIN"

RC=0
wbp() { # <out> args...: a workbench command in the clone, stdout and stderr together; sets RC
    local o=$1 secs=$T_WB; shift
    [ "$1" = run ] && secs=$T_RUN
    echo "workbench $*   (in the clone)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    ( cd "$P" && with_timeout "$secs" "$WB" "$@" >"$o" 2>&1 )
    RC=$?
}
shown() { sed 's/^/    /' "$1" | head -${2:-8}; }

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
cat >"$P/.workbench/config.toml" <<TOML
claude_path = "$BIN/claude"
default_budget_usd = 0.10

[tools]
available = ["Read", "Edit", "Write"]
allowed = ["Read", "Edit", "Write"]

[verifier]
skill = "$SKILL"
tools = ["Read"]
timeout_min = 5
TOML

cat >"$SCRATCH/goal.md" <<'GOAL'
---
title: An old verify step is not read
budget_usd: 0.10
turn_timeout_min: 5
---

## Request

Nothing real runs: the stand-in claude writes one file and its verifier leaves home.png.

## Criteria

- [c1] The proof is the verifier's.
  - proof: screenshot: home

## Out of scope

- Any change to the code.
GOAL
wbp "$SCRATCH/new.out" goal new legacy-verify --from "$SCRATCH/goal.md" --base "$BASE"
ID=$(sed -n 's/^created //p' "$SCRATCH/new.out")
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id ($(head -3 "$SCRATCH/new.out"))"
wbp "$SCRATCH/approve.out" goal approve "$ID"
[ "$RC" = 0 ] || die "goal approve $ID failed: $(cat "$SCRATCH/approve.out")"

wbp "$SCRATCH/run.out" run "$ID"
shown "$SCRATCH/run.out" 20
check "run: the turn finished" "workbench run exited $RC" test "$RC" = 0

# The verify step an older Workbench wrote after turn 1, appended as its writer did: the next seq numbers, one
# `proof.added` without `source`, and the file it names in the turn's proof folder.
EVENTS="$P/.workbench/threads/$ID/events.jsonl"
mkdir -p "$P/.workbench/threads/$ID/proof/turn-1" && cp "$PNG" "$P/.workbench/threads/$ID/proof/turn-1/step.png" \
    || die "could not write the old step's file"
python3 -I - "$EVENTS" <<'PY' || die "could not append the old verify step to the log"
import hashlib, json, sys
path = sys.argv[1]
seq = max(json.loads(line)["seq"] for line in open(path) if line.strip())
png = open(path.rsplit("/", 1)[0] + "/proof/turn-1/step.png", "rb").read()
old = [
    ("verify.started", {"command": "scripts/verify.sh", "proof_ref": "proof/turn-1", "commit": None, "tree": None}),
    ("proof.added", {"name": "step.png", "path": "proof/turn-1/step.png", "sha256": hashlib.sha256(png).hexdigest(),
        "bytes": len(png), "commit": None, "tree": None}),
    ("verify.ended", {"command": "scripts/verify.sh", "result": "passed", "exit_code": 0, "duration_ms": 1200,
        "proof_files": 1}),
]
with open(path, "a") as log:
    for kind, data in old:
        seq += 1
        log.write(json.dumps({"v": 1, "seq": seq, "ts": "2026-10-18T10:00:00.000Z", "turn": 1, "kind": kind,
            "data": data}, sort_keys=True) + "\n")
PY

wbp "$SCRATCH/log.json" log "$ID" --json
check "log --json loads the old log, verify.started and verify.ended in it" "exit $RC, or the events are not there" \
    bash -c 'test "$1" = 0 && grep -q "\"verify.started\"" "$2" && grep -q "\"verify.ended\"" "$2"' _ "$RC" "$SCRATCH/log.json"
wbp "$SCRATCH/log.out" log "$ID"
check "log loads the old log" "workbench log exited $RC" test "$RC" = 0

wbp "$SCRATCH/status.json" status "$ID" --json
STATUS_RC=$RC
wbp "$SCRATCH/review.json" review "$ID" --json
REVIEW_RC=$RC
wbp "$SCRATCH/status.out" status "$ID"
STATUS_TEXT_RC=$RC
wbp "$SCRATCH/review.out" review "$ID"
REVIEW_TEXT_RC=$RC
shown "$SCRATCH/review.out" 40

if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: the old verify fields are put back into what status and review printed"
    python3 -I - "$SCRATCH/status.json" "$SCRATCH/review.json" <<'PY'
import json, sys
for path, value in [(sys.argv[1], {"open_turn": None, "last": "passed"}),
                    (sys.argv[2], {"turn": 1, "result": "passed", "exit_code": 0, "duration_ms": 1200, "proof": []})]:
    obj = json.load(open(path))
    obj["verify"] = value
    open(path, "w").write(json.dumps(obj) + "\n")
PY
    printf 'Verify     passed  turn 1  1s\n' >>"$SCRATCH/review.out"
fi

check "status loads the old log" "exit $STATUS_TEXT_RC" test "$STATUS_TEXT_RC" = 0
check "status --json loads the old log" "exit $STATUS_RC" test "$STATUS_RC" = 0
check "status --json has no verify field" "it has one" \
    py "import sys; sys.exit(0 if 'verify' not in d and 'check' in d else 1)" <"$SCRATCH/status.json"
check "review loads the old log" "exit $REVIEW_TEXT_RC" test "$REVIEW_TEXT_RC" = 0
check "review --json loads the old log" "exit $REVIEW_RC" test "$REVIEW_RC" = 0
check "review --json has no verify field" "it has one" \
    py "import sys; sys.exit(0 if 'verify' not in d and 'verifier' in d else 1)" <"$SCRATCH/review.json"
check "review --json: the proof is the verifier's home.png, not the old step's step.png" "verifier proof or c1 is not that" \
    py "import sys
v = d.get('verifier') or {}
c1 = [c for c in d.get('criteria', []) if c['id'] == 'c1']
ok = [p['name'] for p in v.get('proof', [])] == ['home.png'] and c1 and c1[0]['status'] == 'evidence' \
    and c1[0]['files'] == ['proof/turn-1/home.png']
sys.exit(0 if ok else 1)" <"$SCRATCH/review.json"
check "review prints no Verify line" "it does" bash -c '! grep -q "^Verify " "$1"' _ "$SCRATCH/review.out"
check "status prints no verify line" "it does" bash -c '! grep -q "^verify:" "$1"' _ "$SCRATCH/status.out"

wbp "$SCRATCH/abandon.out" abandon "$ID"
check "abandon ends the thread" "workbench abandon exited $RC" test "$RC" = 0
finish
