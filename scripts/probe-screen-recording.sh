#!/bin/sh
# A verify_command for measuring, by hand, whether a child of `workbench doctor` inherits the terminal's
# Screen Recording grant. Set it as verify_command with app_type = "desktop" in a scratch project's config,
# run `workbench doctor` from the terminal you use, then read $WORKBENCH_PROBE_OUT (default
# ~/workbench-probe.txt) and the image next to it: doctor hides the output of a verify that passes and deletes
# its proof directory. Not part of any check.
set -u
out=${WORKBENCH_PROBE_OUT:-$HOME/workbench-probe.txt}
granted=$(/usr/bin/swift -e 'import CoreGraphics; print(CGPreflightScreenCaptureAccess())' 2>/dev/null)
{
    echo "responsible app: ${TERM_PROGRAM:-unknown}"
    echo "CGPreflightScreenCaptureAccess in the child: ${granted:-unknown}"
} > "$out"
cat "$out"
/usr/sbin/screencapture -x "${out%.txt}.png" || { echo "screencapture failed" | tee -a "$out"; exit 1; }
echo "image: ${out%.txt}.png" | tee -a "$out"
[ "$granted" = "true" ]
