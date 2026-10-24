#!/bin/bash
# Does the installed Swift toolchain still have the `JumpThreadSimplifyCFG` bug that Package.swift works around? Compiles the case in
# docs/swift-bugs/ with SIL verification, with and without the pass disabled. Prints "still broken" (the workaround is needed),
# "fixed" (remove it from Package.swift and this script), "not applicable" (a toolchain older than the one the bug was found on, so
# "both compile" says nothing about a fix) or "inconclusive". Exit 0 for the first three, 1 for the last.
# `--fail-when-fixed` exits 3 on "fixed", so a scheduled run tells the owner the workaround can go.
set -u
fail_when_fixed=0
[ "${1:-}" = "--fail-when-fixed" ] && fail_when_fixed=1
dir=$(mktemp -d "${TMPDIR:-/tmp}/swift-bug-repro.XXXXXX") || exit 1
trap 'rm -rf "$dir"' EXIT
# SWIFT_BUG_REPRO_SRC replaces the case, to test this script's own branches with a file that compiles.
src=${SWIFT_BUG_REPRO_SRC:-"$(cd "$(dirname "$0")/.." && pwd)/docs/swift-bugs/simplify-cfg-async.swift"}
[ -f "$src" ] || { echo "inconclusive: $src is missing"; exit 1; }
version_line=$(swiftc --version 2>&1 | head -1)
echo "$version_line"
# The bug was found on 6.2.1; an older compiler compiling the case proves nothing, so it must not say "fixed".
found_on=6.2.1
version=$(echo "$version_line" | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p')
broken=0
swiftc -O -parse-as-library -Xfrontend -sil-verify-all "$src" -o "$dir/a" >"$dir/with.log" 2>&1 || broken=1
swiftc -O -parse-as-library -Xfrontend -sil-verify-all -Xllvm -sil-disable-pass=simplify-cfg "$src" -o "$dir/b" >"$dir/without.log" 2>&1
without=$?
if [ "$broken" = 1 ] && [ "$without" = 0 ] && grep -q "SIL verification failed" "$dir/with.log"; then
    echo "still broken: the compiler aborts in JumpThreadSimplifyCFG and compiles with simplify-cfg disabled; keep the workaround"
    exit 0
elif [ "$broken" = 0 ] && [ "$without" = 0 ] && [ -n "$version" ] && [ "$(printf '%s\n%s\n' "$found_on" "$version" | sort -V | head -1)" != "$found_on" ]; then
    echo "not applicable: Swift $version is older than $found_on, where the bug was found; this says nothing about a fix"
    exit 0
elif [ "$broken" = 0 ] && [ "$without" = 0 ]; then
    echo "fixed: both compile; the workaround in Package.swift can go"
    if [ "$fail_when_fixed" = 1 ]; then exit 3; fi
    exit 0
else
    echo "inconclusive: see the logs"; sed -n 1,5p "$dir/with.log"; exit 1
fi
