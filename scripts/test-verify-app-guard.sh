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
# `swift -` is the Screen Recording check, which the stub passes; anything else is a build, a window or a helper, which it refuses.
printf '#!/bin/sh\nif [ "$1" = "-" ]; then cat >/dev/null; exit 0; fi\necho "test stub: this test must never reach swift" >&2\nexit 1\n' > "$TMPDIR/stubs/swift"
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
expect 1 "is not a build started by verify-app.sh start" type 1 "text"
expect 1 "is not a build started by verify-app.sh start" paste 1
expect 1 "is not a build started by verify-app.sh start" shot 1 name
expect 1 "is not a build started by verify-app.sh start" stop 99999
expect 1 "is not a build started by verify-app.sh start" calls 1
expect 1 "not a pid" calls "../x"
expect 1 "not a pid" list abc
expect 1 "not a pid" stop "1; rm -rf /"
expect 1 "not a pid" press "../x" "Doctor"
# a scenario name cannot reach outside Fixtures/app/
expect 1 "not a scenario name" start "../etc"
expect 1 "not a scenario name" start "needs-you/.."
expect 1 "not a scenario name" start "Needs-You"
expect 1 "not a scenario name" start "-rf"
expect 1 "no such scenario" start nothing-like-it
# a `start` that fails before it launched anything (so there is no child, and no `$!`) still removes what it made. This is the cleanup
# path of a failed build; the Screen Recording check is passed by the stub, and the fault is injected right after the folder exists.
out=$(WORKBENCH_VERIFY_FAULT=before-launch scripts/verify-app.sh start needs-you 2>&1); code=$?
[ "$code" = 1 ] || fail "a start that failed before launching exits $code, not 1: $out"
echo "$out" | grep -qF "injected fault: before-launch" || fail "a start that failed before launching does not say why: $out"
echo "$out" | grep -qi "unbound variable" && fail "the cleanup of a start with no child stopped on an unset variable: $out"
[ "$(ls "$TMPDIR/workbench-verify" 2>/dev/null | grep -c '^build\.')" = 0 ] || fail "a start that failed before launching left its build folder"
# a pid file left by a run that ended is not a build either: it is refused, and nothing is killed
mkdir -p "$TMPDIR/workbench-verify/pids"
echo "$TMPDIR/workbench-verify/build.gone" > "$TMPDIR/workbench-verify/pids/424242"
expect 1 "is not running the build" stop 424242
[ -f "$TMPDIR/workbench-verify/pids/424242" ] || fail "a refused stop removed the pid file of a process it never checked"

# --- a live process behind a recorded pid: only the recorded build is ever touched ---------------------------------------------------
# `sleep` run under the name of the path a build would run from stands in for the app: `ps` shows that name, which is all the check reads.
# (`exec -a`, not a copy of the binary: macOS kills a copy of a signed system binary at once.)
STATE="$TMPDIR/workbench-verify"
PIDS="$STATE/pids"
mkdir -p "$PIDS"
SLEEP="$(command -v sleep)"
LIVE=""
trap 'for p in $LIVE; do kill "$p" 2>/dev/null; done; rm -rf "$TMPDIR"' EXIT
# fake_app <folder>: runs the stand-in as <folder>/Workbench.app/Contents/MacOS/WorkbenchApp and sets FAKE_PID to its pid
fake_app() {
  local bin="$1/Workbench.app/Contents/MacOS/WorkbenchApp"
  mkdir -p "$1"
  (exec -a "$bin" "$SLEEP" 300) &
  FAKE_PID=$!
  disown "$FAKE_PID" 2>/dev/null || true  # no "Terminated" job noise when a stand-in is ended
  LIVE="$LIVE $FAKE_PID"
  sleep 0.2
}
alive() { kill -0 "$1" 2>/dev/null; }

# 1. an installed Workbench behind a recorded pid: refused by every command, and not killed
fake_app "$TMPDIR/Applications"
installed=$FAKE_PID
echo "$STATE/build.recorded" > "$PIDS/$installed"
for command in "stop $installed" "list $installed" "press $installed Doctor" "type $installed text" "paste $installed" "shot $installed name" "calls $installed"; do
  # shellcheck disable=SC2086
  expect 1 "is not running the build" $command
done
alive "$installed" || fail "an installed Workbench behind a recorded pid was killed"

# 2. a build whose folder only starts like the recorded one: also not it
fake_app "$STATE/build.lookalike"
lookalike=$FAKE_PID
echo "$STATE/build.look" > "$PIDS/$lookalike"
expect 1 "is not running the build" stop "$lookalike"
alive "$lookalike" || fail "a process in a lookalike folder was killed"

# 3. the recorded build itself: press refuses what opens a panel before any helper runs, list passes the pid check, stop ends it
fake_app "$STATE/build.real"
real=$FAKE_PID
echo "$STATE/build.real" > "$PIDS/$real"
expect 1 "opens a panel or another app" press "$real" "Event log"
expect 1 "opens a panel or another app" press "$real" "Choose project, now x"
expect 1 "opens a panel or another app" press "$real" "Open the event log"
expect 1 "press needs a label" press "$real" ""
expect 1 "test stub" list "$real"   # past the pid check, as far as the helper, which the stub refuses
alive "$real" || fail "a refused press ended the build"
expect 0 "stopped $real" stop "$real"
sleep 0.3
alive "$real" && fail "stop did not end the recorded build"
[ -e "$STATE/build.real" ] && fail "stop left the build folder"
[ -e "$PIDS/$real" ] && fail "stop left the pid file"
alive "$installed" || fail "stopping one build ended another process"

[ "$status" = 0 ] && echo "verify-app guard: ok"
exit $status
