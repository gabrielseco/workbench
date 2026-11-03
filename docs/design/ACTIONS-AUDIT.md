# Actions audit: where a button lives, so nothing is said twice

Static audit of `Sources/WorkbenchApp` (2026-11-03, from the code, not from screenshots; a `verify-app` sweep per scenario
would confirm the tables below). Prompted by #388: after a run, Run settings offered "Open in editor" (the goal file) and
"Open in Herdr", while the review card's "…" menu offered Open worktree and Open in Herdr.

## What the app has today

Two UIs draw actions, and they overlap:

- **The feed** (`chatFeedOn`): one decision card per thread. `FeedActions.derive` (`FeedAction.swift`) is the single place that
  picks the next press (`primary`, at most one) and the rest (`more`, the "…" menu). This is already the right model.
- **The step screens** (the older UI): each hand-draws its own row. `ReviewView.actions` (Discard, Open worktree, Open in Herdr,
  Open diff, Refresh, Send back, Accept), `RunView` (Open worktree, Open in Herdr, Run again), `GoalView` (Open in editor,
  New goal, Open in Herdr), `RootView` (Ship, Merge, New goal, Show findings, Refresh).
- **Run settings** (`RunSettingsInspector.openers`): a third list, always on screen beside the feed.

## Repeats found

| Action | Where it is offered (same thread, same moment) |
|---|---|
| Open in Herdr | decision card "…" (every state), Run settings (before a run), `ReviewView`, `RunView`, `GoalView` |
| Open worktree | decision card "…" (run, review, decided), `ReviewView`, `RunView` |
| Open goal file | Run settings, `GoalView` ("Open in editor": same action, different label) |
| New goal | decision card (draft, decided, PR), `RootView` banner, `GoalView`, `WorkbenchApp` menu, empty state |
| Merge, Ship, Show findings, Refresh CI | decision card and `RootView`'s finished banner |
| "Open in editor" | means the goal file (Goal, Run settings) and one changed file (`ReviewView` file sheet): two meanings |

Same action under different names is the worst of these: "Open in editor" (goal file) next to "Open worktree" (also the editor).
Several "Stop" buttons exist too (feed, chat, new-goal popover, tasks), but they stop different things; only the label could say which.

## Rules

1. **One home per action.** An action is offered in exactly one place on a screen. Where two UIs exist, the second reads the first
   (`FeedActions`); it does not rebuild the list.
2. **Place by what it acts on.**
   - *The current step* (Accept, Send back, Discard, Ship, Merge, Run again, Stop, Open diff, Refresh): the decision card. One
     primary, the rest in "…".
   - *The thread's work* (Open worktree, Open in Herdr): the decision card, the same two in every state while a worktree exists.
   - *The run's configuration* (goal file, limits, tools, folders): Run settings. It never carries open-the-work actions.
   - *Starting something unrelated* (New goal): the rail and the menu bar, not the card, except when it is the next step.
3. **One name per action, and the name says the object.** "Open worktree", "Open goal file", "Open diff", "Open in Herdr". Never a
   bare "Open in editor".
4. **A state shows only what can be pressed now.** Hide, do not grey out, what cannot apply: no Open diff before there is a diff,
   no Refresh while running, no worktree actions once discarded or cleaned (`decided` already does this).
5. **One primary per state**, already true of `FeedDecision`. A sheet or popover has a primary plus Cancel; Cancel is never primary.
6. **Confirmation belongs to the action, not the button.** Merge, Discard and Ship confirm in one dialog each, whichever surface
   starts them.

## Actions per phase (what the decision card should offer)

| Phase | Primary | "…" menu |
|---|---|---|
| Draft goal | Approve and run | Open in Herdr, New goal |
| Approved goal | Run | Open in Herdr, New goal |
| Running | Stop turn | Open worktree, Open in Herdr |
| Run ended badly | Run again | Open worktree, Open in Herdr |
| Review | Accept work, plus Open diff beside it | Send back, Discard, Review details, Open worktree, Open in Herdr, Refresh |
| Accepted | Ship | Open worktree, Open in Herdr, New goal |
| PR open | Merge (CI green) or Review PR | Show findings, Refresh CI, Open worktree, Open in Herdr, New goal |
| Discarded, cleaned | New goal | none (no worktree) |

`derive` already matches this except one row to confirm: it offers Open in Herdr in the draft and approved states, where there is
no worktree and it opens the project.

## Work this implies (in order)

1. Done, #388: Run settings stops repeating the card after a run.
2. Done: Run settings no longer lists Open in Herdr; it keeps the goal file (rule 2).
3. Done: Review shows **Open diff** as a plain button beside Accept work (what changed is what a reviewer looks for, and it was
   hidden in "…"). Open worktree and Open in Herdr stay in the menu. `FeedDecision.secondary` is that one slot.
4. Step screens: build their rows from `FeedActions.derive` while both UIs exist, or retire them with the feed preview.
5. A test that, per scenario, no `FeedAction.Kind` appears twice in `derive` output and Run settings lists none of the card's titles.
