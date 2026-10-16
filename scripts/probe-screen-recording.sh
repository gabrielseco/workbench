#!/bin/sh
# A verify_command for measuring, by hand, whether a child of `workbench doctor` inherits the terminal's
# Screen Recording grant. Set it as verify_command with app_type = "desktop" in a scratch project's config,
# run `workbench doctor` from the terminal you use, and read the output. Not part of any check.
set -u
swift_bin=/usr/bin/swift
granted=$($swift_bin -e 'import CoreGraphics; print(CGPreflightScreenCaptureAccess())' 2>/dev/null)
echo "responsible app: ${TERM_PROGRAM:-unknown}"
echo "CGPreflightScreenCaptureAccess in the child: ${granted:-unknown}"
/usr/sbin/screencapture -x "$WORKBENCH_PROOF_DIR/probe.png" || echo "screencapture failed"
[ "$granted" = "true" ]
