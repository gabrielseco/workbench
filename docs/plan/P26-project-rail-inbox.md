# P26: Project rail and inbox

Status: in progress, slices 1 to 3 built. Design: [`../design/project-inbox/`](../design/project-inbox/) (`Main.dc.html` the inbox, `Automations.dc.html`
the automations view; copied from the Design canvas, 2026-11-08).

Threads can now run side by side (P23), so the window stops being "one project, one thread, and a list". The design makes **projects visible**
(a rail of them, each with its count) and turns the thread list into an **inbox** sorted by what needs you. This plan is the gap between that
design and `main`.

## What the design shows

| Area | Design | Today |
|---|---|---|
| Project rail | 72 pt column of project tiles (two letters), a selected bar, a count badge (amber needs you, red failed, blue dot running), a top tile for **all projects' inbox** with the summed count, `+` to add a project | One project at a time; a `ProjectPill` in the top bar opens the project card to switch |
| Inbox | `INBOX · PROJECT` with `+`, sections **Needs you**, **Waiting** (shipped PR, CI running), **Done** (collapsed: "Show 9 finished threads"); a row is a mark, the title, the reason in words, the spend; an automation that needs approval is a row with an `auto` tag | `PreviewRail`: Threads (flat, `Show more`) then Scheduled tasks |
| Top bar | project name and `base`, an **Inbox / Automations** switch with counts, spend and state pill in the thread view, `New task…` in the automations view | `ProjectPill`, **`AgentsPill`**, base, spend, state pill; no switch (`WindowMode` thread/tasks is reached from the rail) |
| Thread detail | title, a stage line (Goal, Run, Review, Accept, Ship, PR review, Clean), goal card, activity lines, a **NEXT** card with the action | `FeedScreen` (chat feed) |
| Automations | its own view: task list (7, with marks) and the detail with "Will it run tonight?", history, `Run now`, `Edit with AI` | `TasksView`, reached from the rail |
| Footer | event log, Doctor, `30 min per turn` | `FooterBar` |

The fake window chrome (traffic lights) is the canvas's, not something to build.

## The one thing the design drops: Agents

The top bar has no agents pill. The Agents card (P25) stays and must stay **per project**, so it moves instead of going away:

- **Rail tile menu** (right click or long press on a project tile): `Agents…`, `Doctor`, `Reveal in Finder`, `Remove from rail`. `Agents…` opens the
  existing card for *that* project, even when it is not the selected one.
- **⌘,** and the app menu's `Agents…` keep working for the selected project (`WorkbenchApp.swift:44`).
- **Inbox header button** (decided): a small `cpu` icon button beside the `+` in the `INBOX · PROJECT` header, its tooltip the run role's
  `Codex · gpt-6.1-terra`. It is the visible way in; the top bar stays as the design draws it. It is not shown in the Automations view, which has
  the tile menu and ⌘,.
- The goal agent is still named on a chat and on the new-thread screen (P25 slice 1); that is where it matters.

## What stands in the way

1. **The app holds one project.** `ProjectStore.project`, the polling, `AttentionCenter` and `ThreadListLoader` all follow the selected project.
   `sessions` is already keyed by `(project path, thread)` and quit/recovery already walks `ownedRuns` across projects
   (`ProjectStore+Quit.swift`), so a run in another project survives a switch; what is missing is *reading* the other projects' state.
   P23 lists "many projects at once" as out of scope for running; this phase lifts it only for **showing and switching**. One project still has
   `max_active_threads` threads, and there is no cross-project scheduler or spend cap.
2. **The rail must know which projects.** Today: `recentPaths` (up to 10, `ProjectStore+Recents.swift`). The rail needs an explicit, ordered, removable
   list (pinned projects) in `Preferences`, seeded from the recents.
3. **Counts for projects that are not open.** Needs a cheap read of each rail project's threads and tasks without loading it: reuse
   `ThreadListLoader` and the task summary, on the 30 s poll `AttentionCenter` already has, one project after another (bounded: no more than the rail's
   limit, a failed read keeps the last count, as `lastTasks` does).
4. **UI rules** (`AGENTS.md`): every new view is a component with props in its own file, added to `COMPONENTS` in `scripts/check-ui-tokens.sh`;
   spacing from `Space`, type from `TextStyle`/`TextRole`, colour from `Theme`; no literals. The design's hexes map onto `Theme` (amber, blue, red,
   green, grey), they are not copied.

## Slices (one PR each, in order)

### 1. Agents off the top bar, reachable per project (built)

Remove `AgentsPill` from `ToolbarBar`. `showingAgents` becomes the agents card *for a project path* (`agentsProject: String?`), so it can open for a
project other than the selected one; `AgentSetup` and `setAgent` read and write that project's config. The inbox header button arrives with slice 4; until then the way in is
the project card's row menu plus ⌘,. Core change: none.
Tests: the card opens for a named project and edits that project's config, not the selected one's; ⌘, opens the selected project's.
verify-app scenario: top bar without the pill, card from the menu.

As built: `ProjectStore.agentsProject` (a path) with `showAgents(for:)`; `showingAgents` stays as the open project's card (⌘,). The card has its
own config state (`cardAgentConfig`, read by `refreshCardAgents`), so it shows and edits the project it was opened for, and an edit to the
open project also refreshes the copy chats and the New goal card read. The card's title is `Agents · <folder>`. The project card's rows have
an `Actions for <name>` menu with `Agents…` (it closes the project card first, so the Agents card is not under it). `VERIFY_OPEN=agents`
shows the open project's card for a scenario.

### 2. Project rail (built)

`ProjectRail` (72 pt), `ProjectTile` (props: `initials`, `selected`, `badge: .needsYou(n) | .failed(n) | .running | none`), `CountBadge`. Replaces
`ProjectPill`; `+` runs the existing folder chooser; the tile menu from the section above. Preferences gain the ordered `railProjects`.
Selecting a tile calls the existing `open(_:)`. The top tile is a placeholder until slice 4.
Tests: `RailProjects` (pure) seeds from recents, orders, removes, drops a project whose folder is gone and says so on the tile; badge precedence
(failed over needs you over running). A removed project's live runs are not stopped.

As built: `RailProjects` (pure: seeding, adding, removing, moving, initials, names) and `RailBadge`; `ProjectRail` (72 pt), `ProjectTile`, `CountBadge`
in their own files. `Preferences.railProjects` is nil until the person arranges the rail (then it starts from the recents, oldest first, so a tile
never jumps), and an empty list is kept as empty. A project chosen from the project card or the folder panel is pinned at the end (a relaunch restoring the open project is not an add, so a removed tile stays removed); choosing one again does not move it. The tile menu
(right click) has `Agents…`, `Doctor` (opens the project first), `Reveal in Finder`, `Move up`, `Move down` and `Remove from rail`; removing only
hides the tile (the project stays in the recents), and removing the open project moves to its neighbour. Two deviations from the sketch above:
`+` opens the project card (the recents and `Choose folder…`) instead of the folder panel, so a recent project can be added and the harness can
press it; the top bar names the project as text, and its pill is gone. The top tile is disabled until slice 4. The open project's tile counts what
the window reads of it; the others show no badge until slice 3.

### 3. Project summaries (counts for projects not open) (built)

`ProjectSummary { needsYou, failed, running }` per rail project, derived from `ThreadRow` marks and the task summary (the rules `RailRow` already
applies), read on the attention poll, bounded, never writing. The badge and the all-projects count come from it. Quit and recovery unchanged.
Failure cases: a project whose log is corrupt shows a red badge, not zero; a folder that disappeared; a read that times out keeps the last count;
the selected project uses the live store, not the poll, so its badge never lags the list beside it.
Core change: a read-only `ProjectSummaryLoader` in `WorkbenchCore` (Linux-testable); no event format change.

As built: core has `ThreadActivity` (the one rule for a thread's mark, which the app's list now calls too, so the list and the rail cannot
disagree), `ProjectSummary` and `ProjectSummaryLoader` (the newest 200 threads, each replayed only when its log or goal file changed; the
`Cache` makes a poll of an unchanged project a `stat` per file). The app's `RailSummaries` reads every rail project on the existing 30 s
attention poll, one after another, off the main actor and with a 10 s limit (`raced`): a read that does not come back leaves the last
count, one still in flight is not asked again, and the tasks' part (the rules `RailRow.task` applies) keeps its last value when the tasks
cannot be read. A tile for a folder that is gone is not read (the tile says so); a project off the rail is forgotten. The open project's
tile is the window's own reading (`railBadge`), the others are the last summary, and the project the window just left keeps the count it
had while open. A log that cannot be read is failed (red), not zero.

### 4. Inbox

`InboxModel` replaces `RailModel`'s thread section: **Needs you**, **Waiting** (shipped, CI running or waiting on review), **Done** (collapsed, count),
in that order, the selected thread kept visible. Row = `ThreadMark`, title, reason line, spend (the rows already carry all four). Automations
needing approval appear in Needs you with the `auto` tag. The `+` stays `beginNewGoal`. The top tile of the rail shows **all projects**: the same
sections across projects, each row with its project's tile mark, a click selects the project and the thread.
Tests: sectioning (every `ThreadMark` lands in exactly one section; order stable; Done hidden count), cross-project merge order, selection survives
a section change.

### 5. Top bar and Automations view

The Inbox / Automations switch with counts replaces the rail's `Scheduled` section and the "Open the Tasks page" link (`WindowMode` stays; the
switch is its control). `TasksView` keeps its content and gains the design's header: `New task…` in the bar, list left, detail right, the rail
still on screen. The base, spend and state pill stay thread-only, as the comment in `ToolbarBar` already requires.

### 6. Thread detail parity

Check `FeedScreen` against the artboard: the stage line, the goal card, the NEXT card. Add only what is missing (likely the stage line as one
component fed by the thread's state). Out of scope: changing the chat feed itself (P22).

### 7. Docs and menu bar

Update `docs/plan/README.md` (the scope rule's "no project list, no inbox" no longer holds for display), P23's "many projects at once" line, and
`MenuBarModel`, which today counts one project's attention.

## Verification (every slice that changes what the app shows)

`scripts/verify-app.sh` on a fixture with **three projects** (needs-you, failed, running) and a second thread running, screenshots posted with
`pr-shots`, one per scenario; `design-review` against the artboards in light and dark at 900x600 (the rail must not squeeze the inbox below its
minimum). Slices 1, 2 and 4 add a text or list control? Only if so, `scripts/check-text-alignment.py`. No verify-cli scenario: no `workbench`
command changes. `release-build` label is not needed unless `Package.swift` or concurrency code changes (slice 3 may touch the latter).

## Not in this phase

A project-wide spend cap, a queue, moving threads between projects, drag-reordering tiles (arrows in the menu first), a light-theme artboard
(the design is dark only; the app follows system appearance through `Theme`, so the light check is by `design-review`, not a new mock).

## Questions for you

Answered by default while building (change them on the PR if wrong):

1. Removing a tile **only hides it**: the project stays in the recents (the project card still lists it).
2. The all-projects inbox **opens a thread in its own project**, switching the rail selection.
