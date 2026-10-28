#!/usr/bin/env bash
# The throwaway Workbench build that the verify-app skill drives, and nothing else: it never touches an installed Workbench.app. The
# parts that keep a verification safe are written once here, so the model has nothing else to call. The same shape as Triage's.
#   scripts/verify-app.sh start [scenario]     build this checkout into a throwaway bundle, copy the fixture project `scenario` (default
#                                              needs-you) into a temporary git repository, launch the app on it, and print its pid,
#                                              window id and size. The app is left running.
#   scripts/verify-app.sh list <pid>           what is on screen: role <tab> label
#   scripts/verify-app.sh press <pid> "<label>"  press that button (an exact label, else a prefix)
#   scripts/verify-app.sh shot <pid> <name>    screenshot the window into $WORKBENCH_PROOF_DIR (default .build/verify)/<name>.png
#   scripts/verify-app.sh stop <pid>           end that build and remove the bundle, the fixture copy and every setting it left
#   scripts/verify-app.sh scenarios            the scenario names
# Every command after `start` takes the pid `start` printed and refuses any other: a pid it did not start, an installed Workbench, or a
# process that has since been replaced, so the window, the button and the process are always this build's.
# Safety, each part written down because a model may be running this:
#   - the build has a bundle id of its own, new for each start (dev.rogal.workbench.verify-<number>), and the app is opened on a
#     fixture project (Fixtures/app/<scenario>/): it reads and writes none of a person's settings or projects
#   - the window is found by pid, never by name, and only that pid is ever ended
#   - `press` refuses the buttons that open a panel or another app (`Choose project`, `Event log`, `Open the event log`), by the label
#     it resolves to, here and again in scripts/ax.swift; a scenario cannot widen the list
#   - a scenario name is lower-case letters and dashes and must be a folder of Fixtures/app/: it cannot reach anywhere else
# A `start` that fails, or is interrupted (Ctrl-C, SIGTERM), leaves nothing: the app it launched is ended and its build folder, fixture copy
# and settings are removed, so no process runs without the caller having its pid. Only a `start` that printed the pid leaves a build.
# Test seam: WORKBENCH_VERIFY_FAULT=before-launch, after-launch, after-window (fail there) or in-launch-gap (a SIGTERM between the launch and recording its
# pid) shows the cleanup without a crash. Ctrl-C has the same handler as SIGTERM and SIGHUP; no test sends it (a background job ignores it).
# Environment: VERIFY_WINDOW_SIZE <width>x<height> in points before any capture (default 1100x700, needs Accessibility);
#   VERIFY_SETTLE_SECONDS wait after the window appears (default 2); WORKBENCH_PROOF_DIR where `shot` writes.
# The terminal running this needs Screen Recording (start, shot) and Accessibility (press, list, resize).
# Exit codes: 0 done, 1 refused or failed (the reason on stderr), 2 usage or not macOS.
set -euo pipefail

PLATFORM="${WORKBENCH_VERIFY_UNAME:-$(uname -s)}"
if [[ "$PLATFORM" != Darwin ]]; then
  echo "verify-app: this drives the macOS app and this is $PLATFORM" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ID_PREFIX="dev.rogal.workbench.verify"
REFUSED='^(Choose project|Event log|Open the event log)'
STATE_ROOT="${TMPDIR:-/tmp}"
STATE_ROOT="${STATE_ROOT%/}/workbench-verify"
PIDS="$STATE_ROOT/pids"

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

fail() {
  echo "verify-app: $*" >&2
  exit 1
}

scenarios() { ls "$ROOT/Fixtures/app" 2>/dev/null | grep -E '^[a-z][a-z-]*$' || true; }

# The directory of the build with this pid, only when that process is still the one we started from it.
build_dir() {
  local pid="$1" dir
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || fail "not a pid: $pid"
  [[ -f "$PIDS/$pid" ]] || fail "pid $pid is not a build started by verify-app.sh start"
  dir="$(<"$PIDS/$pid")"
  [[ "$(ps -o command= -p "$pid" 2>/dev/null)" == "$dir/Workbench.app/Contents/MacOS/WorkbenchApp"* ]] ||
    fail "pid $pid is not running the build in $dir (it ended, or the pid was reused)"
  printf '%s' "$dir"
}

# What the app saved for this bundle id, and nothing under any other id.
forget_settings() {
  local id="$1"
  [[ "$id" == "$ID_PREFIX"-* ]] || return 0
  defaults delete "$id" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$id.plist"
  rm -rf "$HOME/Library/Saved Application State/$id.savedState" "$HOME/Library/Caches/$id" "$HOME/Library/HTTPStorages/$id"
}

# Ends the build with this pid and removes what it left. Quiet when there is nothing to do.
remove_build() {
  local pid="$1" dir="" id=""
  [[ -f "$PIDS/$pid" ]] && dir="$(<"$PIDS/$pid")"
  [[ -n "$dir" && -f "$dir/bundle-id" ]] && id="$(<"$dir/bundle-id")"
  if [[ -n "$dir" && "$(ps -o command= -p "$pid" 2>/dev/null)" == "$dir/Workbench.app/Contents/MacOS/WorkbenchApp"* ]]; then
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PIDS/$pid"
  [[ -n "$dir" && "$dir" == "$STATE_ROOT"/build.* ]] && rm -rf "$dir"
  [[ -n "$id" ]] && forget_settings "$id"
  return 0
}

# Builds a crashed or killed run left: a pid file whose process is gone.
remove_stale() {
  local file pid
  [[ -d "$PIDS" ]] || return 0
  for file in "$PIDS"/*; do
    [[ -f "$file" ]] || continue
    pid="$(basename "$file")"
    kill -0 "$pid" 2>/dev/null || remove_build "$pid"
  done
}

# What `start` has made and not yet handed over. Set from the moment the temporary folder exists; cleared only once the pid was printed.
PENDING_DIR=""
PENDING_ID=""
PENDING_PID=""

# Ends and removes whatever a failed or interrupted `start` made. Idempotent: it clears the pending state first.
abort_start() {
  # `$!` is the last process launched in the background, set the moment it was forked: a signal that arrives after the launch and before
  # PENDING_PID was recorded still finds it. (remove_build only ends a process whose command is this build's, so a stale `$!` is harmless.)
  local code="${1:-$?}" dir="$PENDING_DIR" id="$PENDING_ID" pid="$PENDING_PID" last
  # `$!` is unset until a background process was launched, and `set -u` would stop the cleanup there: a start that failed before the launch
  # (a failed build, say) has no child. bash 3.2 has no `${!:-}`, so unset checking is off for this one read.
  set +u
  last="$!"
  set -u
  [[ -n "$pid" ]] || pid="$last"
  PENDING_DIR="" PENDING_ID="" PENDING_PID=""
  trap - EXIT INT TERM HUP
  if [[ -n "$dir" ]]; then
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
      # The pid file may not exist yet (interrupted between the launch and writing it): remove_build reads the folder from it.
      [[ -f "$PIDS/$pid" ]] || printf '%s' "$dir" >"$PIDS/$pid"
      remove_build "$pid"
    fi
    [[ -n "$id" ]] && forget_settings "$id"
    [[ "$dir" == "$STATE_ROOT"/build.* ]] && rm -rf "$dir"
  fi
  exit "$code"
}

start() {
  local scenario="${1:-needs-you}" size="${VERIFY_WINDOW_SIZE:-1100x700}" dir id pid window
  [[ "$scenario" =~ ^[a-z][a-z-]*$ ]] || fail "not a scenario name: $scenario (lower-case letters and dashes)"
  [[ -d "$ROOT/Fixtures/app/$scenario" ]] || fail "no such scenario: $scenario (have: $(scenarios | tr '\n' ' '))"
  [[ "$size" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]] || fail "bad VERIFY_WINDOW_SIZE: $size (want <width>x<height>)"

  # Without Screen Recording, screencapture saves a wallpaper-only image instead of failing.
  swift - <<'SWIFT' || fail "this terminal has no Screen Recording permission (System Settings, Privacy & Security): a screenshot would show only the wallpaper"
import CoreGraphics
import Foundation
exit(CGPreflightScreenCaptureAccess() ? 0 : 1)
SWIFT

  mkdir -p "$PIDS"
  remove_stale
  dir="$(mktemp -d "$STATE_ROOT/build.XXXXXX")"
  id="$ID_PREFIX-$RANDOM$RANDOM"
  PENDING_DIR="$dir" PENDING_ID="$id"
  trap 'abort_start' EXIT
  trap 'abort_start 130' INT
  trap 'abort_start 143' TERM
  trap 'abort_start 129' HUP
  printf '%s' "$id" >"$dir/bundle-id"
  [[ "${WORKBENCH_VERIFY_FAULT:-}" != before-launch ]] || fail "injected fault: before-launch"

  # The fixture project: the scenario's threads in a temporary git repository (the app opens a git repository's .workbench/).
  mkdir -p "$dir/project/.workbench"
  git -C "$dir/project" init -q -b main
  if [[ -d "$ROOT/Fixtures/app/$scenario/threads" ]]; then
    cp -R "$ROOT/Fixtures/app/$scenario/threads" "$dir/project/.workbench/threads"
  else
    mkdir -p "$dir/project/.workbench/threads"
  fi

  # The build: bundle-app.sh, to a path and a bundle id of its own.
  WORKBENCH_APP="$dir/Workbench.app" WORKBENCH_BUNDLE_ID="$id" "$ROOT/scripts/bundle-app.sh" >&2 || fail "the build failed"

  # Launched directly, so its pid is certain, with the project in its environment.
  WORKBENCH_APP_PROJECT="$dir/project" "$dir/Workbench.app/Contents/MacOS/WorkbenchApp" >"$dir/app.log" 2>&1 &
  # The gap between the launch and recording its pid: the seam delivers a SIGTERM exactly here (the handler runs before the next command).
  [[ "${WORKBENCH_VERIFY_FAULT:-}" != in-launch-gap ]] || kill -TERM $$
  pid=$!
  PENDING_PID="$pid"
  disown "$pid" 2>/dev/null || true
  printf '%s' "$dir" >"$PIDS/$pid"
  [[ "${WORKBENCH_VERIFY_FAULT:-}" != after-launch ]] || fail "injected fault: after-launch"

  window=""
  for _ in $(seq 1 60); do
    kill -0 "$pid" 2>/dev/null || fail "the app ended at once: $(head -c 300 "$dir/app.log" 2>/dev/null | tr '\n' ' ')"
    window="$(swift "$ROOT/scripts/window-info.swift" "$pid" 2>/dev/null || true)"
    [[ -n "$window" ]] && break
    sleep 0.5
  done
  [[ -n "$window" ]] || fail "no window appeared in 30 s"

  if ! WORKBENCH_PID="$pid" swift "$ROOT/scripts/ax.swift" resize "${size%x*}" "${size#*x}" >/dev/null 2>"$dir/ax.err"; then
    echo "verify-app: window left at its launch size: $(head -c 200 "$dir/ax.err")" >&2
  fi
  [[ "${WORKBENCH_VERIFY_FAULT:-}" != after-window ]] || fail "injected fault: after-window"
  sleep "${VERIFY_SETTLE_SECONDS:-2}"
  window="$(swift "$ROOT/scripts/window-info.swift" "$pid")"
  read -r wid wx wy ww wh <<<"$window"
  echo "pid=$pid"
  echo "window=$wid"
  echo "size=${ww}x${wh}"
  # Handed over: the caller has the pid, so `stop` can end it. If nobody could read the lines above, the failed write already ran the trap.
  PENDING_DIR="" PENDING_ID="" PENDING_PID=""
  trap - EXIT INT TERM HUP
}

command="${1:-}"
[[ -n "$command" ]] || usage
shift || true
case "$command" in
  start) start "${1:-}" ;;
  scenarios) scenarios ;;
  list)
    [[ $# -eq 1 ]] || usage
    build_dir "$1" >/dev/null
    WORKBENCH_PID="$1" swift "$ROOT/scripts/ax.swift" list
    ;;
  press)
    [[ $# -eq 2 ]] || usage
    build_dir "$1" >/dev/null
    [[ -n "$2" ]] || fail "press needs a label"
    [[ "$2" =~ $REFUSED ]] && fail "refused: \"$2\" opens a panel or another app"
    WORKBENCH_PID="$1" WORKBENCH_REFUSE="$REFUSED" swift "$ROOT/scripts/ax.swift" press "$2"
    ;;
  shot)
    [[ $# -eq 2 ]] || usage
    build_dir "$1" >/dev/null
    [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "not a screenshot name: $2"
    out="${WORKBENCH_PROOF_DIR:-$ROOT/.build/verify}"
    mkdir -p "$out"
    info="$(swift "$ROOT/scripts/window-info.swift" "$1")" || fail "pid $1 has no window on screen"
    read -r wid _ <<<"$info"
    screencapture -x -o -l "$wid" "$out/$2.png"
    [[ -s "$out/$2.png" ]] || fail "screencapture wrote nothing"
    echo "$out/$2.png"
    ;;
  stop)
    [[ $# -eq 1 ]] || usage
    build_dir "$1" >/dev/null
    remove_build "$1"
    echo "stopped $1"
    ;;
  *) usage ;;
esac
