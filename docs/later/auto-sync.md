# Threads that keep up with the base on their own

Status: idea, not planned. It builds on `workbench sync` and the review screen's `Bring up to date` ([P23](../plan/P23-concurrency.md),
slice 6) and waits for the P23 soak, because it starts turns nobody asked for.

## The idea

Today a person brings the base in: `workbench sync [--run]`, or the button on the review. That is the manual version of something that
should come to need no one. When the work is stable nobody wants to read what landed on `main`; they want the thread to be healthy
when they come back to it. So when the base moves, an open thread syncs itself: Workbench merges the new commits in, starts the
sync turn if the merge conflicted or the check needs to see the result, and the check, not the agent, says whether it worked.
Only a thread that could not be healed asks for the person.

## Why it is mostly built

- **Detection:** `base_moved` (`ReviewReport.baseMovement`, `status`, `review`): how far the base is ahead and which of the thread's
  files it touched too.
- **The act:** `ThreadService.syncBase` (fetch, save uncommitted work in its own commit, merge, leave a conflict in progress,
  record `base.synced`) and `SyncPrompt`'s note, started through the same path as `send-back`.
- **The judge:** the project's check after the turn, as for any turn. Nothing here marks a thread healthy because the agent said so.
- **The trigger it adds, from [thread until merged](thread-until-merged.md):** when a pull request merges, that note says which other
  open PRs now need work. Auto-sync is that work, done for you.

## When it fires

In order of how safe they are; start with the first.

1. **Before `ship`.** The thread is idle and about to publish; syncing then is the least surprising, and a conflict stops the ship
   with a reason instead of opening a pull request that cannot merge.
2. **When the thread is idle and the base moved** (no turn, no check, no open decision being typed into), checked when Workbench
   looks at the project, not on a timer of its own.
3. **When another thread's pull request merges** (needs thread-until-merged), for each open thread whose files it touched.

## What keeps it safe to leave alone

- **Opt-in:** a setting, `auto_sync = "off" | "before_ship" | "idle"`, default `off`. It is a project's decision to spend turns this way.
- **Never during work:** it waits for a thread with no live turn, check or run; a merge never starts under a runner (`syncBase` holds the
  thread's log, as today).
- **Bounded:** one turn per sync, under the thread's own budget and timeout, at most two attempts for one movement of the base. A
  budget overrun, a check that is still red, a refused turn or a conflict the agent left unresolved ends it: the thread goes to
  `needs you` with the reason, and the merge is left as it is for the person.
- **Merge only:** history is never rewritten, nothing is pushed by a sync. A branch already pushed gets the merge commit as a normal
  commit; a push stays a decision (or the existing `ship` rules).
- **A trail:** `base.synced` and the turn are in the log; the review says what the sync changed, and `status` says when it last ran.
- **Counted:** an automatic turn is a turn, so it counts against the thread's budget and, while it runs, the project's
  `max_active_threads` and `max_concurrent_checks` like any other. A project-wide spend cap does not exist (P23 out of scope), so the
  per-thread limit above is the only brake.

## Open questions

- Whether `idle` should be allowed at all before the person has used `before_ship` for a while.
- How a sync that heals a thread but changes what the criteria were checked against is shown: the check passed again, but the
  judge's earlier verdict was about the old base.
- Whether a thread whose sync keeps failing should stop trying until the base moves again.
- What `workbench status --all` says for a thread that synced itself an hour ago, without making the list noisy.
