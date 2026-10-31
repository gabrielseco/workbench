# Design

What the Workbench app should look like, written down so a change can be checked against it (the `design-review` skill and
the `design` review stage). It describes `Sources/WorkbenchApp` as it is; when a change deliberately changes a rule, change this
file in the same PR. The screens come from the mockups in [`mac-app/`](mac-app/) (Goal, Run, Review, Ship + PR review, Menu bar);
the colour meanings are from [P19](plan/P19-swiftui-app.md) and live in `Theme.swift`.

## Principles

1. **A native Mac app, not a web page.** System controls, system button styles, SF Symbols, standard text styles. No hand-made
   control where a system one exists.
2. **The answer first.** The app exists to say where the thread is and whether it needs you. The step you are on and the one
   action that moves it on are the first things the eye lands on.
3. **Quiet by default, colour for meaning.** Almost everything is `.primary` or `.secondary`. Colour never decorates.
4. **Dense, not cramped.** It is read many times a day: compact rows, but text has room and nothing collides at the minimum size.

## Colour

Five colours, all from `Theme` (never `Color(red:…)` or a literal in a view), each with a light and a dark value:

| Colour | Means | Never |
|---|---|---|
| blue | working, or your current step | decoration |
| green | done | "good" in general |
| grey | not yet | disabled text (use `.secondary`) |
| amber | the thread cannot go on until you decide | an error |
| red | something broken | "needs you" |

- The same meaning always gets the same colour, and colour is never the only signal: a step mark pairs its colour with its
  `SpineMark.symbol`, a status with a word.
- Both appearances are supported. A tinted label has to be readable on the rail in light and in dark (the amber and green
  text is the one that fails first).
- Neutral surfaces use the system fills (`.quaternary`, the rail's own `Theme.rail`), not a new grey.

## Layout

- One window with the thread spine on the left (a rail, about 220 wide) and the current screen beside it. The window's minimum
  is **900×600** (`RootView`); everything must still fit there, truncating with an ellipsis rather than clipping or overlapping.
- Screen content is padded 20 (a card or sheet 28), sections are stacked with spacing 10 to 14, a group inside a section 4 to 8.
- Spacing values come from **2, 3, 4, 6, 8, 10, 12, 14, 20, 28**. A new value needs a reason.
- Leading edges line up: marks in a column share a fixed width so the text beside them aligns.
- One primary action per screen state (`.borderedProminent`); the others are `.bordered`, `.borderless` or `.link`. A second
  prominent button in the same state is a finding.

## Typography

Text styles, so it scales with the system. A fixed point size is allowed only for the serif goal text (`.system(size: 16–17,
design: .serif)`) that the Goal mockup sets apart.

| Role | Style |
|---|---|
| Screen title | `.title2.weight(.semibold)` (`.title.weight(.bold)` for the empty-project state only) |
| Section title | `.headline` |
| Body, rows | `.callout` |
| Commands, paths, ids, log lines | `.system(.callout, design: .monospaced)` (`.caption` monospaced in a dense row) |
| Metadata, hints, errors | `.caption`, `.secondary` unless it is an error |
| Counts and costs | `.monospacedDigit()` |

At most three sizes in one component; hierarchy comes from weight and `.secondary` before size.

## States

Every screen answers four questions without a click, and a change that touches a screen shows each of the ones it can reach:

- **Empty:** says what to do next ("no thread yet" offers a New goal), not only that nothing is there.
- **Working:** progress is shown in place (the blue current mark, the open turn's activity), not as a spinner over everything.
- **Needs you:** amber, with the one thing to decide and the button that decides it.
- **Broken or unknown:** red or plain text with the reason and the core's own wording. An unknown value says `unknown`
  (a cost with no price is never `$0.00`; files changed that cannot be counted say so), never a number made up.

## Controls

- Buttons are sentence case; an icon-only button has `.help(…)`; a destructive one says what it destroys.
- Anything that opens another app or a file panel says so in its label or its `.help`.
- Text a person may want to copy (a command, a path, a PR number) is selectable.
- A sheet or card (`OverlayCard`) has one way out (Esc and a Cancel) and does not move the screen under it.
- Keyboard shortcuts where the siblings have them: a card cancels with Esc and confirms with ⌘Return.

## What this file does not cover

Behaviour: that is the verifier and the tests. This is only how it looks. Where it is silent, follow the Human Interface
Guidelines for macOS, and if a change introduces a pattern on purpose, add it here in the same PR.
