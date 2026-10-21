#!/bin/bash
# verify-cli scenario for `workbench ship` putting the verifier's screenshots in the pull request. On a clone of this
# repository whose origin is a bare copy in the temp folder, so nothing is pushed anywhere real, with stand-ins on PATH:
# a `claude` that runs the fake-claude test double (the coding turn writes one file, the verifier's turn leaves a PNG in
# its proof folder), a `gh` that is logged in, finds no pull request and opens #7, and a `pr-shots` that records what it
# is asked to upload. No real turn is run, so it costs nothing.
#   bash scripts/verify-cli/ship-screenshots.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/ship-screenshots.sh   (the same, on a branch that contains origin/main)
# A thread is run once: the verifier (on by default, with a skill committed at the base) must record home.png as
# `proof.added` with `source: verifier`; `accept` commits the work; `ship --yes --no-describe` must open the pull request,
# print `put 1 screenshot in the pull request`, ask `pr-shots` to upload exactly the verifier's PNG (same sha256) for
# pull request 7, and record `proof.published`. Exit 0 only when every step passed, 1 when one failed, 2 when it refused
# to start (nothing changed). VERIFY_CLI_SABOTAGE=1 makes the stand-in verifier leave no PNG, so its proof is not
# recorded: the steps "the verifier recorded home.png as proof", "ship put 1 screenshot in the pull request", "pr-shots
# uploaded the verifier's PNG for pull request 7" and "proof.published names home.png and pull request 7" must FAIL.
# The frame is in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

echo "==> building fake-claude"
with_timeout "$T_BUILD" swift build --product fake-claude || die "swift build --product fake-claude failed"
FAKE="$ROOT/.build/debug/fake-claude"
[ -x "$FAKE" ] || die "no $FAKE after the build"

ORIGIN="$SCRATCH/origin.git"
P="$SCRATCH/project"
BIN="$SCRATCH/bin"
PNG="$SCRATCH/home.png"
UPLOADS="$SCRATCH/uploads.txt"
SKILL=.claude/skills/verify/SKILL.md
g clone -q --bare "$ROOT" "$ORIGIN" || die "git clone --bare failed"
g -C "$ORIGIN" update-ref refs/heads/main "$BASE_SHA" || die "could not set main in the bare copy"
g -C "$ORIGIN" symbolic-ref HEAD refs/heads/main || die "could not point the bare copy's HEAD at main"
g clone -q "$ORIGIN" "$P" || die "git clone failed"
g -C "$P" checkout -q -B main origin/main || die "could not check out main in the clone"
# The verifier reads its skill from the thread's base commit, so it is committed on main and pushed to origin.
mkdir -p "$P/$(dirname "$SKILL")" || die "could not make the skill's folder"
printf '# Ship screenshots probe\n\nLeave home.png in the proof folder, then say c1 holds.\n' >"$P/$SKILL"
g -C "$P" add -f "$SKILL" || die "could not add the skill"
g -C "$P" -c user.name=verify-cli -c user.email=verify-cli@example.com commit -q -m "verify-cli: verifier skill" \
    || die "could not commit the skill in the clone"
g -C "$P" push -q origin main || die "could not push the skill to the bare origin"

mkdir -p "$BIN" || die "could not make $BIN"
PNG_HEX=89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c6360000002000001e221bc330000000049454e44ae426082
python3 -I -c "import sys; sys.stdout.buffer.write(bytes.fromhex(sys.argv[1]))" "$PNG_HEX" >"$PNG" || die "could not write the PNG"
LEAVE_PNG="cp '$PNG' \"\$WORKBENCH_PROOF_DIR/home.png\""
if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: the stand-in verifier leaves no PNG, so no proof is recorded"
    LEAVE_PNG=":"
fi
# `--output-format json` is the verifier's turn; the coding turn streams.
cat >"$BIN/claude" <<STUB
#!/bin/sh
mode=""; prev=""
for a in "\$@"; do [ "\$prev" = --output-format ] && mode=\$a; prev=\$a; done
if [ "\$mode" = json ]; then
    [ -n "\${WORKBENCH_PROOF_DIR:-}" ] && $LEAVE_PNG
    FAKE_CLAUDE= exec '$FAKE' "\$@"
fi
FAKE_CLAUDE=write=ship-probe.txt exec '$FAKE' "\$@"
STUB
cat >"$BIN/gh" <<'STUB'
#!/bin/sh
case "$1 $2" in
    "auth status") exit 0 ;;
    "pr list") echo "[]" ;;
    "pr create") echo "https://github.com/verify-cli/project/pull/7" ;;
    *) echo "verify-cli stand-in gh: $*" >&2; exit 1 ;;
esac
STUB
cat >"$BIN/pr-shots" <<STUB
#!/bin/sh
case "\$1" in
    path) echo "\$PR_SHOTS_DIR/verify-cli/\$2.png" ;;
    list) ls "\$PR_SHOTS_DIR"/verify-cli/*.png ;;
    pr) for f in "\$PR_SHOTS_DIR"/verify-cli/*.png; do
            echo "pr \$2 \$(basename "\$f") \$(shasum -a 256 <"\$f" | cut -d' ' -f1)"
        done >>'$UPLOADS' ;;
    *) echo "verify-cli stand-in pr-shots: \$*" >&2; exit 1 ;;
esac
STUB
chmod +x "$BIN/claude" "$BIN/gh" "$BIN/pr-shots"
echo "==> clone at $P, origin $ORIGIN, stand-ins in $BIN"

RC=0
wbp() { # <out> args...: a workbench command in the clone with the stand-ins first on PATH, stdout and stderr together; sets RC
    local o=$1 secs=$T_WB; shift
    [ "$1" = run ] && secs=$T_RUN
    echo "workbench $*   (in the clone)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone)" >&2
    ( cd "$P" && PATH="$BIN:$PATH" with_timeout "$secs" "$WB" "$@" >"$o" 2>&1 )
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
title: Ship screenshots
budget_usd: 0.10
turn_timeout_min: 5
---

## Request

Nothing real runs: the stand-in claude writes one file and its verifier leaves home.png.

## Criteria

- [c1] The verifier's screenshot is in the pull request.
  - proof: screenshot: home

## Out of scope

- Any change to the code.
GOAL
wbp "$SCRATCH/new.out" goal new ship-screenshots --from "$SCRATCH/goal.md" --base main
ID=$(sed -n 's/^created //p' "$SCRATCH/new.out")
[ -n "$ID" ] || die "goal new made no thread: $(cat "$SCRATCH/new.out")"
THREAD_DIR="$P/.workbench/threads/$ID"
wbp "$SCRATCH/approve.out" goal approve "$ID"
[ "$RC" = 0 ] || die "goal approve $ID failed: $(cat "$SCRATCH/approve.out")"

wbp "$SCRATCH/run.out" run "$ID"
shown "$SCRATCH/run.out" 20
check "run: the turn and its verifier finished" "workbench run exited $RC" test "$RC" = 0
wbp "$SCRATCH/log.json" log "$ID" --json
recorded=$(py "print(' '.join(e['data']['name'] for e in lines if e['kind']=='proof.added' and e['data'].get('source')=='verifier'))" \
    <"$SCRATCH/log.json" 2>/dev/null)
check "the verifier recorded home.png as proof" "verifier proof in the log: '${recorded}'" test "$recorded" = home.png

wbp "$SCRATCH/accept.out" accept "$ID" -m "chore: ship screenshots probe" --yes
check "accept: exit 0" "workbench accept exited $RC" test "$RC" = 0

wbp "$SCRATCH/ship.out" ship "$ID" --yes --no-describe
shown "$SCRATCH/ship.out" 40
check "ship: exit 0 and the pull request is opened" "exit $RC" \
    bash -c 'test "$1" = 0 && grep -qx "opened the pull request" "$2"' _ "$RC" "$SCRATCH/ship.out"
check "ship put 1 screenshot in the pull request" "no 'put 1 screenshot' line" \
    grep -qx "put 1 screenshot in the pull request" "$SCRATCH/ship.out"
want="pr 7 home.png $(shasum -a 256 <"$PNG" | cut -d' ' -f1)"
check "pr-shots uploaded the verifier's PNG for pull request 7" "it was asked: '$(cat "$UPLOADS" 2>/dev/null)'" \
    test "$(cat "$UPLOADS" 2>/dev/null)" = "$want"
wbp "$SCRATCH/log-after.json" log "$ID" --json
published=$(py "e=[x['data'] for x in lines if x['kind']=='proof.published']
print('%s %s' % (e[-1].get('number'), ','.join(e[-1].get('files') or [])) if e else '')" <"$SCRATCH/log-after.json" 2>/dev/null)
check "proof.published names home.png and pull request 7" "the log has: '$published'" test "$published" = "7 home.png"
finish
