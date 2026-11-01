# P22: The app as a chat feed

Status: planned, nothing built. Written 2026-11-01. Follows [P19](P19-swiftui-app.md) (the window), [P20](P20-goal-editor.md) (the goal
editor) and [P21](P21-scheduled-tasks.md) (tasks). This document describes future behaviour; `docs/spec/` and
[`../DESIGN.md`](../DESIGN.md) still describe what ships.

**Outcome:** a thread is one conversation. You talk before a goal exists, approve a drafted goal, watch the run, judge and verify
arrive as events in the same feed, and press one button to ship. The window lists the project's threads, each row carrying its own
state. Steps advance on their own and the feed stops only when it needs you.

```
list of threads ──▶ one thread = one feed:  chat ─▶ goal card ─▶ run events ─▶ judge, verify ─▶ [Ship] ─▶ PR review
                                              │                                                   (stops only for: failed check,
                                              └─ free: no worktree, no run, no cost until "Make this a goal"   judge disagreement, over budget)
```

This is a **refactor with new behaviour on top**, not a reskin. P19 to P21 were built one screen at a time, each answering the
need of the day, and the app shows it (see "Why now"). We now know the shape, so the work is to make the code that shape first, then
add the behaviour. The old screens keep working until the feed has taken over.

## The design

The mockups are the source: [`docs/design/chat-feed/`](../design/chat-feed/) (an editable canvas, copied from the claude.ai artifact
`T6B63qpQZFpBk9LFUvTjQg`, version `1793569893-f993`). Fifteen artboards, each in dark and light:

| Artboard | Shows |
|---|---|
| A `Main` | brainstorm chat, nothing runs, "Make this a goal" |
| B `B-Goal` | the drafted goal as an editable card, "Approve goal", the Run settings inspector |
| C `C-Run` | mid-run feed: tasks, tool calls, the judge and verify queued, steer, stop |
| D `D-Verify` | judge agrees, verify passed with screenshots, one "Ship" |
| E `E-Autopilot` | **variant, not in this plan:** auto-ship, the PR open and its review comments back in the chat, a list grouped by state |
| F `F-Tasks` | a scheduled task with its run history (the P21 screen, restyled) |
| G `G-NewThread` | a new thread opens into a composer: "Send" is a free chat, "Do it now" drafts the goal from your words |
| `Rail` | the thread list, with scenes for each state |

**The mockups invent specifics** (PR #482, "48 tests", `FeedView.swift`, the `$0.84`). They show layout, not data. The colours are the
five already in `Theme` and `DESIGN.md` (green done, blue working, amber needs you, red broken, grey idle); the primary button is
neutral so it never competes with them. A slice that disagrees with a mockup says so in its PR; a mockup that is wrong gets fixed
in the canvas, not worked around in the code.

## Why now (what is scrappy, checked 2026-11-01)

- **`ProjectStore` is one object that assumes one thread.** `ProjectStore.swift` and its seven extensions are 1,345 lines. It holds the
  project, the recents, the doctor, the tasks, the attention centre *and* the thread on screen: `screen`, `goal`, `review`,
  `currentThread`, `actionError`, `goalEditError`, `busy`, `ownedRun` ("at most one: a second start is refused"). A thread list with
  two live threads cannot be built on that without copying state per thread by hand.
- **Scoping by string.** `busy` and the "awaiting a turn" flag are made to belong to one thread by comparing
  `"<project path>|<thread id>"` strings (`currentScope`, `busyScope`, `awaitingScope`, `generation`). Each is a patch for a stale answer
  landing on the wrong thread; a per-thread object makes the whole class of bug impossible instead of guarded.
- **The window is organised by step, not by conversation.** `Rail` shows the spine, `ThreadPane` switches between `GoalView`,
  `RunView` and `ReviewView`, and `FinishedBanner` carries every post-run button (Ship, Review PR, Merge, New goal). A step has a
  form; the feed has events. The same information, the other way round.
- **The state machine of "what do I press next" lives in views.** `FinishedBanner` decides which of five buttons shows. That is a
  rule of the core (`canShip`, `canMerge` exist) read by a view that then decides layout and order on its own.
- **Concurrency is a promise in three docs and in no code path.** [`later/README.md`](../later/README.md),
  [`later/thread-list.md`](../later/thread-list.md) and [`later/thread-until-merged.md`](../later/thread-until-merged.md) all wait on it.
  This plan does not build it, but it must stop making it harder.

## What exists today (checked 2026-11-01)

- The window: `RootView` (toolbar, 220 pt rail, centre, footer), `ThreadPane`, `GoalView`, `RunView`, `ReviewView`, `FinishedBanner`,
  `TasksView`, the popovers (`NewGoalPopover`, `SendBackPopover`) and the menu bar.
- `ThreadStore.summaries()` lists every thread with its state; `ThreadStore.state(of:)` derives a thread's state from the log.
- The spine (`ThreadSpine`, `SpineStep`) and attention (`Attention`: working, needs you, with a reason) come from the core. The design's
  phase row is the same spine with a Chat step in front.
- The event log already carries what a run feed needs: `agent.activity` (normalized text, tool and usage items, any provider),
  `turn.started` and `turn.ended`, `judge.ran`, `proof.added` and the verifier events, `pr_review.finished`. Readers ignore unknown kinds
  and fields, and the event version stays 1 for additive changes ([`../spec/event-log.md`](../spec/event-log.md)).
- Fixtures for every state: `Fixtures/app/` (draft, goal-approved, running, needs-you, review-changes, accepted, pr-open, pr-findings,
  cleaned, discarded, corrupt, no-thread, tasks), driven by `scripts/verify-app.sh`.
- **Not there:** chat before a goal, auto-advance, a thread list, steering a running turn, more than one live thread.

## Rules for the migration

1. **One data layer, two views, until the flip.** The new feed reads the same models and calls the same actions as the old screens
   (`GoalActions`, `ThreadService`). A bug fixed in an action is fixed for both. No second copy of a rule.
2. **A preference flag, off by default** (`Preferences`: "Chat feed (preview)"). The old window is the default until slice 7. One switch
   puts a person back.
3. **Core changes are additive and default to today's behaviour.** New event kinds and new optional config keys only; a new key's
   default reproduces what happens now (`auto_advance = false` is today's "press Continue"). An old thread's log opens in the new
   view with no migration. Nothing here needs `BREAKING CHANGE:`; if a slice would, it stops and comes back here.
4. **Derive, don't store.** The feed is a function of the log, the goal file and the thread state. No second list of "what happened"
   (the same rule as the event log).
5. **Every slice leaves `main` shippable.** A slice is one PR, merged on its own, with the flag off and the old window unchanged. A
   slice that cannot be merged without the next one is the wrong cut.
6. **Parity is checked on screen.** Every `Fixtures/app/` scenario is screenshotted in both modes (`verify-app`, then `design-review`
   against the artboard). The flip waits for all of them.
7. **The refactor slices change no behaviour.** Slice 1 and 2 are judged by "every existing test passes with only renames, and the old
   window looks the same in `verify-app`".

## Decisions already made

- **The feed is the thread screen, not a new app.** The toolbar, project card, popovers, Tasks screen and menu bar stay; the feed
  replaces the rail's spine and the centre's per-step screens inside a thread.
- **The spine stays** as the phase row under the title (Chat, Goal, Run, Review, Ship, PR review, Clean), core-derived as today.
- **Concurrency is its own phase** (P23, below). This plan builds toward it and does not lift the guard.
- **Autopilot (artboard E) is out.** Auto-ship and "full auto" change what `ship` may do unasked; they need their own decision after
  auto-advance has been used for real.
- **The thread name stays derived** from the request's first line (as P20). A chat's name is derived from its first message.

## Open decisions (settle in slice 0, before any code)

| # | Question | Leaning |
|---|---|---|
| 1 | Where does chat text live: in the event log or in a sidecar like the turn transcripts (`threads/<id>/transcript/`)? | Sidecar, with one `chat.message` event holding path, size and hash, so the log stays small and bounded |
| 2 | Is a chat turn an agent turn (one `turn.started`/`turn.ended`, bounded, costed) or a lighter thing? | An agent turn on its own role in config, read-only, so every ending rule applies |
| 3 | Is auto-advance per project, per goal, or both? | A config default plus the P20 `skip:` style override in the goal |
| 4 | What exactly stops the feed? | A failed check, a judge that disagrees with the criteria, going over budget, and any refused tool call that needs a grant. Everything else goes on |
| 5 | "Steer this run" (send text that arrives when the current tool call ends)? | Leave out of the first cut: it is a new input to a live turn and touches "a turn always ends" |
| 6 | Does chat get a CLI (`workbench chat`) for agents and tests, or is it app-only like the P20 editor? | CLI, so it can have a verify-cli scenario and an agent can use it. Decide with #1 |
| 7 | Does the mockup's inspector ("Run settings") replace the Goal screen's settings, or sit beside it? | Replace: one place for what a run is allowed to do |

## Slices (one PR each)

### 0. Settle the decisions

Docs only. Answer the open decisions above in this file, write each slice's goal file (the `goal` skill), and update
[`../plan/README.md`](README.md)'s scope rule to say what the list and the chat change. Nothing is built.

### 1. A per-thread session (refactor, no behaviour change)

Split `ProjectStore` in two:
- `ProjectStore` keeps what is the project's: the project, recents and refused paths, the doctor, tasks, the attention centre,
  preferences, the picker and the popover flags.
- `ThreadSession` (new, one per thread on screen) holds what is the thread's: the snapshot, the goal model, the review, the owned run,
  `busy`, `actionError`, `actionNote`, the goal edit state and the polling for that thread.

The string scopes (`currentScope`, `busyScope`, `awaitingScope`) go away: an answer for an old session lands on an old session.
`ProjectStore` holds exactly one session for now (the current thread), so the window is unchanged; two sessions at once is P23's
problem and is no longer a rewrite. Do it in two PRs if one is too big: 1a moves `busy`, the awaiting flag and `ownedRun`; 1b moves
`screen`, `goal`, `review` and the actions that act on them.
*Tests:* the existing `WorkbenchAppTests` pass with renames only; one new test per bug the string scopes guarded (a reload that
answers after another project is opened; a doctor run that ends after the thread changed).

### 2. The feed as data (core or app, no UI)

A pure function `Feed.items(log, goal, state) -> [FeedItem]`: a user message, an agent message, a goal card, a run event (a turn
started, a tool call with its summary, a file edit with its diff size, a denial), a judge result, a verify result with its
screenshots, a decision (the one button and why), a notice. One `FeedItem` kind per row in artboards A to D.
*Tests:* a fixture log per scenario produces the expected items in order; a damaged log shows what could be read and says so (as
`ThreadSnapshot.problems` does now); bounded: a turn with 1,000 activity items becomes a bounded feed, grouped, never a thousand rows.
Whether this lives in `WorkbenchCore` (so `workbench log` and a future web view can share it) or in the app is decided here.

### 3. The feed screen, behind the flag

The new thread screen: header with the phase row and the state pill, the feed, the composer, the inspector, the footer as today.
Reads `ThreadSession` and `Feed.items`. Shows the existing flow only: the goal card edits through the P20 `GoalEditor`, "Approve goal"
calls `approve`, the run events are the live log, the decision card calls `ship`, `accept`, `send-back` and `discard`. No chat, no
auto-advance: the Continue button is a card in the feed.
*Check:* every `Fixtures/app/` scenario in both modes, side by side, with `design-review`. `DESIGN.md` gets the feed's layout rules in
this PR (the "Layout" section describes a 220 pt spine rail and per-step screens today).

### 4. Auto-advance (core, then the feed)

`[run] auto_advance` (default `false`) plus a per-goal override. When on, a passing turn goes to check, verify and judge without a
press, and the thread stops only on the conditions of open decision 4. The CLI honours it too (`workbench run` and `next`), so the
feed does not own a rule the terminal lacks.
*Tests with the fake claude:* the stops (a failing check, a judge with an unmet criterion, a budget stop, a denied call), and that
every stop still ends in exactly one `turn.ended` per `turn.started`. A verify-cli scenario, normal and sabotaged, because a command
now does something it did not.

### 5. The thread list

The rail becomes the list: a row per thread from `ThreadStore.summaries()` with the title, a mark (working, needs you, done, idle) and
one line of state; selecting a row changes `currentThread` and builds that thread's session. Grouped by state once there is more than
one live thread (artboard E's rail). The single-active-thread guard in the core **stays**: until P23 the list shows history and the
one live thread. This slice makes "open an old thread" possible in the window, which `later/thread-list.md` said was missing.
*Tests:* switching threads during a reload, during a run and during a doctor run shows the right thread's state each time.

### 6. Chat before a goal

New thread state `chat`: a free conversation with no worktree, no run and no cost to the thread's budget (the turns are costed and
bounded like any, on their own role). "Make this a goal" drafts the goal from the conversation through the existing `draftGoal` path;
"Do it now" (artboard G) does the same from one message. `NewGoalPopover` stays as the way in until the flip. New events
(`chat.message`, `chat.ended`), additive, specified in `docs/spec/event-log.md` in this PR. A chat that is never made a goal is a
thread you can read and discard, never a leftover process.
*Tests:* a chat turn is bounded and always ends; a stopped, timed-out and crashed chat turn each record how it ended; a chat creates no
worktree and no branch; an old log with no `chat.*` events opens as before.

### 7. Flip the default, remove the old window

The flag defaults on for one release, then the old `ThreadPane`, `SpineRail`, `GoalView`, `RunView`, `ReviewView` and
`FinishedBanner` are deleted along with their fixtures' old-mode screenshots. `DESIGN.md`, `docs/mac-app/` (replaced by
`docs/design/chat-feed/`) and the scope rule in `plan/README.md` are updated in the same PR.

## Concurrency (P23, not this plan)

Written when slice 5 has landed. It lifts the single-thread guard in the core, gives each `ThreadSession` its own owned run, adds the
shared process and CPU budget and the resume-race handling, and needs its own soak (the gate is in [`README.md`](README.md)). It also
unlocks [`later/thread-until-merged.md`](../later/thread-until-merged.md) (a shipped thread stays open until its PR is merged). Slices 1
and 5 exist so that P23 is mostly deleting a guard and adding a budget, not reshaping the app.

## Failure cases the plan owns

- A thread that ended badly (crash, timeout, killed runner) shows how it ended in the feed, never an empty or spinning row.
- A damaged log shows what could be read and says what is damaged; Workbench never rewrites a log.
- An answer for a thread that is no longer on screen is dropped by construction (slice 1), not by a string compare.
- The flag off means the old window, exactly. A test opens every fixture with the flag off after each slice.
- Auto-advance never skips an approval: a goal whose hash changed is `stale` and the feed stops there.
- Every chat and every advance is bounded (turns, time, budget, lines, log size), as everything else.

## Out of scope

Autopilot (auto-ship, full auto), steering a live turn, more than one live thread (P23), many projects open at once, the iPad
or any non-Mac layout, the Triage integration, and any redesign of the Tasks screen beyond the shared styling.

## Risks

- **Slice 1 is large** and touches what every other slice stands on. It is the one place to take the time: no behaviour change, a full
  test pass, and two PRs if needed.
- **The feed over-grows.** A long run produces a long feed; group tool calls and cap what is drawn (slice 2's bound), and keep the log
  one click away as today (`Event log` in the footer).
- **Two views to keep in step** for as long as the flag exists. The rule is one data layer; the cost is the flip's date. Keep the
  flag's life short: slices 3 to 6 are meant to follow each other.
- **Chat widens what Workbench is.** It is a thinking space before a goal, not a general assistant: it has no tools that write, no
  worktree, and ends in "Make this a goal" or in being discarded.
