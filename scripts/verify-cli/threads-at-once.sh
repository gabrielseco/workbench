#!/bin/bash
# verify-cli scenario for several active threads and `--thread` (P23 slices 2 and 3), on a clone of this repository. No turn is
# run, so it costs nothing.
#   bash scripts/verify-cli/threads-at-once.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/threads-at-once.sh   (the same, on a branch that contains origin/main)
# With `max_active_threads = 2`: two threads can be started and a third is refused (exit 6) naming both; `abandon` with no id
# refuses (exit 6) and lists both, `abandon --thread <a>` ends a, `status --thread <b> --json` is b, a thread named twice
# differently is a usage error (exit 2); `--thread` may come before a note or a stage name; with one thread left `abandon` needs no id again; at the default (1) a second thread is
# refused as before. Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start (nothing changed).
# VERIFY_CLI_SABOTAGE=1 gives the "no id" refusals a --thread, so those steps must FAIL. The frame and the other switches are in
# lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: the 'no id' refusals are sent a --thread"

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
shown() { sed 's/^/    /' "$1" | head -${2:-6}; }
CFG="$P/.workbench/config.toml"
newid() { sed -n 's/^created //p' "$1"; }

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
setcap() { # <n>: max_active_threads = n, above the tables
    { echo "max_active_threads = $1"; grep -v '^max_active_threads' "$CFG"; } >"$SCRATCH/cfg" && cp "$SCRATCH/cfg" "$CFG"
}

# --- 1. the default is one --------------------------------------------------------------------------------

wbp "$SCRATCH/n1.out" goal new verify-one --base "$BASE"
check "default: the first thread starts" "exit $RC" test "$RC" = 0
ONE=$(newid "$SCRATCH/n1.out")
wbp "$SCRATCH/n2.out" goal new verify-two --base "$BASE"
shown "$SCRATCH/n2.out"
check "default: a second thread is refused (exit 6) naming the first" "exit $RC: $(head -c 200 "$SCRATCH/n2.out")" \
    bash -c 'test "$1" = 6 && grep -q "$2" "$3"' _ "$RC" "$ONE" "$SCRATCH/n2.out"
wbp "$SCRATCH/a0.out" abandon "$ONE"
check "default: the first thread is abandoned" "exit $RC" test "$RC" = 0

# --- 2. two at once ---------------------------------------------------------------------------------------

setcap 2
wbp "$SCRATCH/c1.out" goal new verify-a --base "$BASE"
A=$(newid "$SCRATCH/c1.out")
sleep 1
wbp "$SCRATCH/c2.out" goal new verify-b --base "$BASE"
B=$(newid "$SCRATCH/c2.out")
check "max_active_threads = 2: two threads are started" "a='$A' b='$B'" test -n "$A" -a -n "$B" -a "$A" != "$B"
wbp "$SCRATCH/c3.out" goal new verify-c --base "$BASE"
shown "$SCRATCH/c3.out"
check "a third is refused (exit 6) naming both" "exit $RC: $(head -c 200 "$SCRATCH/c3.out")" \
    bash -c 'test "$1" = 6 && grep -q "$2" "$4" && grep -q "$3" "$4"' _ "$RC" "$A" "$B" "$SCRATCH/c3.out"

# --- 3. which thread -------------------------------------------------------------------------------------

if [ "$SABOTAGE" = 1 ]; then wbp "$SCRATCH/x1.out" abandon --thread "$A"; else wbp "$SCRATCH/x1.out" abandon; fi
shown "$SCRATCH/x1.out"
check "abandon with no id and two active: refused (exit 6), both listed" "exit $RC: $(head -c 200 "$SCRATCH/x1.out")" \
    bash -c 'test "$1" = 6 && grep -q "$2" "$4" && grep -q "$3" "$4"' _ "$RC" "$A" "$B" "$SCRATCH/x1.out"
check "refused: nothing was ended" "a thread has ended" \
    bash -c '! grep -q "abandoned" "$1"' _ "$SCRATCH/x1.out"
wbp "$SCRATCH/x2.out" status --thread "$B" --json
check "status --thread <b> --json is b" "$(head -c 200 "$SCRATCH/x2.out")" \
    bash -c 'python3 -I -c "import json,sys; sys.exit(json.load(open(sys.argv[1]))[\"thread\"] != sys.argv[2])" "$1" "$2"' _ "$SCRATCH/x2.out" "$B"
wbp "$SCRATCH/x3.out" status "$A" --thread "$B"
check "two different threads named: usage error (exit 2)" "exit $RC: $(head -c 200 "$SCRATCH/x3.out")" test "$RC" = 2
wbp "$SCRATCH/x4.out" status --thread no-such-thread
check "a thread that does not exist: not found (exit 7)" "exit $RC" test "$RC" = 7

# The flag may stand before an argument that is not the thread: with the old order these were usage errors (exit 2).
wbp "$SCRATCH/x5.out" send-back --thread no-such-thread "fix it"
check "send-back --thread <id> \"note\": the flag is read first (not found, exit 7)" "exit $RC: $(head -c 200 "$SCRATCH/x5.out")" test "$RC" = 7
wbp "$SCRATCH/x6.out" review-stage --thread no-such-thread design
check "review-stage --thread <id> <stage>: the flag is read first (not found, exit 7)" "exit $RC: $(head -c 200 "$SCRATCH/x6.out")" \
    test "$RC" = 7

wbp "$SCRATCH/x7.out" send-back --thread "$A" "fix it" --thread "$B"
check "--thread given twice for different threads: usage error (exit 2)" "exit $RC: $(head -c 200 "$SCRATCH/x7.out")" test "$RC" = 2

# --- 4. ending one frees a slot and the other needs no id --------------------------------------------------

wbp "$SCRATCH/e1.out" abandon --thread "$A"
check "abandon --thread <a>: exits 0" "exit $RC: $(head -c 200 "$SCRATCH/e1.out")" test "$RC" = 0
wbp "$SCRATCH/e2.out" goal new verify-d --base "$BASE"
check "a slot is free again: a new thread starts" "exit $RC: $(head -c 200 "$SCRATCH/e2.out")" test "$RC" = 0
D=$(newid "$SCRATCH/e2.out")
wbp "$SCRATCH/e3.out" abandon --thread "$D"
wbp "$SCRATCH/e4.out" abandon
shown "$SCRATCH/e4.out"
check "one thread left: abandon needs no id" "exit $RC: $(head -c 200 "$SCRATCH/e4.out")" \
    bash -c 'test "$1" = 0 && grep -q "$2" "$3"' _ "$RC" "$B" "$SCRATCH/e4.out"

finish
