#!/bin/bash
# verify-cli scenario for `workbench grant` (P13 task 7), with the real `claude`, on this repository.
#   bash scripts/verify-cli/grant.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/grant.sh   (the same, on a branch that contains origin/main)
# Runs one throwaway thread for two cheap turns. Turn 1 is denied a chmod, a compound and a command under
# `[tools] denied`; the script checks what `grant` lists, grants the chmod once, refuses the rest with the
# documented exit codes, and turn 2 (send-back) must run the chmod. Exit 0 only when every step passed, 1 when
# one failed, 2 when it refused to start (nothing changed). VERIFY_CLI_SABOTAGE=1 turns the once grant into a
# `--never` before turn 2, so the grant does nothing and the chmod steps must FAIL. The frame and the other
# switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

CONFIG="$ROOT/.workbench/config.toml"
[ -f "$CONFIG" ] || die "no $CONFIG; grant must leave it byte for byte as it is, so there has to be one"
cp "$CONFIG" "$SCRATCH/config.before"

PROBE=scripts/verify-cli/grant-probe.sh
CHMOD_PATTERN="Bash(chmod +x $PROBE)"
GOAL_SRC="$SCRATCH/goal.md"
cat >"$GOAL_SRC" <<'EOF'
---
id: verify-cli-grant
title: verify-cli grant scenario
base: origin/main
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

This is a throwaway thread that tests `workbench grant`; its branch is deleted afterwards. Do these four steps
in order, each as its own tool call:

1. With the file tools, create `scripts/verify-cli/grant-probe.sh` holding the two lines `#!/bin/sh` and
   `echo grant-probe`.
2. With the Bash tool, run exactly `chmod +x scripts/verify-cli/grant-probe.sh`.
3. With the Bash tool, run exactly `mkdir -p scratch/grant-compound && touch scratch/grant-compound/a` as one command.
4. With the Bash tool, run exactly `rm -rf scratch/grant-probe-dir`.

If the Bash tool refuses a command, do not retry it, do not look for another way to do the same and do not
change any setting: go on to the next step, and finish by saying which commands were refused. Do not commit.

## Criteria

- [c1] `scripts/verify-cli/grant-probe.sh` exists in the worktree.
  - proof: the diff shows that one new file and nothing else

## Out of scope

- Any other file, and committing.
EOF

start_thread verify-cli-grant "$GOAL_SRC"
remove_on_pass branch "$BRANCH"
run_thread

# --- turn 1: denied, and the turn still succeeded ------------------------------------------------------

turn_result() { # <n>: the nth turn.ended's result and its denial count, "result denials"
    wb "$T_WB" log "$ID" --json | py "e=[x['data'] for x in lines if x['kind']=='turn.ended']
n=$1
print(e[n-1]['result'], e[n-1].get('permission_denials', 0)) if len(e)>=n else print('none 0')"
}
read -r result1 denials1 <<<"$(turn_result 1)"
echo "    turn 1: $result1, $denials1 denial(s)"
check "turn 1 ended succeeded although commands were denied" "turn 1 ended '$result1' with $denials1 denial(s)" \
    bash -c '[ "$1" = succeeded ] && [ "$2" -gt 0 ]' _ "$result1" "$denials1"

LIST1=$(wb "$T_WB" grant "$ID" --json)
# The denial number of the first entry whose `input` satisfies the Python predicate $1 (over `x`), else nothing.
number_of() { echo "$LIST1" | py "print(next((x['number'] for x in d['denied'] if $1), ''))"; }
echo "$LIST1" | py "
for x in d['denied']:
    print('    %s  %-9s %-9s %s' % (x['number'], x['level'], x['status'], (x['input'] or '')[:80]))"

CHMOD_N=$(number_of "(x['input'] or '').strip() == 'chmod +x $PROBE'")
COMPOUND_N=$(number_of "x['compound'] and 'grant-compound' in (x['input'] or '')")
RM_N=$(number_of "(x['input'] or '').strip().startswith('rm -rf')")
echo "    denial numbers: chmod ${CHMOD_N:-none}, compound ${COMPOUND_N:-none}, rm -rf ${RM_N:-none}"

chmod_listed() {
    [ -n "$CHMOD_N" ] || { echo "    no denied chmod in grant --json"; return 1; }
    echo "$LIST1" | py "
x=[x for x in d['denied'] if x['number']==$CHMOD_N][0]
p=x['parts'][0] if x['parts'] else {}
print('    chmod: level %s, status %s, pattern %s' % (x['level'], x['status'], p.get('pattern')))
sys.exit(0 if x['level']=='safe' and x['status']=='open' and p.get('pattern')=='$CHMOD_PATTERN' and not x['compound'] else 1)"
}
check "grant --json lists the denied chmod as safe with the pattern $CHMOD_PATTERN" "see above" chmod_listed
check "the compound and the rm -rf were denied too" "compound '${COMPOUND_N:-}', rm -rf '${RM_N:-}'" \
    test -n "$COMPOUND_N" -a -n "$RM_N"

# The file tools are allowed, the chmod was not: the file is there and is not executable yet.
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
    fail "worktree left by run" "no worktree at '${WT}'"
else
    if [ ! -f "$WT/$PROBE" ]; then
        echo "    the model did not write $PROBE; the script writes it"
        mkdir -p "$WT/scripts/verify-cli" && printf '#!/bin/sh\necho grant-probe\n' >"$WT/$PROBE"
    fi
    check "the denied chmod did not run: $PROBE is not executable" "it is executable already" test ! -x "$WT/$PROBE"
fi

# --- grant --once --------------------------------------------------------------------------------------

grant_once() {
    [ -n "$CHMOD_N" ] || return 1
    wb "$T_WB" grant "$ID" "$CHMOD_N" --once --json | py "
print('    recorded %s as %s, seq %s' % (d['pattern'], d['scope'], d['seq']))
sys.exit(0 if d['pattern']=='$CHMOD_PATTERN' and d['scope']=='once' and d['recorded'] and d['seq'] else 1)"
}
check "grant $CHMOD_N --once records $CHMOD_PATTERN" "see above (exit or JSON)" grant_once

status_of() { # <number>: the status of that denial now; fails (printing nothing) when the query or the entry is missing
    local list
    list=$(wb "$T_WB" grant "$ID" --json) || return 1
    echo "$list" | py "s=next((x['status'] for x in d['denied'] if x['number']==$1), None)
sys.exit(1) if s is None else print(s)"
}
status_after_grant=$(status_of "${CHMOD_N:-0}")
check "grant --json shows granted_once" "status is '$status_after_grant'" test "$status_after_grant" = granted_once
check ".workbench/config.toml is byte for byte unchanged" "grant wrote to the config" cmp -s "$SCRATCH/config.before" "$CONFIG"

# --- turn 2: the grant reaches the next turn -----------------------------------------------------------

if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: revoking the grant with --never before turn 2"
    wb "$T_WB" grant "$ID" "$CHMOD_N" --never >/dev/null
fi

NOTE="The user granted exactly this command: chmod +x $PROBE. Run it now with the Bash tool, and nothing else."
wb "$T_RUN" send-back "$NOTE"
send_exit=$?
check "send-back: turn 2 succeeded" "workbench send-back exited $send_exit" test "$send_exit" = 0

LOG2=$(wb "$T_WB" log "$ID" --json)
argv2=$(echo "$LOG2" | py "s=[e for e in lines if e['kind']=='turn.started']; print(json.dumps(s[1]['data']['argv']) if len(s)>1 else '[]')")
argv_has_pattern() {
    echo "$argv2" | py "
a=d[d.index('--allowedTools')+1:] if '--allowedTools' in d else []
a=a[:next((i for i,v in enumerate(a) if v.startswith('--')), len(a))]
print('    turn 2 --allowedTools: %d entries, grant %s' % (len(a), 'in' if '$CHMOD_PATTERN' in a else 'NOT in'))
sys.exit(0 if '$CHMOD_PATTERN' in a else 1)"
}
check "turn 2's argv (turn.started) allows $CHMOD_PATTERN" "see above" argv_has_pattern

read -r result2 denials2 <<<"$(turn_result 2)"
echo "    turn 2: $result2, $denials2 denial(s)"
check "turn 2 ended succeeded" "turn 2 ended '$result2'" test "$result2" = succeeded
check "turn 2 ran the chmod: $PROBE is executable in the worktree" "the mode is not executable" test -x "$WT/$PROBE"

# --- the once grant is spent ---------------------------------------------------------------------------

status_after_turn=$(status_of "${CHMOD_N:-0}")
check "a once grant is spent: grant --json says open again (now '$status_after_turn')" \
    "status is '$status_after_turn' after the turn it was for" test "$status_after_turn" = open

# --- refusals, with the documented exit codes -----------------------------------------------------------

# <expected exit> <step> <why> <grant arguments...>: the exit code of `workbench grant` with those arguments.
refusal() {
    local want=$1 name=$2 why=$3 out got; shift 3
    out=$(wb "$T_WB" grant "$ID" "$@" 2>&1); got=$?
    echo "$out" | sed 's/^/    /' | head -3
    check "$name: exit $want" "$why; exit $got" test "$got" = "$want"
}
if [ -n "$COMPOUND_N" ]; then
    refusal 6 "grant $COMPOUND_N --once (a compound named whole)" "a compound must be granted by part" "$COMPOUND_N" --once
else
    fail "grant of a compound named whole: exit 6" "turn 1 was not denied the compound"
fi
refusal 7 "grant 99 --once (no such denial)" "99 does not exist" 99 --once
if [ -n "$CHMOD_N" ]; then
    refusal 2 "grant $CHMOD_N without a scope" "a number needs --once, --thread or --never" "$CHMOD_N"
fi
if [ -n "$RM_N" ]; then
    rm_out=$(wb "$T_WB" grant "$ID" "$RM_N" --once --allow-dangerous 2>&1); rm_exit=$?
    echo "$rm_out" | sed 's/^/    /' | head -3
    check "grant $RM_N --once --allow-dangerous (under [tools] denied): exit 6, names [tools] denied" \
        "exit $rm_exit" bash -c '[ "$1" = 6 ] && [[ $2 == *"[tools] denied"* ]]' _ "$rm_exit" "$rm_out"
    rm_status=$(status_of "$RM_N")
    # Still blocked: nothing was recorded, so the denial stays open and no later turn is told to allow it.
    check "the refused rm -rf stays open" "status '$rm_status'" test "$rm_status" = open
    rm_in_allowed=$(echo "$argv2" | py "
a=d[d.index('--allowedTools')+1:] if '--allowedTools' in d else []
a=a[:next((i for i,v in enumerate(a) if v.startswith('--')), len(a))]
print(' '.join(v for v in a if v.startswith('Bash(rm')))")
    check "turn 2's --allowedTools has no rm entry" "found: $rm_in_allowed" test -z "$rm_in_allowed"
else
    fail "grant of a command under [tools] denied: exit 6" "turn 1 was not denied the rm -rf"
fi
check ".workbench/config.toml is still byte for byte unchanged" "grant wrote to the config" cmp -s "$SCRATCH/config.before" "$CONFIG"

left=$( [ -n "$WT" ] && pgrep -fl "$WT")
check "no process of the worktree left" "$left" test -z "$left"

# The thread is ended here, not left active: abandon keeps the branch and saves the changes.
wb "$T_WB" abandon "$ID" >/dev/null
ended=$(wb "$T_WB" status "$ID" --json | py "print(d['ended'] or '')")
check "thread ended (abandon)" "thread $ID is still active" test -n "$ended"

finish
