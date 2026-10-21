# A thread that stays open until its pull request is merged

Status: idea, not planned. It waits on [concurrency](README.md), because today one project has one active thread.

## The idea

`ship` ends a thread's work but not the thread: the thread stays open, in a `shipped` state, until its pull request
is merged or closed. While it is open Workbench watches the pull request, read-only:

- CI checks (what `ship --watch` does now, for as long as the PR lives, not one `--timeout`).
- Review rounds: a new push or a review comment can start the next `pr-review` round or a follow-up turn on the same
  branch (what `--review-loop` does now), asking before each push.
- The merge: when the PR is merged Workbench runs `clean` for that thread and says which other open PRs now need a
  rebase (step 9 of the `workbench` skill, done for you). When it is closed unmerged it says so and keeps the branch.

Workbench never merges. The person does, or says to.

## Why

The lifecycle has a hole after `ship`: nothing records "waiting for review or merge", so `clean` has to be remembered and a
PR can sit with an open comment or a red check unseen. A thread that lasts as long as its PR makes `status` the single answer to
"what is still open".

## Why not now

A thread that waits for a person would hold the project's only active thread for hours or days, and block the next task.
So this needs more than one active thread. Until then a shipped thread ends, and `clean --yes` removes the merged ones
afterwards.

## Shape, when concurrency exists

- A thread state `shipped` (open, no turn running) next to `running` and `accepted`; it does not count against the
  budget or the turn timeout, and does not hold the worktree lock once the worktree is removed.
- `status --all` lists it with the PR number and what it waits on (`CI`, `review`, `merge`).
- The watcher polls `gh` at a long interval and is one owner per subprocess like every other child; a watch that cannot say
  how it ended is a bug (the Conventions in `AGENTS.md`).
- Exit and recovery: a crashed watch is restarted by `status`, and a thread whose PR was merged while Workbench was not
  running is cleaned on the next command.

## Open questions

- Poll or a webhook (a local app could listen; the CLI cannot).
- Whether a new review comment starts a turn by itself or only shows in `status` until the person says so.
- How long a shipped thread may stay open before `status` asks about it.
