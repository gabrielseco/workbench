---
name: design-review
description: Review how a change to Workbench.app looks from a product designer's point of view — hierarchy, alignment and spacing, typography, the five colour meanings in light and dark, truncation at the 900×600 minimum window, empty/working/needs-you/broken states, and fit with native macOS conventions — checked against docs/DESIGN.md and Apple's HIG. Captures the app on fixture scenarios with verify-app and pairs the screenshots with a static pass over the SwiftUI diff. Use after verify-app for any change under Sources/WorkbenchApp that changes something visible, or when asked for a "design review", "does this look good" or a "polish pass".
allowed-tools: Bash(scripts/verify-app.sh:*), Bash(gh:*), Bash(git:*), Bash(grep:*), Read, Grep
---

# Design review

`verify-app` asks "does it do what the PR says?". This asks "does it look right?": would a designer who knows the Mac sign off on
it. The standard is `docs/DESIGN.md` (this app's rules, and the five colour meanings in `Theme.swift`), then Apple's Human Interface
Guidelines for macOS, and for a new screen the mockups in `docs/mac-app/`. A finding cites one of them, not taste.

Scale to the diff: a copy or colour tweak gets one or two captures; a new screen or a layout change gets the full matrix.

## Rubric

This section is what the `design` review stage hands its reviewer; the rest of the file is for a person running the skill by hand.
The reviewer is read-only: it builds and runs nothing and judges the diff, the goal and the screenshots it was given. Read
`docs/DESIGN.md` from the checkout first.

Static pass over the added lines in `Sources/WorkbenchApp/**` (each hit is a finding only if the context or a screenshot shows it
matters; say which file and line):

- `.font(.system(size:` outside the serif goal text, or `.font(.custom(` → a text style (DESIGN.md, Typography).
- `Color(red:`, `Color(#`, `NSColor(` literals in a view → a `Theme` colour (DESIGN.md, Colour).
- A colour used for a meaning it does not have: amber for an error, red for "needs you", green for "good" in general.
- Colour as the only signal: a state told apart only by its tint, with no symbol or word.
- `.padding(` and `spacing:` values outside DESIGN.md's set; two `.borderedProminent` buttons in one state.
- A `Text` in a row or header with no `lineLimit` or a fixed frame that clips it at 900 wide.
- An icon-only `Button` or `Image` with no `.help(`.
- A hand-made control (a shape with `onTapGesture` that acts as a button) where a system one exists.
- A cost, count or duration shown as a number when the core says it is unknown.

Then, for each screenshot, in this order:

1. **Hierarchy.** In one second, is it clear which step the thread is on and what to do? One primary action?
2. **Alignment and rhythm.** Leading edges line up across rows and sections; spacing is larger between groups than within.
3. **Typography.** The DESIGN.md styles, at most three sizes in a component.
4. **Colour and contrast.** Each colour means one thing; readable in the appearance shown.
5. **Fit at 900×600.** Truncates with an ellipsis; nothing important is pushed off screen or under the footer.
6. **States.** Empty says what to do next; working shows progress in place; unknown says `unknown`.
7. **Native feel.** Would it sit next to Mail or Xcode? Standard controls, consistent SF Symbols, sentence case.
8. **Consistency.** A new row, pill or card matches the existing ones.

Grade each finding **Blocking** (clipped or overlapping layout, unreadable text, a colour with the wrong meaning, the primary action
hard to find, something that does not fit at 900×600), **Polish** (misalignment, inconsistent spacing or style, weak hierarchy, a
missing `.help` or empty state) or **Nit** (subjective, say so, at most three). Each finding gives what is wrong, the screenshot or
`file:line`, and the rule it breaks (a DESIGN.md section or HIG). Say what works well in one line. A state or size with no screenshot
is "not reviewed", never "fine". End with `VERDICT: CLEAN` when there is nothing Blocking or Polish, else `VERDICT: FIX`.

## 1. Scope

Read `docs/DESIGN.md`, then the change (`gh pr view <n> --json title,body,files`, `gh pr diff <n>`; before a PR exists,
`git diff origin/main...`). List the screens it touches (Goal, Run, Review, Ship, PR review, the rail, a card) and the states each
can be in: the normal case plus whichever of empty, working, needs-you, broken, long text (a long request, path or criterion), many
rows, disabled. If the diff shows nothing, say so and stop.

## 2. Static pass

Do the Rubric's static pass first; it is certain, so it comes before the pixels.

## 3. Capture the matrix

Use `verify-app` for the mechanics (read `.agents/skills/verify-app/SKILL.md`: scenarios, `start`, `list`, `press`, `shot`, `stop`,
and always `stop`). Never call anything else that launches or kills. Name captures `<screen>-<state>-<size>.png`.

- **Scenarios.** Pick the ones that reach the states from step 1 (`scripts/verify-app.sh scenarios`); a state no scenario has is
  "not captured", reviewed from the code, and a new scenario if the change is worth one.
- **Two sizes.** The minimum and a roomy one: `VERIFY_WINDOW_SIZE=900x600 scripts/verify-app.sh start <scenario>` and again with
  `1600x1000`. `start` sets the size through Accessibility; if it says the window stayed at its launch size, say so in the report.
- **Appearance.** The app follows the system and `verify-app.sh` has no switch for it, so captures are in whatever the machine is
  set to. Say which in the report, and review the other from `Theme.swift`'s values and the static pass. Do not change System
  Settings for a review.
- **Before.** For a changed screen, the same shots from `origin/main` in a throwaway worktree (`git worktree add ../wb-main
  origin/main`, remove it after), named `before-…`.

`Read` every capture and look at it. A claim about colour or layout is checked by the picture, not by `list`.

## 4. Report

In the chat: the verdict (**looks good**, **polish needed**, **blocking issues**), the findings by grade, and the screenshot paths. On
a PR, post the screenshots with `pr-shots` as `verify-app` says; a review comment is the person's call, as for `pr-review`. Blocking
findings are fixed before the PR is ready, then run this again; polish is fixed unless told otherwise. If a finding shows that
DESIGN.md is wrong or silent about a pattern the change introduces on purpose, edit DESIGN.md in the same PR instead of flagging the code.
