#!/bin/bash
# verify-cli scenario for `read_also` (a run may read other repositories, read-only), with the real `claude`, on this repository.
#   bash scripts/verify-cli/read-also.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/read-also.sh   (the same, on a branch that contains origin/main)
# Makes a second git repository beside the scratch folder with a secret word in a file, adds `read_also` for it to
# .workbench/config.toml (restored on exit) and runs one throwaway thread. The goal asks the turn to read that word and write it
# into a file of this repository, and to TRY to change a file of the other one. The steps: the turn was started with the folder added
# and every write to it denied, the first prompt names it, the word is in this repository's file, and the other repository is
# byte for byte as it was. Costs at most the turn cap ($VERIFY_CLI_BUDGET_USD, default 0.50). Exit 0 only when every step passed, 1
# when one failed, 2 when it refused to start (nothing changed). VERIFY_CLI_SABOTAGE=1 leaves `read_also` out, so the turn cannot read
# the folder: the argv, prompt and word steps must FAIL. The frame and the other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

CONFIG="$ROOT/.workbench/config.toml"
[ -f "$CONFIG" ] || die "no $CONFIG; this scenario edits it (and puts it back)"
grep -Eq '^read_also[[:space:]]*=' "$CONFIG" && die "$CONFIG already sets read_also; this scenario will not overwrite it"
# The backup lives outside $SCRATCH, which finish removes before the EXIT trap runs.
ORIG=$(mktemp "${TMPDIR:-/tmp}/verify-cli-read-also-config.XXXXXX") || die "mktemp failed"
cp "$CONFIG" "$ORIG"
restore() { cp "$ORIG" "$CONFIG" && rm -f "$ORIG"; }
trap restore EXIT

WORD="QUOKKA6613"
OTHER="$SCRATCH/other-repo"
mkdir -p "$OTHER" && OTHER=$(cd "$OTHER" && pwd -P)
git -C "$OTHER" init -q -b main || die "could not make the other repository"
echo "$WORD" >"$OTHER/secret.txt"
echo "original" >"$OTHER/change-me.txt"
git -C "$OTHER" add -A && git -C "$OTHER" -c user.name=verify -c user.email=verify@example.invalid commit -q -m "other repository" \
    || die "could not commit in the other repository"
BEFORE=$(git -C "$OTHER" rev-parse HEAD)

if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: read_also is left out"
else
    { printf 'read_also = ["%s"]\n' "$OTHER"; cat "$ORIG"; } >"$CONFIG"
fi

GOAL_SRC="$SCRATCH/goal.md"
cat >"$GOAL_SRC" <<GOAL
---
id: verify-cli-read-also
title: verify-cli read-also scenario
base: origin/main
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

This is a throwaway thread that tests reading another repository. Another git repository is at \`$OTHER\`. Read its file
\`secret.txt\` and create the file \`verify-cli-read-also.txt\` in this repository's root whose only content is the word in it.
Also try, once, to append the line \`changed\` to \`$OTHER/change-me.txt\` (that repository is read-only for you, so expect to be
refused) and say in your final answer whether it was refused. Change nothing else, do not commit, and do not run any test.

## Criteria

- [c1] \`verify-cli-read-also.txt\` exists and holds the word from the other repository's \`secret.txt\`.
  - proof: a person reads the file

## Out of scope

- Any other file, and committing.
GOAL

start_thread verify-cli-read-also "$GOAL_SRC"
remove_on_pass branch "$BRANCH"
run_thread

argv=$(wb "$T_WB" log "$ID" --json | py "s=[e for e in lines if e['kind']=='turn.started']; print(' '.join(s[-1]['data']['argv']) if s else '')")
check "the turn was started with the folder added" "argv has no --add-dir $OTHER" bash -c '[[ $1 == *"--add-dir $2"* ]]' _ "$argv" "$OTHER"
check "and every write to it denied" "argv lacks the Edit/Write rules" \
    bash -c '[[ $1 == *"Edit(/$2/**)"* && $1 == *"Write(/$2/**)"* ]]' _ "$argv" "$OTHER"
check "the first prompt names the folder" "turn-1.md does not name it" grep -qF "$OTHER" "$THREAD_DIR/prompts/turn-1.md"
answer=$(cat "$WT/verify-cli-read-also.txt" 2>/dev/null)
echo "    the file says: ${answer:-<missing>}"
check "the turn read the other repository: the file has the word" "the file says '${answer:-<missing>}', not $WORD" \
    bash -c 'grep -q "$2" <<<"$1"' _ "$answer" "$WORD"
check "the other repository is untouched" "its status: $(git -C "$OTHER" status --porcelain) / head $(git -C "$OTHER" rev-parse HEAD)" \
    bash -c 'test -z "$(git -C "$1" status --porcelain)" && test "$(git -C "$1" rev-parse HEAD)" = "$2" && grep -qx original "$1/change-me.txt"' _ "$OTHER" "$BEFORE"

wb "$T_WB" abandon "$ID" >/dev/null 2>&1
ended=$(wb "$T_WB" status "$ID" --json | py "print(d['ended'])")
check "abandon ends the thread" "status says ended: $ended" test "$ended" = abandoned
finish
