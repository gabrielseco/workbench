#!/bin/bash
# verify-cli scenario for the timer (`task timer install | status | remove` and the hint on `task approve`), on a clone of this repository
# in the temp folder, with a stand-in `launchctl` and a temporary HOME: nothing real is loaded or written outside the temp folder. No turn is
# run, so it costs nothing.
#   bash scripts/verify-cli/task-timer.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/task-timer.sh   (the same, on a branch that contains origin/main)
# Approving a scheduled task with no timer must print one hint naming `task timer install` (and none once it is installed). `install` must
# write an executable launcher and a valid agent file under HOME, load the agent through launchctl (unload any old copy first, then
# bootstrap) and print the `sudo pmset repeat wakeorpoweron MTWRF 03:55:00` line for the person to run, saying Workbench does not run sudo.
# `status` must say the agent is loaded and the task approved, with a wake line; a second `install --every 5m --pull-main` must replace the
# files; a bad interval is exit 2; an agent that is not loaded is a FAIL with exit 1; `remove` must unload it, delete both files and name
# `sudo pmset repeat cancel`; when launchctl refuses to unload, `remove` must fail (exit 1), delete nothing and say so. Each of
# `help task timer install|status|remove` must answer. launchctl must be the only program run: its calls are bootout, bootstrap and print and nothing else.
# Exit 0 only when every step passed, 1 when one failed, 2 when it refused to start (nothing changed).
# VERIFY_CLI_SABOTAGE=1 makes the stand-in launchctl refuse to load, so "install writes the launcher and the agent and loads it",
# "install prints the wake line and says it does not run sudo" (a failed load stops the output), "status says the agent is loaded and the
# task approved" and "a second install replaces the files" must FAIL. The frame is in lib.sh. Run by
# hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

ORIGIN="$SCRATCH/origin.git"
P="$SCRATCH/project"
HOME_T="$SCRATCH/home"
LC="$SCRATCH/launchctl"
g clone -q --bare "$ROOT" "$ORIGIN" || die "git clone --bare failed"
g -C "$ORIGIN" update-ref refs/heads/main "$BASE_SHA" || die "could not set main in the bare copy"
g -C "$ORIGIN" symbolic-ref HEAD refs/heads/main || die "could not point the bare copy's HEAD at main"
g clone -q "$ORIGIN" "$P" || die "git clone failed"
g -C "$P" checkout -q -B main origin/main || die "could not check out main in the clone"
mkdir -p "$HOME_T" "$LC" || die "could not make the temp folders"

# A launchctl that records its calls and keeps a "loaded" flag. It is the only program the timer runs.
cat >"$LC/launchctl" <<STUB
#!/bin/sh
echo "\$@" >>"$LC/calls"
case "\$1" in
bootout)
    if [ -f "$LC/fail_bootout" ]; then echo "Boot-out failed: 5: Input/output error" >&2; exit 5; fi
    if [ -f "$LC/loaded" ]; then rm "$LC/loaded"; exit 0; fi; echo "no such service" >&2; exit 3 ;;
bootstrap) if [ -f "$LC/refuse" ]; then echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; fi; touch "$LC/loaded"; exit 0 ;;
print)
    if [ -f "$LC/loaded" ]; then printf '\tstate = not running\n\truns = 0\n\tlast exit code = 0\n\trun interval = 900 seconds\n'; exit 0; fi
    echo "Could not find service" >&2; exit 113 ;;
esac
exit 2
STUB
chmod +x "$LC/launchctl"
if [ "$SABOTAGE" = 1 ]; then : >"$LC/refuse"; echo "    VERIFY_CLI_SABOTAGE=1: the stand-in launchctl refuses to load"; fi
echo "==> clone at $P, home $HOME_T, stand-in launchctl $LC/launchctl"

RC=0
wbp() { # <out> args...: a workbench command in the clone with the temporary HOME and the stand-in launchctl; stdout and stderr together
    local o=$1; shift
    echo "workbench $*   (in the clone, HOME=temp)" >>"$SCRATCH/commands"
    echo "\$ workbench $*   (in the clone, HOME=temp)" >&2
    ( cd "$P" && HOME="$HOME_T" WORKBENCH_LAUNCHCTL="$LC/launchctl" with_timeout "$T_WB" "$WB" "$@" >"$o" 2>&1 )
    RC=$?
}
shown() { sed 's/^/    /' "$1" | head -${2:-12}; }

wbp "$SCRATCH/init.out" init
check "init writes a config in the clone" "workbench init exited $RC" test "$RC" = 0
mkdir -p "$P/.workbench/tasks/nightly"
printf -- '---\nat: 04:00\ndays: weekdays\nfix: report\n---\nA nightly job.\n' >"$P/.workbench/tasks/nightly/task.md"

# --- 1. the hint --------------------------------------------------------------------------------------------

wbp "$SCRATCH/approve1.out" task approve nightly; shown "$SCRATCH/approve1.out" 6
check "approving a scheduled task with no timer prints the hint" "exit $RC: $(head -c 300 "$SCRATCH/approve1.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "^hint: it runs weekdays 04:00, but no timer is installed: workbench task timer install" "$2"' _ "$RC" "$SCRATCH/approve1.out"

# --- 2. install ----------------------------------------------------------------------------------------------

wbp "$SCRATCH/install1.out" task timer install; shown "$SCRATCH/install1.out" 12
LAUNCHER=$(ls "$HOME_T"/.workbench/timers/*/tick.sh 2>/dev/null | head -1)
PLIST=$(ls "$HOME_T"/Library/LaunchAgents/com.workbench.task-tick.*.plist 2>/dev/null | head -1)
check "install writes the launcher and the agent and loads it" "exit $RC: $(head -c 300 "$SCRATCH/install1.out")" \
    bash -c '[ "$1" = 0 ] && [ -x "$2" ] && [ -f "$3" ] && sh -n "$2" && plutil -lint "$3" >/dev/null && [ -f "$4/loaded" ] && grep -q "task tick" "$2"' _ "$RC" "$LAUNCHER" "$PLIST" "$LC"
check "install prints the wake line and says it does not run sudo" "got: $(head -c 500 "$SCRATCH/install1.out")" \
    bash -c 'grep -q "^  sudo pmset repeat wakeorpoweron MTWRF 03:55:00" "$1" && grep -q "Workbench does not run sudo" "$1" && grep -q "plugged in and logged in" "$1"' _ "$SCRATCH/install1.out"
check "the launcher runs from the project with caffeinate" "launcher: $(grep -c caffeinate "$LAUNCHER" 2>&1)" \
    bash -c 'grep -q "^cd .*project.* || exit 1" "$1" && grep -q "/usr/bin/caffeinate -i .* task tick" "$1"' _ "$LAUNCHER"
wbp "$SCRATCH/approve2.out" task approve nightly
check "once the timer is installed the hint is gone" "got: $(head -c 300 "$SCRATCH/approve2.out")" \
    bash -c '! grep -q "no timer is installed" "$1"' _ "$SCRATCH/approve2.out"

# --- 3. status -----------------------------------------------------------------------------------------------

wbp "$SCRATCH/status1.out" task timer status; shown "$SCRATCH/status1.out" 10
check "status says the agent is loaded and the task approved, with a wake line" "exit $RC: $(head -c 400 "$SCRATCH/status1.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "^ok   agent: loaded" "$2" && grep -q "^ok   task nightly: approved, weekdays 04:00" "$2" && grep -q "wake:" "$2"' _ "$RC" "$SCRATCH/status1.out"

# --- 4. install again ----------------------------------------------------------------------------------------

wbp "$SCRATCH/install2.out" task timer install --every 5m --pull-main
check "a second install replaces the files" "exit $RC: $(head -c 300 "$SCRATCH/install2.out")" \
    bash -c '[ "$1" = 0 ] && grep -q "git pull --ff-only" "$2" && grep -q "<integer>300</integer>" "$3" && [ "$(grep -c "^bootstrap" "$4/calls")" = 2 ]' _ "$RC" "$LAUNCHER" "$PLIST" "$LC"
wbp "$SCRATCH/bad.out" task timer install --every 2h
check "a bad interval is a usage error (exit 2)" "exit $RC: $(head -c 200 "$SCRATCH/bad.out")" test "$RC" = 2

# --- 5. an agent that is not loaded --------------------------------------------------------------------------

rm -f "$LC/loaded"
wbp "$SCRATCH/status2.out" task timer status
check "an agent that is not loaded is a FAIL (exit 1)" "exit $RC: $(head -c 300 "$SCRATCH/status2.out")" \
    bash -c '[ "$1" = 1 ] && grep -q "^FAIL agent: installed but not loaded" "$2"' _ "$RC" "$SCRATCH/status2.out"

# --- 5b. a remove that cannot unload ---------------------------------------------------------------------------

: >"$LC/fail_bootout"
wbp "$SCRATCH/stuck.out" task timer remove; shown "$SCRATCH/stuck.out" 4
check "a remove that cannot unload fails (exit 1) and deletes nothing" "exit $RC: $(head -c 300 "$SCRATCH/stuck.out")" \
    bash -c '[ "$1" = 1 ] && grep -q "^could not unload" "$2" && grep -q "nothing was deleted" "$2" && [ -f "$3" ] && [ -f "$4" ]' _ "$RC" "$SCRATCH/stuck.out" "$LAUNCHER" "$PLIST"
rm -f "$LC/fail_bootout"

# --- 6. remove -----------------------------------------------------------------------------------------------

wbp "$SCRATCH/remove.out" task timer remove; shown "$SCRATCH/remove.out" 8
check "remove deletes both files and names the sudo line to cancel the wake" "exit $RC: $(head -c 300 "$SCRATCH/remove.out")" \
    bash -c '[ "$1" = 0 ] && [ ! -e "$2" ] && [ ! -e "$3" ] && grep -q "sudo pmset repeat cancel" "$4"' _ "$RC" "$LAUNCHER" "$PLIST" "$SCRATCH/remove.out"
wbp "$SCRATCH/status3.out" task timer status
check "after remove status says it is not installed (exit 1)" "exit $RC: $(head -c 200 "$SCRATCH/status3.out")" \
    bash -c '[ "$1" = 1 ] && grep -q "^FAIL agent: not installed" "$2"' _ "$RC" "$SCRATCH/status3.out"

# --- 6b. each form has its own help --------------------------------------------------------------------------

bad_help=""
for form in install status remove; do
    wbp "$SCRATCH/help-$form.out" help task timer "$form"
    { [ "$RC" = 0 ] && grep -q "^workbench task timer $form" "$SCRATCH/help-$form.out"; } || bad_help="$bad_help $form"
done
check "help answers for task timer install, status and remove" "failed for:$bad_help" test -z "$bad_help"

# --- 7. launchctl is the only program run -----------------------------------------------------------------------

check "launchctl was only asked to bootout, bootstrap and print" "calls: $(sort -u "$LC/calls" | cut -c1-60 | tr '\n' ';')" \
    bash -c '! grep -vE "^(bootout|bootstrap|print) " "$1"' _ "$LC/calls"

finish
