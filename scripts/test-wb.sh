#!/usr/bin/env bash
# Checks scripts/wb builds before it runs, passes arguments and the caller's directory through, and does not run a stale binary
# when the build fails. A fake `swift` and a fake binary stand in, so nothing is compiled.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILED=0
result() { if [[ "$2" == "$3" ]]; then echo "PASS  $1"; else echo "FAIL  $1: wanted '$3', got '$2'"; FAILED=1; fi; }
mkdir -p "$TMP/repo/scripts" "$TMP/repo/.build/debug" "$TMP/bin" "$TMP/project"
cp "$ROOT/scripts/wb" "$ROOT/scripts/use-xcode.sh" "$TMP/repo/scripts/"
cp "$ROOT/.xcode-version" "$TMP/repo/"
printf '#!/usr/bin/env bash\necho "ran in $PWD with: $*"\n' >"$TMP/repo/.build/debug/workbench"
printf '#!/usr/bin/env bash\necho built >>"%s/log"\n[[ -z "${FAKE_SWIFT_FAIL:-}" ]]\n' "$TMP" >"$TMP/bin/swift"
chmod +x "$TMP/repo/.build/debug/workbench" "$TMP/bin/swift"
run() { (cd "$TMP/project" && PATH="$TMP/bin:$PATH" DEVELOPER_DIR=/x "$@" "$TMP/repo/scripts/wb" doctor --json 2>"$TMP/err"; echo "exit $?"); }
out="$(run env)"
result "builds, then runs from the caller's directory with its arguments" "$out" "ran in $(cd "$TMP/project" && pwd) with: doctor --json
exit 0"
result "built exactly once" "$(wc -l <"$TMP/log" | tr -d ' ')" "1"
out="$(run env FAKE_SWIFT_FAIL=1)"
result "a failed build exits 70 and runs nothing" "$out" "exit 70"
exit "$FAILED"
