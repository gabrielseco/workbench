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
- **The palette is the artboards'.** Dark / light: blue `#5b9dff` / `#1f5fd1`, green `#4cc38a` / `#1b7f4e`, amber `#f0b04a` / `#a35f00`, red `#f2685f` /
  `#c8322a`, grey `#7e8695` / `#667084`; the rail `#1b1e24` / `#eceef2` and the thread screens' content `#16191e` / `#f4f5f8`
  (`Theme.canvas`); the surfaces `raised` `#2a2f39` / `#e1e5ec`, `panel` `#21252d` / `#ffffff` and `line` `#323844` / `#d3d8e0`. The values are in `ThemeTests`, which is what fails if they drift.

## Layout

- One window with the thread spine on the left (a rail, about 220 wide) and the current screen beside it. The window's minimum
  is **900×600** (`RootView`); everything must still fit there, truncating with an ellipsis rather than clipping or overlapping.
- Screen content is padded 20 (a card or sheet 28), sections are stacked with spacing 10 to 14, a group inside a section 4 to 8.
- Spacing values come from **2, 3, 4, 6, 8, 10, 12, 14, 20, 28**. A new value needs a reason.
- Leading edges line up: marks in a column share a fixed width so the text beside them aligns.
- One primary action per screen state (`.borderedProminent`); the others are `.bordered`, `.borderless` or `.link`. A second
  prominent button in the same state is a finding.

## Chat feed

The thread as one conversation ([P22](plan/P22-chat-feed.md)): the thread screen is `FeedScreen`. It draws `snapshot.feed` (the core's
`Feed.items`), what the last action said, and a decision card whose buttons run the thread actions (`GoalActions`, slice 3b); the
Run settings inspector comes in 3c. The
mockups are in [`design/chat-feed/`](design/chat-feed/); where this file and a mockup disagree on a layout value, this file is what
ships, and the mockup gets fixed.

- **Header.** The title (`.title3`, semibold, 15 pt, two lines at most), then the **phase row**: the spine's seven steps in one line, each an 8 pt dot with a 1.5 pt ring (the colour the rail
  draws the step in: filled when done or current, hollow while pending) and its title (`.callout`: `Theme.fg2` when done, primary when current,
  `Theme.fg3` while pending, the artboards' two text greys, so a step still to come stays readable in light), 14 apart and no chevrons. A thread that began as a chat has a **Chat** step first (current while it is a
  chat, done once it has a goal); a thread that began as a goal has none. A chat shows the row too, with Chat the only step reached. The toolbar above it keeps the project pill, the agents pill (hugs its label, right after the project pill at the same gap; a long model name is cut with an ellipsis at 220 pt, the full text in its help), the **Inbox / Automations switch** (two choices in a bordered capsule after the project's name and its `base:`, the chosen one raised, each with its count in a filled pill beside the word: `Inbox` the number that needs you, amber, `Automations` the number that failed, red, none when none; the count is also said in words to VoiceOver), then the base, the spend and the state pill, which says only the head of the state (`Needs you`; the reason is in the thread's row and the decision card). The footer carries `Event log N`, then Doctor and its result, and at the right the thread's per-turn limit. The rail
  has no Doctor: it is one list, 288 wide, the project's **inbox** (`INBOX · PROJECT`, with the project's Agents button and a `+` that opens the New goal card, until the
  new-thread screen); the tasks are not listed in it, the Automations view lists them. The inbox has three sections in this order, each with its caps label and count: **Needs you** (amber: a thread
  that asks for something or is broken, then the tasks that need approval, tagged `auto`), **Waiting** (blue label; everything not over: a turn going, a draft, accepted and not shipped, a pull request
  still open) and **Done** (what is over: thrown away, abandoned, cleaned, its pull request merged or closed), which is one grey line with a chevron, `Show N finished threads`, until it is opened (per project,
  for the session), then `Hide finished threads`; the thread on screen is listed in its section whichever it is (the loader still stops at 50, then "N older threads"). Each row is **two
  lines** with the spend at the right (`$0.50`, `unknown` when the core cannot tell, none before a first turn): a mark at the left (working a spinner, needs you an amber dot with
  a halo, done a check, idle a hollow ring, broken a cross), the title (`.callout`, semibold, cut in the middle) and under it the words of its state in grey (the mark and the section's colour say how urgent it is) (a thread's `Accepted`, a
  task's `not approved`, `approval stale`); the selected row sits on
  `Theme.raised`. A click shows that thread, with its feed and settings, or that task's page; it starts and stops nothing. The spine is not drawn twice.
  A thread a task started (its run log names it) is not in the rail once it is over (done or idle): it is one click from the task's page (each run's
  `Open thread`), and listed while it is on screen so the selection can be seen; one that is working, needs you or is broken stays in Threads.
  A project's tile on the rail is its **picture** with its name under it, never two letters: an outline (circle, square, diamond or hexagon), solid or a ring, with a mirrored 3 × 3 mark, chosen by a fixed hash (FNV-1a) of the project's path so it never changes between launches (`ProjectGlyph`). One ink, grey, blue when the tile is the open one: colour is a state, so a project never owns one. The name is one line of caption under the tile, cut at the end with an ellipsis (52 pt wide); a click on it is a click on the tile; the tooltip has the name and path. At 900 × 600 the inbox tile, five projects and `+` fit without scrolling.
  The top tile of the project rail (a tray, with the needs-you count of every project) is the **inbox of all projects**: chosen, it is the selected tile and the rail's
  list is `INBOX · ALL PROJECTS`, the same three sections with every project's rows in the rail's order, each row with its project's initials in a neutral outlined pill (blue is a state, never a
  label); Done is one count and link for all of them; a click opens that project, shows the thread (or the automation's task) and goes back to that project's own inbox; a project tile does too.
  `New task…` is a button at the right of the top bar while Automations is chosen (File ▸ New Task…, ⇧⌘N; the rail's one `+` starts a goal, as ⌘N does).
- **The new-thread screen** is what the rail's `+` and ⌘N open: in the feed's 680 column
  under a `New thread` title and a phase row with Chat current, `What do you want to work on?` (`.title2`, semibold) and the line that says
  nothing runs and nothing costs until you say so, a composer panel (`Theme.panel`, a hairline, radius 12) with the text box, the staged
  screenshots as small thumbnails with a remove button, a `+` to choose screenshots and `Paste or drop screenshots.`, and two buttons,
  `Draft the goal` (⌘↵) and `Discuss first` (↵, the one prominent button). Under it a three-line legend in the buttons' order, name then what it does: `Discuss first`, `Draft the goal`, and `Use my text as the goal` (a link: a quick
  goal from the words, no agent, no criteria, free). There are no starter chips: `+`, paste and drop already add screenshots, and typing already starts a chat. Discuss first needs text, and takes the staged screenshots with it
  (a chat keeps them for every later turn); a refusal is an amber row above the panel with the text kept; a project with no goal agent offers `Draft
  with Claude` / `Draft with Codex`. While it is open the rail's first row is `New thread · Type to start · free`, selected; the toolbar says
  `$0.00` and `No run`; the footer has no Event log.
- **A task's page** is in the feed's 680 column: the name (`.title3`, semibold), one line `schedule · opens a PR · N runs · next …`, and
  `Defined in .workbench/tasks/<name>/task.md. Edit that file, or use Edit with AI.` in a monospaced caption, with the task's buttons at
  the right (Approve while it is not approved, Run now once it is, Stop while a run started here goes). Under it the task's own
  **Will it run tonight?** card: a verdict (`Will run`, `Will run, check the warnings`, `Will not run`) and its warnings, problems first,
  from the task (a file that does not load, an approval missing or stale, a last run that waited for review), the project (another
  thread is still active, so the next run would skip) and the machine (the timer's own lines that warn or fail), each with the one
  button that deals with it (`Approve` / `Re-approve`, `Open thread`); open when it has warnings, one line when it has none. Then the
  **New task** is the `New task…` button at the right of the top bar while Automations is chosen (the rail has one `+`, which starts a goal; also File ▸ New Task… ⇧⌘N, and a button on the empty Automations page) that opens a screen in the main area: `New task`
  with `Cancel`, a `NAME` field (focused; a red line says what is wrong with a name as it is typed), a `WHAT IT SHOULD DO` box, `Propose` and
  `Create empty task` (same size), and a note saying what Propose costs or that it needs a goal agent. Working shows a busy line with `Stop`; a
  proposal shows the same settings-and-diff view as Edit with AI with `Accept` and `Discard`; Accept opens the new task's page.
  **Fix this with AI** (in an ended run's opened Details) opens that card with the run's facts in its box and scrolls to it. The
  **Edit with AI** card, closed until the task's `Edit with AI` button (beside `Run now`) opens it, with the text box focused, and kept
  open while an edit is working or waiting for a decision (a text box, `Propose`, and a note that it costs up to the goal draft's budget, is read-only until accepted and
  that accepting does not approve): working, it says so with a `Stop`; a proposal shows the settings approval binds to as `key old → new`
  (the first thing to read), the instructions as a `+` / `-` diff, `Accept` and `Discard`; a failure is a red line and `Try again`. Then the
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
  (Approve and run, Run, Stop turn, Accept and ship, Ship, Review PR, Merge…, New goal…). While a thread is in review a **guidance field** sits under the card (kept per thread): with text in it the
  primary reads `Send to agent` and Accept and ship stays beside it. `Accept and ship` commits, then pushes and opens the pull request, and stops at the first step that fails (a thread that was accepted but not shipped then shows `Ship`). Plain `Accept work`, the commit without the push, is in the menu with Discard…. The other actions of the step (Open diff, Open worktree, Open in Herdr, Refresh; Open worktree and Open in Herdr stay after Accept and Ship, as on the
  the old step screens' own) are in a borderless `…` menu beside it, Discard in red, each disabled for
  the same reason as on the step screen. The card decides nothing: `FeedActions.derive` reads `canShip`, `canMerge`, the goal's
  `canApprove` and `RunModel.stoppable`, and picks which one is next. Discard and Merge keep their confirmation; guidance is the field under the card.
- **What an action said** (an error in red, a note in grey, a notice in green, a Herdr handoff) is a row above the card, in the words
  the actions use, and goes when the next action starts. The pull request's CI summary sits there too while it is watched.
- **The goal card** says what Approve and run means. While the goal is a draft that no turn has run, and nothing is going on, the card
  **is the editor**: the request, each criterion (its text and the proof that will check it, a proof Workbench cannot check in amber with
  why) and the out-of-scope list are changed in place, (`GoalBlocks`, also the Run settings' goal edits), a refused edit
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
  a grey ring), the last three tool calls as a mono tail, and `Open worktree` beside `Stop` (the decision's stop action and its secondary one: the folder in the editor, since the files are still changing; `Open diff` is Review's;
  the *Next* card is not drawn while the card is). Under it, `Judge` and `Verify` as grey rings with what they will do, each only when it is on for the goal. A refused call and the
  agent's words stay rows of their own. A finished turn is `Run finished · 5 tasks · 3 files · +7 −1 · $1.88` with `View diff`;
  `Verify passed` is a card with up to three screenshot thumbnails and their names; when the next press is Ship the foot is `Ready to ship`
  (the branch and base, then `Ship`; there is no send-back after Accept). Not in the artboard and not built: the steer
  input, the verify card's command chips.
- **Buttons and switches:** the screen's main action is `.primaryButton()`, the artboards' inverse pill (`inv` fill, `invfg`
  label, radius 7, 34 high; 40 % when disabled), and every other plain button is `.plainButton()` (raised fill, hairline border, radius 7,
  30 high). Neutral on purpose: the system accent follows the person's macOS setting and the five state colours already mean something, so a
  setting that is on takes none of them. Native switches are tinted `inv` (`.switchTint()`); macOS softens a near-white or near-black tint to a
  mid grey, so an on switch reads as a grey track with the knob at the right, not the artboard's crisp pill. `scripts/check-banned-apis.sh` refuses a bare `.borderedProminent`.
- **Run settings** is a column (300 wide) beside the feed, shown by the header's "Run settings" button or View ▸ Run settings (⌥⌘R),
  open by default until a person closes it, and remembered. It holds what this run is allowed to do: the steps after a turn as switches (Verifier, Judge, the
  project's review stages; a step that cannot run for the goal says why) and, under them, one switch for whether they run by
  themselves after a passing turn ("Run the judge and review stages by themselves", a line saying what a run will do, "Runs: judge,
  design" or "Off", and whether that is the goal's own setting or the project's; disabled, with the project's `[review] auto` named, when
  that list decides), the limits (model, budget, timeout: read-only, "Change these
  in the goal file"), the allowed tools (chips: ten, then `+N more`, granted ones marked), the reference folders (the config's, and the
  goal's, added and removed here) and Open (editor, Herdr, Run in Herdr instead). Everything is read-only unless the goal is a draft that no turn has run, and
  while an approval, a run or another action is going; it says why when the reason lasts ("A goal that has run is not edited."). In a window whose centre column is narrower than 900 (a window under about 1100 wide, the 900 minimum included) it opens
  over the feed as a sheet, so the feed keeps its width. It writes the goal's edits and runs the same goal actions.
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
  a `+` that adds screenshots (paste and drop work too; staged ones show as thumbnails above the text box, as on the new-thread screen), the text box (one line, growing to six) and a 30 pt square `arrow.up` Send button; a message that sent screenshots shows `N screenshots` under its words; under it a grey ring and `Chat only. No worktree,
  no run, no cost.` at the left and the one `.borderedProminent` button, `Make this a goal →`, at the right (enabled once the agent has
  answered and nothing is going). Return sends and Shift- or Option-Return adds a line. What the app says back about a message or a
  draft (too long, no goal agent, a draft that did not come out) is an amber row above the panel: the person has to change something
  before it can go on, it is not a broken thread. The New goal card's Chat kind says the same in amber.

## Agents card

The project's agent roles, and where they are changed ([P25](plan/P25-project-agents.md)). A `popover` card, 560 wide, centred over a light veil, opened by the
agents pill beside the project pill in the top bar (a `.control` pill: a `cpu` mark and the run role's `Codex · model`, or `Agents` when the config is unread)
or by Agents… in the app menu (⌘,). Header: `AGENTS` (`SectionLabel`) and a close button. One row per role in
the order goal, plan, run, judge, review, ship, verifier. An editable row has the role in `.calloutStrong` with what it does under it (`.caption`); at the
right a provider picker (`Claude`, `Codex`, and `Off` for goal) and an effort picker (`Default effort`, low … max); under them a model menu
(`Default model`, the role's provider's names from `ModelCatalog`, the project's `[providers.<id>] models` and the models its roles use, then `Other…`, which shows a single-line
field that commits with Return or when it loses focus; blank is the provider's default) and, at its right, where the setting came from
(`provider default`, `set in the config · effort high`, `no [agents.goal]: chat and drafting are off`). A model name that looks like the other provider's
(`opus` on Codex, `gpt-…` on Claude) adds a `.warning` line under the row with a `Use default model` button. The verifier row only reads (its model is
`[verifier] model`, not an agent key). Every change is one `ConfigEdit` call, the code `workbench config set` runs: a refusal shows under the rows in
`.error`, a change to the run agent while a coding thread is active shows the `goal approve` note in `.warning`. With no `.workbench/config.toml` the rows
are not drawn and the card says to run `workbench init`. A chat's footer and the new-thread screen name the goal agent in `.caption`.

## Setting up a new project

A folder that is a git repository with no `.workbench/` opens on the setup screen (`ProjectSetupScreen`), not an empty state: `Set up Workbench in
<folder>`, what setup writes (`.workbench/config.toml`, `.workbench/` in `.git/info/exclude`) and that the folder's files stay as they are, then a
`GOAL AGENT` `SegmentedSwitch` (Claude, Codex, None; Claude picked) with a `.caption` on what that agent does, and `Set up Workbench` (primary) beside
`Not now`. Nothing is written before the press. Setup is `ProjectSetup.initialize`: it never overwrites a config or an agent the config names, and a
failure removes what it wrote; the screen then shows `Setup failed: <reason>` in `.error` and the button reads `Try again`. After setup with a goal agent
the window opens on New goal with a `.success` line saying who discusses and drafts. `Not now` shows the empty state with `Set up Workbench…`.

## Tasks screen

The top bar's `Inbox | Automations` switch changes the centre between the thread screens and the project's scheduled tasks; it
changes nothing in the thread. The Automations (Tasks) screen is a list of the tasks at the left (`SCHEDULED · N`, 360 wide, a row each: the
mark, the name and under it the schedule and how the last run went, no `auto` tag), and the selected task's page on the right ("Will it run tonight?", then the run timeline). While the list is on
screen the inbox rail steps aside: four columns (projects, inbox, list, page) do not fit the 900 pt window. The New task screen and the
empty page have no list, so the inbox rail stays. It is read only: it shows what `TaskLibrary`, `TaskRunLog` and
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
  the script and skill with their sizes); a refusal stays in the card in the core's words. `Run now` starts the run on the one press, with no card to confirm: the task is approved already, and the run line under it says it started. A run started here
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
`Open review` or `Open task` is the one prominent button; `Send back…` opens the window with the guidance field focused. The popover
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
- A sheet or card (`.modal`, `Modal.swift`) has one way out (Esc and a close button) and does not move the screen under it.
- **A modal is centred in the window**, horizontally and vertically, whatever opened it: a card is never placed beside, under or over the
  control it came from, and the project card is no exception. `.modal` has no placement to choose (it was removed so that it cannot be
  re-added by accident); a card that seems to need one is a design question for DESIGN.md first, not a new case in `Modal.swift`.
- **A modal you page through keeps its size.** The screenshot preview sizes a set to its largest shot (bounded by the window) and fits
  each picture inside it, and a modal's title never widens its card (a long one is cut): the card grew and shrank with every verify
  screenshot until it did. `ScreenshotPreviewModelTests` checks the area is the same on every page.
- **A list has a cap, and says what it left out.** Any list that can grow (an inbox section, the rail, a menu, a picker) shows at most
  **10** rows, then a line with the count that is hidden ("Show 14 more"); the one on screen and anything that needs the person stays
  listed whatever the cap. Every section is capped, not only the last one: Needs you and Waiting grew past ten because only Done had a
  limit. A list with no cap is a design question for this file first. A scenario with more than ten rows (`AppScenarioManyThreads`) is
  captured in the PR.
- **Everything you can click can be reached from the keyboard.** A new screen or component names, in its PR, how a person gets to it,
  moves over it and acts on it without the mouse: it takes focus (`.focusable()` and `.focused`, or a real `Button`), arrow keys move
  over a list or a row of tiles, Return opens, Esc leaves, and changing project, thread or tab leaves focus somewhere usable (the new
  screen's first control), never nowhere. A tile or row that is a shape with `onTapGesture` fails this by construction. Show it in
  the PR the way the screenshots are shown: the keys pressed and what the window did.
  A screen that opens takes the caret only if nothing the person is walking with the keys holds it: the project rail keeps focus while
  ⌥⌘↑/↓ or the arrows step over it (`ProjectStore.railFocused`), so the chat and new-goal boxes do not grab it from under the keys.
- **Where the keys are is always drawn.** A list or row of tiles is one focus stop and its arrows select as they go, so selection cannot say
  whether the keys are on it: the selected item draws the focus ring (`FocusRing.swift`, the system's focus colour, never one of the five
  meaning colours) only while its list has focus. A new focus stop sets `.focused`, `.listHasKeys(_)` and, in its items,
  `.selectedFocusRing(_, radius:)` (or `.focusRing(_, radius:)` for a stop whose item is the stop). `.focusEffectDisabled()` is allowed only
  with one of them. Every list that is walked with the arrows also sets `store.listFocused` (the project rail sets `railFocused`, the switch `switchFocused`), and a
  screen that takes the caret when it opens checks `store.listHasKeys`. The top bar's Inbox / Automations switch is one stop (← →) and
  View ▸ Inbox (⌘I) and View ▸ Automations (⇧⌘A) reach it without Full Keyboard Access, which Tab to a plain control depends on.
- Keyboard shortcuts where the siblings have them: a card cancels with Esc and confirms with ⌘Return.
- A multi-line text box is `PlaceholderTextEditor` (the placeholder sits where the text view starts its text, measured by
  `scripts/check-text-alignment.py`; a box that grows with its text hides its scroll bar). Never a bare `TextEditor`: CI refuses it.

## What this file does not cover

Behaviour: that is the verifier and the tests. This is only how it looks. Where it is silent, follow the Human Interface
Guidelines for macOS, and if a change introduces a pattern on purpose, add it here in the same PR.
