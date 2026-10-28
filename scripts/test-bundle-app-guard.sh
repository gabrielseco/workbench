#!/usr/bin/env bash
# Checks bundle-app.sh's refusals, which need neither macOS nor a build: the PR gate runs it on Linux, where the script must say no
# clearly and change nothing. WORKBENCH_BUNDLE_UNAME stands in for `uname -s`.
set -u
cd "$(dirname "$0")/.."
status=0
fail() { echo "FAIL: $*" >&2; status=1; }

out=$(WORKBENCH_BUNDLE_UNAME=Linux scripts/bundle-app.sh 2>&1); code=$?
[ "$code" = 2 ] || fail "on Linux it exits $code, not 2"
echo "$out" | grep -q "macOS app and this is Linux" || fail "on Linux it does not say why: $out"

out=$(WORKBENCH_BUNDLE_UNAME=Darwin WORKBENCH_APP=/tmp/not-an-app scripts/bundle-app.sh 2>&1); code=$?
[ "$code" = 2 ] || fail "a WORKBENCH_APP that does not end in .app exits $code, not 2"

out=$(WORKBENCH_BUNDLE_UNAME=Darwin scripts/bundle-app.sh --bogus 2>&1); code=$?
[ "$code" = 2 ] || fail "an unknown flag exits $code, not 2"

out=$(WORKBENCH_BUNDLE_UNAME=Darwin WORKBENCH_BUNDLE_ID='a b' scripts/bundle-app.sh 2>&1); code=$?
[ "$code" = 2 ] || fail "a bundle id with a space exits $code, not 2"

[ "$status" = 0 ] && echo "bundle-app guard: ok"
exit $status
