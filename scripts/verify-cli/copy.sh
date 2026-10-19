#!/bin/bash
# verify-cli scenario for the `copy` config key, on this repository. `workbench doctor` cuts the same kind of worktree a
# thread does, so no turn is run and it costs nothing.
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/copy.sh   (in the main checkout, on a branch that contains origin/main)
# Puts an ignored probe file (.build/verify-copy-probe.txt) in this checkout, adds `copy` and a `setup_command` that
# prints it to .workbench/config.toml (restored on exit), and runs doctor: the setup output must show the probe's
# contents, so the file reached the new worktree before setup ran, and the doctor worktree must be gone afterwards.
# Then a `copy` entry that points out of the repository must make the config refuse to load. Exit 0 only when every step
# passed, 1 when one failed, 2 when it refused to start (nothing changed). VERIFY_CLI_SABOTAGE=1 leaves the probe out, so
# the "setup sees the copied file" step must FAIL. The frame and the other switches are in lib.sh. Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

CONFIG="$ROOT/.workbench/config.toml"
PROBE=".build/verify-copy-probe.txt"
[ -f "$CONFIG" ] || die "no $CONFIG; this scenario edits it (and puts it back)"
grep -Eq '^(copy|setup_command)[[:space:]]*=' "$CONFIG" && die "$CONFIG already sets copy or setup_command; this scenario will not overwrite them"

cp "$CONFIG" "$SCRATCH/config.orig"
restore() { cp "$SCRATCH/config.orig" "$CONFIG" 2>/dev/null; rm -f "$ROOT/$PROBE"; }
trap restore EXIT

with_config() { # <lines>: the original config with <lines> as its first root keys
    { printf '%s\n' "$1"; cat "$SCRATCH/config.orig"; } >"$CONFIG"
}
doctor_to() { # <file>: doctor's output into <file>, its exit code on stdout
    wb "$T_RUN" doctor >"$1" 2>&1
    echo $?
}

# --- 1. a matching ignored file reaches the worktree before setup ------------------------------------------

[ "$SABOTAGE" = 1 ] && echo "    VERIFY_CLI_SABOTAGE=1: no probe file in the checkout" || echo "copy-probe" >"$ROOT/$PROBE"
check "the probe is ignored by git" "git does not ignore $PROBE" bash -c 'echo x >"$1" 2>/dev/null; git check-ignore -q "$1"; r=$?; [ -s "$1" ] || rm -f "$1"; exit $r' _ "$ROOT/$PROBE"
[ "$SABOTAGE" = 1 ] && rm -f "$ROOT/$PROBE"

with_config "copy = [\".build/verify-*.txt\"]
setup_command = \"cat $PROBE\""
code=$(doctor_to "$SCRATCH/doctor1.out")
sed 's/^/    /' "$SCRATCH/doctor1.out" | head -14
check "doctor with copy: exit 0" "workbench doctor exited $code" test "$code" = 0
check "doctor with copy: setup sees the copied file" "the setup output has no 'copy-probe'" grep -q 'copy-probe' "$SCRATCH/doctor1.out"
check "doctor leaves no worktree or branch of its own" "doctor's worktree or branch is still there" \
    bash -c '! git rev-parse -q --verify refs/heads/workbench/doctor >/dev/null && [ ! -e "$1/.workbench/worktrees/doctor" ]' _ "$ROOT"
check "the checkout is unchanged" "git status shows: $(g status --porcelain)" test -z "$(g status --porcelain)"

# --- 2. a path out of the repository is refused when the config loads --------------------------------------

with_config 'copy = ["../.env"]'
code=$(doctor_to "$SCRATCH/doctor2.out")
sed 's/^/    /' "$SCRATCH/doctor2.out" | head -4
check "copy outside the repository: doctor refuses" "workbench doctor exited $code" test "$code" != 0
check "copy outside the repository: names the key" "the output does not mention 'copy'" grep -q "'copy'" "$SCRATCH/doctor2.out"

finish
