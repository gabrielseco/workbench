#!/usr/bin/env bash
# Checks verify-app.sh's refusals, which need neither macOS tools nor a build, so the Linux lint job runs it: every command after `start`
# refuses a pid it did not start, and a scenario name cannot reach outside Fixtures/app/. WORKBENCH_VERIFY_UNAME stands in for `uname -s`.
set -u
cd "$(dirname "$0")/.."
export WORKBENCH_VERIFY_UNAME=Darwin
export TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
# If a guard under test is broken, `start` must not get as far as building or launching a real app: nothing here may reach a compiler.
mkdir -p "$TMPDIR/stubs"
printf '#!/bin/sh\necho "test stub: this test must never reach swift" >&2\nexit 1\n' > "$TMPDIR/stubs/swift"
chmod +x "$TMPDIR/stubs/swift"
export PATH="$TMPDIR/stubs:$PATH"
status=0
fail() { echo "FAIL: $*" >&2; status=1; }
# expect <exit code> <text the message must contain> <args...>
expect() {
  local want="$1" text="$2"
  shift 2
  local out code
  out=$(scripts/verify-app.sh "$@" 2>&1); code=$?
  [ "$code" = "$want" ] || fail "'$*' exits $code, not $want: $out"
  echo "$out" | grep -qF -- "$text" || fail "'$*' does not say '$text': $out"
}

out=$(WORKBENCH_VERIFY_UNAME=Linux scripts/verify-app.sh start 2>&1); code=$?
[ "$code" = 2 ] || fail "on Linux it exits $code, not 2"
echo "$out" | grep -q "macOS app and this is Linux" || fail "on Linux it does not say why: $out"

expect 2 "start [scenario]"
expect 2 "start [scenario]" frobnicate
# a pid it did not start, whatever the command
expect 1 "is not a build started by verify-app.sh start" list 1
expect 1 "is not a build started by verify-app.sh start" press 1 "Doctor"
expect 1 "is not a build started by verify-app.sh start" shot 1 name
expect 1 "is not a build started by verify-app.sh start" stop 99999
expect 1 "not a pid" list abc
expect 1 "not a pid" stop "1; rm -rf /"
expect 1 "not a pid" press "../x" "Doctor"
# a scenario name cannot reach outside Fixtures/app/
expect 1 "not a scenario name" start "../etc"
expect 1 "not a scenario name" start "needs-you/.."
expect 1 "not a scenario name" start "Needs-You"
expect 1 "not a scenario name" start "-rf"
expect 1 "no such scenario" start nothing-like-it
# a pid file left by a run that ended is not a build either: it is refused, and nothing is killed
mkdir -p "$TMPDIR/workbench-verify/pids"
echo "$TMPDIR/workbench-verify/build.gone" > "$TMPDIR/workbench-verify/pids/424242"
expect 1 "is not running the build" stop 424242
[ -f "$TMPDIR/workbench-verify/pids/424242" ] || fail "a refused stop removed the pid file of a process it never checked"

[ "$status" = 0 ] && echo "verify-app guard: ok"
exit $status
