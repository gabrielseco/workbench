#!/bin/bash
# verify-cli scenario for `workbench judge` telling the judge what the verifier did. On a clone of this repository with a
# `claude` stand-in that runs the fake-claude test double: the coding turn writes one file, the verifier's turn leaves a PNG
# in its proof folder and answers with a known report, and the judge's turn records the arguments it was given (the
# prompt among them) and answers with a verdict. No real turn is run, so it costs nothing.
#   bash scripts/verify-cli/judge-verifier.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/judge-verifier.sh   (the same, on a branch that contains origin/main)
# A thread is run once with the verifier on (a skill committed at the base), then judged: the judge's prompt must have a
# "## Verifier" section saying it finished after turn 1, carry its report marked as the verifier's claim, list its
# home.png as a screenshot, and never say "No verify step ran.". Exit 0 only when every step passed, 1 when one failed,
# 2 when it refused to start (nothing changed). VERIFY_CLI_SABOTAGE=1 turns the verifier off (`enabled = false`), so it
# leaves no report and no PNG: the steps "the prompt says the verifier finished after turn 1", "the prompt carries the
# verifier's report as its claim" and "the prompt lists the verifier's home.png" must FAIL. The frame is in lib.sh.
# Run by hand, not by CI.
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
VERDICT="$SCRATCH/verdict.json"
DUMP="$SCRATCH/judge-argv.json"
SKILL=.claude/skills/verify/SKILL.md
BASE=verify-cli-base
g clone -q "$ROOT" "$P" || die "git clone failed"
g -C "$P" checkout -q -b "$BASE" || die "could not make the base branch in the clone"
# The verifier reads its skill from the thread's base commit, so it is committed on the base.
mkdir -p "$P/$(dirname "$SKILL")" || die "could not make the skill's folder"
printf '# Judge verifier probe\n\nLeave home.png in the proof folder, then say c1 holds.\n' >"$P/$SKILL"
g -C "$P" add -f "$SKILL" || die "could not add the skill"
g -C "$P" -c user.name=verify-cli -c user.email=verify-cli@example.com commit -q -m "verify-cli: verifier skill" \
    || die "could not commit the skill in the clone"

mkdir -p "$BIN" || die "could not make $BIN"
PNG_HEX=89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c6360000002000001e221bc330000000049454e44ae426082
python3 -I -c "import sys; sys.stdout.buffer.write(bytes.fromhex(sys.argv[1]))" "$PNG_HEX" >"$PNG" || die "could not write the PNG"
printf 'VERIFY-CLI REPORT: c1 holds, home.png shows it.\n' >"$REPORT"
printf '{"criteria": [{"id": "c1", "met": true, "evidence": ["stand-in verdict"]}], "concerns": []}\n' >"$VERDICT"
ENABLED=""
if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: the verifier is off, so it leaves no report and no PNG"
    ENABLED="enabled = false"
fi
# `--output-format json` is the verifier's or the judge's turn (the judge's prompt opens with "independent judge"); the
# coding turn streams.
cat >"$BIN/claude" <<STUB
#!/bin/sh
mode=""; prev=""
for a in "\$@"; do [ "\$prev" = --output-format ] && mode=\$a; prev=\$a; done
if [ "\$mode" = json ]; then
    case "\$*" in
        *"independent judge"*) FAKE_CLAUDE='answer=$VERDICT,dump=$DUMP' exec '$FAKE' "\$@" ;;
    esac
    [ -n "\${WORKBENCH_PROOF_DIR:-}" ] && cp '$PNG' "\$WORKBENCH_PROOF_DIR/home.png"
    FAKE_CLAUDE='answer=$REPORT' exec '$FAKE' "\$@"
fi
FAKE_CLAUDE=write=judge-probe.txt exec '$FAKE' "\$@"
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
$ENABLED
TOML

cat >"$SCRATCH/goal.md" <<'GOAL'
---
title: Judge reads the verifier
budget_usd: 0.10
turn_timeout_min: 5
---

## Request

Nothing real runs: the stand-in claude writes one file, its verifier leaves home.png, and the judge records its prompt.

## Criteria

- [c1] The judge is told what the verifier did.
  - proof: screenshot: home

## Out of scope

- Any change to the code.
GOAL
wbp "$SCRATCH/new.out" goal new judge-verifier --from "$SCRATCH/goal.md" --base "$BASE"
ID=$(sed -n 's/^created //p' "$SCRATCH/new.out")
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id ($(head -3 "$SCRATCH/new.out"))"
APPROVE=(goal approve "$ID"); [ "$SABOTAGE" = 1 ] && APPROVE+=(--allow-unrunnable-proofs)   # the proof cannot run with the verifier off
wbp "$SCRATCH/approve.out" "${APPROVE[@]}"
[ "$RC" = 0 ] || die "goal approve $ID failed: $(cat "$SCRATCH/approve.out")"

wbp "$SCRATCH/run.out" run "$ID"
shown "$SCRATCH/run.out" 20
check "run: the turn finished" "workbench run exited $RC" test "$RC" = 0

wbp "$SCRATCH/judge.out" judge "$ID"
shown "$SCRATCH/judge.out" 8
check "judge: exit 0 and the stand-in was asked" "workbench judge exited $RC, or no prompt was recorded" \
    bash -c 'test "$1" = 0 && test -s "$2"' _ "$RC" "$DUMP"
py "a=d['argv']; i=a.index('--'); print(a[i+1])" <"$DUMP" >"$SCRATCH/prompt.txt" 2>/dev/null
sed -n '/^## Verif/,/^## Screenshots/p' "$SCRATCH/prompt.txt" | sed 's/^/    /' | head -20
check "the prompt says the verifier finished after turn 1" "no such line in its Verifier section" \
    grep -q "^The verifier finished after turn 1\. It left: home\.png\." "$SCRATCH/prompt.txt"
check "the prompt carries the verifier's report as its claim" "no report, or not marked as the verifier's claim" \
    bash -c 'grep -q "VERIFY-CLI REPORT: c1 holds" "$1" && grep -q "the verifier'"'"'s claim, not evidence" "$1"' _ "$SCRATCH/prompt.txt"
check "the prompt lists the verifier's home.png" "no '- home.png' in its screenshots" grep -qx -- "- home.png.*" "$SCRATCH/prompt.txt"
check "the prompt never says No verify step ran." "it still does" \
    bash -c 'test -s "$1" && ! grep -q "No verify step ran\." "$1"' _ "$SCRATCH/prompt.txt"
finish
