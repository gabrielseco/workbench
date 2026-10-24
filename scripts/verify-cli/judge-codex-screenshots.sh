#!/bin/bash
# verify-cli scenario for a Codex judge that has the verifier's screenshots (the answer folder fix). On a clone of this repository
# with a `claude` stand-in that runs the fake-claude test double (the coding turn writes one file, the verifier's turn leaves a PNG
# in its proof folder) and a `codex` stand-in that, like the real CLI, writes its last message to the file `-o` names without
# creating the folder around it. No real turn is run, so it costs nothing.
#   bash scripts/verify-cli/judge-codex-screenshots.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/judge-codex-screenshots.sh   (the same, on a branch that contains origin/main)
# A thread is run once with the verifier on, then judged by Codex: `judge` must exit 0 with a verdict (the thread's `judge/` folder
# did not exist before) and `review --json` must show c1 met. Then the stand-in is made to write nothing and `judge --again` must
# fail saying codex "left no answer in <path>" (the CLI shows machine paths as <path>), not "no result".
# Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start (nothing changed). VERIFY_CLI_SABOTAGE=1 makes
# the stand-in write nothing from the start, so the steps "judge: exit 0" and "review shows the verdict with c1 met" must FAIL.
# The frame is in lib.sh. Run by hand, not by CI.
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
ANSWER="$SCRATCH/codex-answer.txt"
SKILL=.claude/skills/verify/SKILL.md
BASE=verify-cli-base
g clone -q "$ROOT" "$P" || die "git clone failed"
g -C "$P" checkout -q -b "$BASE" || die "could not make the base branch in the clone"
# The verifier reads its skill from the thread's base commit, so it is committed on the base.
mkdir -p "$P/$(dirname "$SKILL")" || die "could not make the skill's folder"
printf '# Codex judge probe\n\nLeave home.png in the proof folder, then say c1 holds.\n' >"$P/$SKILL"
g -C "$P" add -f "$SKILL" || die "could not add the skill"
g -C "$P" -c user.name=verify-cli -c user.email=verify-cli@example.com commit -q -m "verify-cli: verifier skill" \
    || die "could not commit the skill in the clone"

mkdir -p "$BIN" || die "could not make $BIN"
PNG_HEX=89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c6360000002000001e221bc330000000049454e44ae426082
python3 -I -c "import sys; sys.stdout.buffer.write(bytes.fromhex(sys.argv[1]))" "$PNG_HEX" >"$PNG" || die "could not write the PNG"
printf 'VERIFY-CLI REPORT: c1 holds, home.png shows it.\n' >"$REPORT"
if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: the codex stand-in writes no answer"
else
    printf '{"criteria": [{"id": "c1", "met": true, "evidence": ["stand-in verdict"]}], "concerns": []}\n' >"$ANSWER"
fi
# The verifier's turn is `--output-format json`; the coding turn streams.
cat >"$BIN/claude" <<STUB
#!/bin/sh
mode=""; prev=""
for a in "\$@"; do [ "\$prev" = --output-format ] && mode=\$a; prev=\$a; done
if [ "\$mode" = json ]; then
    [ -n "\${WORKBENCH_PROOF_DIR:-}" ] && cp '$PNG' "\$WORKBENCH_PROOF_DIR/home.png"
    FAKE_CLAUDE='answer=$REPORT' exec '$FAKE' "\$@"
fi
FAKE_CLAUDE=write=judge-probe.txt exec '$FAKE' "\$@"
STUB
# Like the real codex: the folder around -o is not made, so the redirect fails when it is missing.
cat >"$BIN/codex" <<STUB
#!/bin/sh
out=""; prev=""
for a in "\$@"; do [ "\$prev" = -o ] && out=\$a; prev=\$a; done
echo "codex progress line"
[ -f '$ANSWER' ] && [ -n "\$out" ] && cat '$ANSWER' >"\$out"
exit 0
STUB
chmod +x "$BIN/claude" "$BIN/codex"
echo "==> clone at $P, base $BASE, stand-ins in $BIN"

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

[providers.codex]
executable = "$BIN/codex"

[agents.judge]
provider = "codex"
allow_unpriced = true
TOML

cat >"$SCRATCH/goal.md" <<'GOAL'
---
title: Codex judge with screenshots
budget_usd: 0.10
turn_timeout_min: 5
---

## Request

Nothing real runs: the stand-in claude writes one file, its verifier leaves home.png, and a stand-in codex judges.

## Criteria

- [c1] The Codex judge gets a verdict.
  - proof: screenshot: home

## Out of scope

- Any change to the code.
GOAL
wbp "$SCRATCH/new.out" goal new judge-codex-shots --from "$SCRATCH/goal.md" --base "$BASE"
ID=$(sed -n 's/^created //p' "$SCRATCH/new.out")
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id ($(head -3 "$SCRATCH/new.out"))"
wbp "$SCRATCH/approve.out" goal approve "$ID"
[ "$RC" = 0 ] || die "goal approve $ID failed: $(cat "$SCRATCH/approve.out")"

wbp "$SCRATCH/run.out" run "$ID"
shown "$SCRATCH/run.out" 20
check "run: the turn finished" "workbench run exited $RC" test "$RC" = 0
check "the thread has no judge folder before the judge runs" "judge/ is already there" \
    bash -c '! test -e "$1/.workbench/threads/$2/judge"' _ "$P" "$ID"

wbp "$SCRATCH/judge.out" judge "$ID"
shown "$SCRATCH/judge.out" 8
check "judge: exit 0" "workbench judge exited $RC" test "$RC" = 0
wbp "$SCRATCH/review.json" review "$ID" --json
check "review shows the verdict with c1 met" "no verdict, or c1 not met" \
    py "j=d['judge']; assert j['ok'] is True and d['agents']['judge']['provider']=='codex', j; assert [c['met'] for c in j['criteria']]==[True], j" <"$SCRATCH/review.json"

# --- a Codex run that writes no answer is named by the file it was asked for ---------------------------------
rm -f "$ANSWER"
wbp "$SCRATCH/judge2.out" judge "$ID" --again
shown "$SCRATCH/judge2.out" 4
check "judge --again with no answer written: exit 1" "workbench judge exited $RC" test "$RC" = 1
check "the failure says codex left no answer, not 'no result'" "message is: $(tail -2 "$SCRATCH/judge2.out")" \
    bash -c 'grep -q "codex left no answer in " "$1" && ! grep -q "no result" "$1"' _ "$SCRATCH/judge2.out"
finish
