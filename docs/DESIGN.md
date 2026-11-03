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

## Chat feed (preview)

The thread as one conversation ([P22](plan/P22-chat-feed.md)), behind View ▸ Chat feed (preview) and off by default: with it on, the
thread screen is `FeedScreen` instead of the per-step screens, with it off nothing here applies. It draws `snapshot.feed` (the core's
`Feed.items`), what the last action said, and a decision card whose buttons run the actions the step screens run (slice 3b); the
Run settings inspector comes in 3c. The
mockups are in [`design/chat-feed/`](design/chat-feed/); where this file and a mockup disagree on a layout value, this file is what
ships, and the mockup gets fixed.

- **Header.** The title (`.title2`, bold, two lines at most), then the **phase row**: the spine's seven steps in one line, each a mark
  (the same symbol and colour as the rail drew it) and its title (`.callout`, semibold from the current step on, `.secondary` while
  pending), with a chevron between. The toolbar above it keeps the project pill, the base, the spend and the state pill. The rail
  keeps the Thread/Tasks switch and Doctor and, between them, **the thread list**: a row per thread, newest first (at most 50, then "N older
  threads"), each a mark (a symbol and a tint: working blue, needs you amber, done green, waiting grey, broken red), the title (`.callout`, two
  lines at most, semibold when selected) and one `.caption` line of state in the toolbar pill's words. A click shows that thread, with its
  feed and settings, including a finished one; it starts and stops nothing. The spine is not drawn twice.
- **Feed.** One scrolling column, newest row at the foot. It is a lazy list that opens at the foot and stays there while it grows,
  so a thousand rows cost what the screen shows. Padding 28 across and 20 above and below, rows 10 apart, a symbol column 16 wide so
  the text beside the marks lines up. It never grows the window and truncates (middle for a path or command) rather than wraps off.
- **Rows.** A row says what happened in a line, with the thing it is about after it on the same line when that is a file or a command
  (`Edit  Sources/Client.swift`, `Refused Bash  git push origin main`) and under it when it is a sentence. Agent text is plain body
  text; a note sent back is a quiet bubble (`.quaternary`) on the right; the goal and the next step are cards (grey fill, or a grey
  outline for the next step); a turn is a semibold line with its time and cost; tool calls are grouped into one line.
- **Colour.** The five meanings, as everywhere: blue a turn that is working, green done or passed (a turn that ended, a check or verify
  that passed, an approved goal), amber needs you (a refused call, a judge that disagrees, a stale goal, a runner that is gone), red
  broken (a failed or timed-out turn, a failed check or verify, a damaged log), grey everything else. Every row also says it in a
  symbol and words, never by colour alone.
- **The decision card** is the last row: the step and why, from the spine and attention, and **one** prominent button for the next press
  (Approve and run, Run, Stop turn, Accept work, Ship, Review PR, Merge…, New goal…). The other actions of the step (Send back…,
  Discard…, Open diff, Open worktree, Open in Herdr, Refresh; Open worktree and Open in Herdr stay after Accept and Ship, as on the
  step screens) are in a borderless `…` menu beside it, Discard in red, each disabled for
  the same reason as on the step screen. The card decides nothing: `FeedActions.derive` reads `canShip`, `canMerge`, the goal's
  `canApprove` and `RunModel.stoppable`, and picks which one is next. Discard and Merge keep their confirmation, Send back its popover.
- **What an action said** (an error in red, a note in grey, a notice in green, a Herdr handoff) is a row above the card, in the words
  the step screens use, and goes when the next action starts. The pull request's CI summary sits there too while it is watched.
- **The goal card** says what Approve and run means. While the goal is a draft that no turn has run, and nothing is going on, the card
  **is the editor**: the request, each criterion (its text and the proof that will check it, a proof Workbench cannot check in amber with
  why) and the out-of-scope list are changed in place, as on the Goal screen (they are the same blocks, `GoalBlocks`), a refused edit
  said under them. Once the goal is approved, run or decided, or while an action is going, the card is its summary: the criteria with
  their proofs (six at most, then "and N more"), read-only.
- **Run settings** is a column (260 wide) beside the feed, shown by the header's "Run settings" button or View ▸ Run settings (⌥⌘R),
  hidden by default and remembered. It holds what this run is allowed to do: the steps after a turn as switches (Verifier, Judge, the
  project's review stages; a step that cannot run for the goal says why) and, under them, one switch for whether they run by
  themselves after a passing turn ("Run the judge and review stages by themselves", a line saying what a run will do, "Runs: judge,
  design" or "Off", and whether that is the goal's own setting or the project's; disabled, with the project's `[review] auto` named, when
  that list decides), the limits (model, budget, timeout: read-only, "Change these
  in the goal file"), the allowed tools (ten, then "and N more", granted ones marked), the reference folders (the config's, and the
  goal's, added and removed here) and Open (editor, Herdr, Run in Herdr instead). Everything is read-only unless the goal is a draft that no turn has run, and
  while an approval, a run or another action is going; it says why when the reason lasts ("A goal that has run is not edited."). In a window whose centre column is narrower than 880 (a window under about 1100 wide, the 900 minimum included) it opens
  over the feed as a sheet, so the feed keeps its width. It writes the goal's edits and runs the actions the Goal screen does.
- **Notices** (activity folded, a damaged log, a cut last line, a changed goal, earlier rows not shown) say what the feed left out and
  send the person to the event log; a damaged log is red and first.
- **A chat** (a thread with no goal yet) has no phase row, no decision card and no Run settings content: its screen is the conversation and a
  composer. The person's messages are `.quaternary` bubbles on the right, the agent's are plain body text under a quiet `Goal agent`
  label, and both wrap and are selectable. While a turn runs the last row is `Replying…` in blue with a spinner and a borderless Stop,
  the text box is dimmed, takes no typing and says `Waiting for the agent…`. The composer is a text box (one line high, up to six),
  `Make this a goal` (`.bordered`, enabled once the agent has answered and nothing is going) and `Send` (the one `.borderedProminent`).
  Return sends and Shift- or Option-Return adds a line. What the app says back about a message or a draft (too long, no goal agent,
  a draft that did not come out) is an amber row above the box: the person has to change something before it can go on, it is not a
  broken thread. The New goal card's Chat kind says the same in amber.

## Tasks screen

The rail's `Thread | Tasks` switch (a native segmented control) changes the centre between the thread screens and the project's
scheduled tasks; it changes nothing in the thread. The Tasks screen is a left column (the "Will it run tonight?" card, then the
task list) and the selected task's run timeline on the right. It is read only: it shows what `TaskLibrary`, `TaskRunLog` and
`TimerService.status()` say and writes nothing.

- **Marks** reuse the five meanings. A run's outcome: `pr-opened` and `reported` green, a run going blue, `nothing-pending`,
  `nothing-to-do` and the `skipped-*` outcomes grey, `stale-approval` amber (it waits for your approval), `failed`,
  `budget-exceeded` and `interrupted` red. Each pairs its colour with a symbol and the outcome's own word. A timer line is green
  (`ok`), amber (`warn`) or red (`FAIL`).
- **States:** no tasks says where they are made (`workbench task new`); a task that does not load is a red PROBLEM row with the
  core's message; a task never run says so; a timer that cannot be read says `unknown`, never green.
- **Two buttons write, and only through core.** The selected task's header has one primary action for its state: `Approve…` while it
  is not approved or stale, `Run now` once it is, and `Stop` (bordered) while a run started here goes. `Approve…` opens a card
  (`OverlayCard`: Esc and Cancel close it, ⌘Return confirms) that shows what would run unattended (the settings, the instructions,
  the script and skill with their sizes); a refusal stays in the card in the core's words. `Run now` asks first on a card that names the most it may cost and what it does (a `fix: pr` run opens a pull request, a `fix: report` run asks a read-only agent and keeps a report), because either starts an agent that spends. A run started here
  shows its last line in the busy bar, and how it ended in a result line under the header: green for `pr-opened` and `reported`, grey
  for a skip, amber for `stale-approval`, red only for `failed`, `budget-exceeded` and `interrupted`. A disabled `Run now` says why in
  its `.help`.
- A run's thread opens in Thread view only when it is the thread on screen (the window has one thread per project); any other is
  a selectable id.

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

## Status item

A `MenuBarExtra` (the wrench and screwdriver) is always in the menu bar while the app runs, so closing the window does not end a run
or the watching. It shows a count only while something needs you (a thread to review, a task that broke or went stale) and says it to
VoiceOver (`Workbench, 2 things need you`); the system draws the item as a template, so the count and the label carry the meaning and
the colour (amber, red when something broke) is a bonus. Its popover (320 wide, the window style) follows mockup 5: the project in
capitals and one pill (`Needs you` amber, `Broken` red, `Working` blue, `Quiet` grey), a card per item (amber or red mark, title,
the one-line reason, and for a thread in review the criteria row), then `Event log`, `Quit` and `Pause notifications`. A card's first
`Open review` or `Open task` is the one prominent button; `Send back…` opens the window with the card that decides it. The popover
decides nothing and writes nothing. Quiet says `Nothing needs you` with the project's own one-line state; a log that cannot be read
is red with the core's words; many items scroll in the popover. When the system will not let the app notify, the popover says so once.

## Quitting

Quitting with work of the app's still going (a thread's run, a task started from the window, a goal draft) asks first, in a system alert
that says what would end and that it ends as `stopped` and can be run again: `Stop and quit` or `Cancel` (which keeps the app open).
Nothing going means no alert. After `Stop and quit` the app waits up to 6 seconds for the turn to end, then quits whether it has or not
(a turn left open is recorded as `interrupted` by the next start).

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
