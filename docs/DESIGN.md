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
- **With the chat feed preview on, the palette is the artboards'** (`Theme.preview`, set by the store; the old window keeps its values
  until P22 slice 7). Dark / light: blue `#5b9dff` / `#1f5fd1`, green `#4cc38a` / `#1b7f4e`, amber `#f0b04a` / `#a35f00`, red `#f2685f` /
  `#c8322a`, grey `#7e8695` / `#667084`; the rail `#1b1e24` / `#eceef2` and the thread screens' content `#16191e` / `#f4f5f8`
  (`Theme.canvas`; without the preview the window draws its own); the preview's surfaces `raised` `#2a2f39` / `#e1e5ec`, `panel` `#21252d` / `#ffffff` and `line` `#323844` / `#d3d8e0`. The values are in `ThemeTests`, which is what fails if they drift.

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

- **Header.** The title (`.title3`, semibold, 15 pt, two lines at most), then the **phase row**: the spine's seven steps in one line, each an 8 pt dot with a 1.5 pt ring (the colour the rail
  draws the step in: filled when done or current, hollow while pending) and its title (`.callout`: `Theme.fg2` when done, primary when current,
  `Theme.fg3` while pending, the artboards' two text greys, so a step still to come stays readable in light), 14 apart and no chevrons. A thread that began as a chat has a **Chat** step first (current while it is a
  chat, done once it has a goal); a thread that began as a goal has none. A chat shows the row too, with Chat the only step reached. The toolbar above it keeps the project pill, the base, the spend and the state pill, which says only the head of the state (`Needs you`; the reason is in the thread's row and the decision card). The footer carries `Event log N`, then Doctor and its result, and at the right the thread's per-turn limit. The rail
  has no Thread/Tasks switch and no Doctor: it is one list, 288 wide, **Threads** with a `+` (the New goal card, until the
  new-thread screen) and then **Scheduled · N** with the project's tasks. A thread row is newest first (at most 50, then "N older
  threads"); a task row follows. Each row has a mark at the left (working a spinner, needs you an amber dot with a halo, done a check,
  idle a hollow ring, broken a cross), the title on one line (`.callout`, semibold) and a `.caption` state line coloured by the same mark
  (blue running, amber needs you, green done, red broken, `.secondary` for idle); the selected row sits on `Theme.raised`. A click shows
  that thread, with its feed and settings, or that task's page; it starts
  and stops nothing. A task's line is its schedule, then what keeps it from running (`needs a fix`, `approval stale`, `not approved`) or
  how its last run ended. The spine is not drawn twice.
- **The new-thread screen** is what the rail's `+` and ⌘N open with the preview on (the popover is the old window's): in the feed's 680 column
  under a `New thread` title and a phase row with Chat current, `What do you want to work on?` (`.title2`, semibold) and the line that says
  nothing runs and nothing costs until you say so, a composer panel (`Theme.panel`, a hairline, radius 12) with the text box, the staged
  screenshots as small thumbnails with a remove button, a `+` to choose screenshots and `Paste or drop screenshots.`, and two buttons,
  `Draft the goal` (⌘↵) and `Discuss first` (↵, the one prominent button). Under it one caption saying what each does and a small `Use my text as the goal`
  (a quick goal, no agent). There are no starter chips: `+`, paste and drop already add screenshots, and typing already starts a chat. Discuss first needs text and no
  screenshots (a chat takes none); a refusal is an amber row above the panel with the text kept; a project with no goal agent offers `Draft
  with Claude` / `Draft with Codex`. While it is open the rail's first row is `New thread · Type to start · free`, selected; the toolbar says
  `$0.00` and `No run`; the footer has no Event log.
- **A task's page** is in the feed's 680 column: the name (`.title3`, semibold), one line `schedule · opens a PR · N runs · next …`, and
  `Defined in .workbench/tasks/<name>/task.md. Edit that file to change it.` in a monospaced caption, with the task's buttons at the
  right (Approve… while it is not approved, Run now once it is, Stop while a run started here goes). Under it the task's own
  **Will it run tonight?** card: a verdict (`Will run`, `Will run, check the warnings`, `Will not run`) and its warnings, problems first,
  from the task (a file that does not load, an approval missing or stale, a last run that waited for review), the project (another
  thread is still active, so the next run would skip) and the machine (the timer's own lines that warn or fail), each with the one
  button that deals with it (`Approve…` / `Re-approve`, `Open thread`); open when it has warnings, one line when it has none. Then the
  runs, newest first, under a quiet `TODAY` / `YESTERDAY` / `WED, OCT 28` heading: a mark, the outcome in bold (coloured when it failed or
  needs you), the time, the trigger, a line of what happened, and at the right one button: `View log` for a run that ended badly
  (reveals the run log in Finder), `Re-approve` for a stale approval, `Open thread` when it has a thread the rail lists.
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
- **A draft goal's card** (the editable one) is the artboard's *Draft goal*: `DRAFT GOAL` (caption), a pill (`Needs approval` amber, `Can't approve
  yet` red, `Approved` green) and `Every field is editable` at the right; then `REQUEST` (the text in a bordered box, in the body face), `CRITERIA ·
  N` (each a bordered row with a ring, its proof as the quiet second line) and `OUT OF SCOPE`; and one footer: what Approve starts (`Starts a
  worktree from main with Verifier and Judge on.`) at the left, the `…` menu and `Approve and run` at the right, so the *Next* card is not drawn
  for it. The button stays `Approve and run`, not the artboard's `Approve goal`: it runs the goal straight after approving it. A goal made from a
  chat has, above the card, a collapsed `Brainstorm · N messages` row that opens in place to the conversation and the agent's line `I drafted a
  goal from this chat. Edit anything below, then approve. Nothing runs until you do.`; there is no `Back to chat` (a chat that became a goal takes
  no more messages). The Run settings panel is open by default beside the feed until a person closes it (a narrow window shows it over the feed
  only once they have chosen).
- **A running turn** is one card (the artboard's *Run*): `Claude is working` with `3:41 of 30:00` (the turn's time against its limit, ticking
  each second) over a thin bar, `TASKS · 3 OF 5` when the agent kept a task list (done ticked, the working one bold with a spinner, the rest
  a grey ring), the last three tool calls as a mono tail, and `Stop` (the decision's stop action; the *Next* card is not drawn while the card
  is). Under it, `Judge` and `Verify` as grey rings with what they will do, each only when it is on for the goal. A refused call and the
  agent's words stay rows of their own. A finished turn is `Run finished · 5 tasks · 3 files · +7 −1 · $1.88` with `View diff`;
  `Verify passed` is a card with up to three screenshot thumbnails and their names; when the next press is Ship the foot is `Ready to ship`
  (the branch and base, then `Request changes` where a send-back is allowed, and `Ship`). Not in the artboard and not built: the steer
  input, the verify card's command chips.
- **Buttons and switches** (preview on): the screen's main action is `.primaryButton()`, the artboards' inverse pill (`inv` fill, `invfg`
  label, radius 7, 34 high; 40 % when disabled), and every other plain button is `.plainButton()` (raised fill, hairline border, radius 7,
  30 high). Neutral on purpose: the system accent follows the person's macOS setting and the five state colours already mean something, so a
  setting that is on takes none of them. Native switches are tinted `inv` (`.switchTint()`); macOS softens a near-white or near-black tint to a
  mid grey, so an on switch reads as a grey track with the knob at the right, not the artboard's crisp pill. With the preview off the
  modifiers return the system styles, and `scripts/check-banned-apis.sh` refuses a bare `.borderedProminent`.
- **Run settings** is a column (300 wide) beside the feed, shown by the header's "Run settings" button or View ▸ Run settings (⌥⌘R),
  open by default until a person closes it, and remembered. It holds what this run is allowed to do: the steps after a turn as switches (Verifier, Judge, the
  project's review stages; a step that cannot run for the goal says why) and, under them, one switch for whether they run by
  themselves after a passing turn ("Run the judge and review stages by themselves", a line saying what a run will do, "Runs: judge,
  design" or "Off", and whether that is the goal's own setting or the project's; disabled, with the project's `[review] auto` named, when
  that list decides), the limits (model, budget, timeout: read-only, "Change these
  in the goal file"), the allowed tools (chips: ten, then `+N more`, granted ones marked), the reference folders (the config's, and the
  goal's, added and removed here) and Open (editor, Herdr, Run in Herdr instead). Everything is read-only unless the goal is a draft that no turn has run, and
  while an approval, a run or another action is going; it says why when the reason lasts ("A goal that has run is not edited."). In a window whose centre column is narrower than 900 (a window under about 1100 wide, the 900 minimum included) it opens
  over the feed as a sheet, so the feed keeps its width. It writes the goal's edits and runs the actions the Goal screen does.
- **Notices** (activity folded, a damaged log, a cut last line, a changed goal, earlier rows not shown) say what the feed left out and
  send the person to the event log; a damaged log is red and first.
- **The feed is a centred column**, at most 680 wide (`FeedLayout.maxColumn`): the rows, what an action said, the decision card and a
  chat's composer. The title and phase row above it and the Run settings inspector beside it keep their places; at the 900×600 minimum
  the column simply fills what there is.
- **A chat** (a thread with no goal yet) has the phase row (Chat the only step reached) but no decision card and no Run settings content: its screen is the conversation and a
  composer. The person's messages are bubbles on the right in `Theme.raised` (radius 14, the bottom-right corner 4, at most 540 wide) with
  no label; the agent's are plain body text at most 620 wide beside a 22 pt avatar (`sparkle`, a `Theme.raised` disc with a `Theme.line`
  ring). Both wrap and are selectable, and say who spoke to VoiceOver (`You`, `Goal agent`), since nothing on screen does. While a turn
  runs the last row is `Replying…` in blue with a spinner and a borderless Stop, and the text box is dimmed, takes no typing and says
  `Waiting for the agent…`. The composer is a rounded panel (`Theme.panel`, a `Theme.line` hairline, radius 12, 46 high at least) holding
  the text box (one line, growing to six) and a 30 pt square `arrow.up` Send button; under it a grey ring and `Chat only. No worktree,
  no run, no cost.` at the left and the one `.borderedProminent` button, `Make this a goal →`, at the right (enabled once the agent has
  answered and nothing is going). Return sends and Shift- or Option-Return adds a line. What the app says back about a message or a
  draft (too long, no goal agent, a draft that did not come out) is an amber row above the panel: the person has to change something
  before it can go on, it is not a broken thread. The New goal card's Chat kind says the same in amber.

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
- A multi-line text box is `PlaceholderTextEditor` (the placeholder sits where the text view starts its text, measured by
  `scripts/check-text-alignment.py`; a box that grows with its text hides its scroll bar). Never a bare `TextEditor`: CI refuses it.

## What this file does not cover

Behaviour: that is the verifier and the tests. This is only how it looks. Where it is silent, follow the Human Interface
Guidelines for macOS, and if a change introduces a pattern on purpose, add it here in the same PR.
