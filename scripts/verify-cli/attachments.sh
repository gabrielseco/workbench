#!/bin/bash
# verify-cli scenario for a goal's screenshots reaching the coding turn, with the real `claude`, on this repository.
#   bash scripts/verify-cli/attachments.sh      (in the main checkout, on a clean origin/main, no active thread)
#   VERIFY_CLI_FROM_BRANCH=1 bash scripts/verify-cli/attachments.sh   (the same, on a branch that contains origin/main)
# Runs one throwaway thread whose goal links a screenshot (`attachments/1.png` in the thread's folder, as the New goal sheet
# leaves it). The picture is a code word drawn as text; the goal asks for that word in a file, so the file only has the
# word if the turn opened the screenshot. The steps: the screenshot is copied read-only into the worktree's
# `.workbench/goal-copy/attachments/`, the first prompt names it, git does not see it, and the file has the word. Costs at
# most the turn cap ($VERIFY_CLI_BUDGET_USD, default 0.50). Exit 0 only when every step passed, 1 when one failed, 2 when
# it refused to start (nothing changed). VERIFY_CLI_SABOTAGE=1 leaves the screenshot out of the thread, so the copy, the
# prompt and the code word steps must FAIL. The frame and the other switches are in lib.sh. macOS (it draws the picture
# with AppKit). Run by hand, not by CI.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight

WORD="PELICAN-7731"
SHOT="$SCRATCH/shot.png"
WORD="$WORD" SHOT="$SHOT" swift - <<'SWIFT' || die "could not draw the screenshot (this scenario needs macOS and swift)"
import AppKit
let word = ProcessInfo.processInfo.environment["WORD"] ?? ""
let path = ProcessInfo.processInfo.environment["SHOT"] ?? ""
let size = NSSize(width: 640, height: 200)
let image = NSImage(size: size, flipped: false) { rect in
    NSColor.white.setFill()
    rect.fill()
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.black,
    ]
    let text = NSAttributedString(string: word, attributes: attributes)
    let box = text.size()
    text.draw(at: NSPoint(x: (rect.width - box.width) / 2, y: (rect.height - box.height) / 2))
    return true
}
guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
else { exit(1) }
try png.write(to: URL(fileURLWithPath: path))
SWIFT
[ -s "$SHOT" ] || die "no screenshot was drawn"

GOAL_SRC="$SCRATCH/goal.md"
cat >"$GOAL_SRC" <<'GOAL'
---
id: verify-cli-attachments
title: verify-cli attachments scenario
base: origin/main
budget_usd: 0.50
turn_timeout_min: 10
---

## Request

This is a throwaway thread that tests whether a screenshot reaches the coding turn. The screenshot shows a code word.
Create the file `verify-cli-attachment.txt` in the repository root whose only content is that code word, exactly as the
screenshot shows it. Change nothing else, do not commit, and do not run any test.

![screenshot 1](attachments/1.png)

## Criteria

- [c1] `verify-cli-attachment.txt` exists and contains the code word from the screenshot.
  - proof: a person reads the file

## Out of scope

- Any other file, and committing.
GOAL

start_thread verify-cli-attachments "$GOAL_SRC"
remove_on_pass branch "$BRANCH"
if [ "$SABOTAGE" = 1 ]; then
    echo "    VERIFY_CLI_SABOTAGE=1: the screenshot is not put in the thread"
else
    # What the New goal sheet leaves beside the goal; the goal text (and so its approval) is unchanged.
    mkdir -p "$THREAD_DIR/attachments" && cp "$SHOT" "$THREAD_DIR/attachments/1.png"
fi
run_thread

COPY="$WT/.workbench/goal-copy/attachments/1.png"
check "the screenshot is copied into the worktree" "no file at $COPY" cmp -s "$SHOT" "$COPY"
mode=$(stat -f %Lp "$COPY" 2>/dev/null)
check "the copy is read-only" "mode is '${mode:-none}'" test "${mode:-}" = 444
check "the first prompt names the screenshot" "turn-1.md does not name it" \
    grep -q ".workbench/goal-copy/attachments/1.png" "$THREAD_DIR/prompts/turn-1.md"
status=$(g -C "$WT" status --porcelain --untracked-files=all)
check "git does not see the screenshot" "status shows: $status" bash -c '! grep -q "\.workbench" <<<"$1"' _ "$status"
answer=$(cat "$WT/verify-cli-attachment.txt" 2>/dev/null)
echo "    the file says: ${answer:-<missing>}"
check "the turn opened the screenshot: the file has the code word" "the file says '${answer:-<missing>}', not $WORD" \
    bash -c 'grep -q "$2" <<<"$1"' _ "$answer" "$WORD"

wb "$T_WB" abandon "$ID" >/dev/null 2>&1
ended=$(wb "$T_WB" status "$ID" --json | py "print(d['ended'])")
check "abandon ends the thread" "status says ended: $ended" test "$ended" = abandoned
finish
