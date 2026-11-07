# P23: Concurrency

**Outcome:** a project can have a few threads active at once (three is the case this is sized for), each in its own worktree, and none
can break another: not through a port, a git lock, a quit, a crash or a ship onto a moved base. The default stays one, so nothing
changes until the setting is raised.

**Why now:** [`README.md`](README.md) sets a "well" gate before concurrency. It is waived: the app already does a thread's work
efficiently, and the wait is the limit. D0 is superseded by this phase. The layout is already thread-shaped (a folder and a worktree
per thread id, a process only while a step runs), and [P22](P22-chat-feed.md) made the app per-thread (`ThreadSession`, the rail), so
this is mostly lifting a guard and closing the places that assumed one thread.

## What a thread is, and why that sizes the work

A thread is files (`threads/<id>/`, a worktree, a branch); a process exists only while a turn, check, verify, plan or judge runs
(`runner.json` names it). An idle thread costs nothing, so the cap is on **running steps**, not open threads. Three threads are mostly
three turns waiting on the network, so this is not a resource manager: one number for checks, no scheduler, no queue.

## Scope

In: per-thread ports for every command Workbench starts; the guard lifted behind `max_active_threads`; explicit thread selection in the
CLI; the shared-repo git calls made safe to overlap; `max_concurrent_checks`; the app for N live threads, including quit and recovery;
ship onto a base that moved; a concurrent soak.

Out: a queue (a step over the cap is refused with a message), a CPU or memory scheduler, a project-wide spend cap (per-thread budgets
stay), many projects at once, a per-thread database or other services (the project builds those from `WORKBENCH_THREAD`, documented),
more than a handful of threads.

## Facts the slices rest on (checked on `main`, 2026-11-07)

- `ThreadStore.activeThreadID()` returns one thread and `create` refuses a second; about 12 callers read "the" active thread
  (`Commands.swift`, `CommandsChat`, `TaskRunner`, `ThreadService+Chat`, `+GoalDraft`, `+QuickGoal`, `DoctorAgents`, the app's `ProjectLoader`
  and `TasksModel`).
- The app's quit guard describes one run (`ProjectStore.liveWork`, `runningProjectPath`).
- The app's port is `AppLauncher.freePort()`: the kernel picks one and the socket is closed again, so nothing reserves it and two threads
  that start a moment apart can get the same one. Only `[run]` receives it; `check_command` and `setup_command` do not.
- `GitRunner` has no handling of git's own lock files; worktrees share one `.git`.
- `setup_command` and `copy` exist, so a fresh worktree gets its install and its gitignored files.
- `doctor` takes `ProjectLock`; `requireNoDoctor()` makes runs refuse while it runs. Per-thread `runner.json` already makes a second step
  on the same thread `busy`.

## Slices (one pull request each)

### 1. Ports per thread (no guard change) (built, #447)

A stable port block per thread, chosen when the thread is created and recorded in its folder, so it is the same for the run, the check, the
setup and every retry, and different between threads. `WORKBENCH_PORT` and `PORT` for the first, `WORKBENCH_PORT_1…` for more (`ports = N`
in the config, default 1), passed to `[run]`, `check_command` and `setup_command` on the allowlisted environment. `AppLauncher.freePort()`
becomes a fallback for a thread with no recorded block. Document the pattern for a database name (`…_$WORKBENCH_THREAD`).

As built: blocks are slots of ten from 41000 (each project starts at a slot of its own from its path, a port in use is skipped, a block counts only while the thread has a worktree); the in-use check connects to `127.0.0.1` and `::1`; an app is never started on a port something else holds, the thread moves to a free block first. See "Ports per thread" in [`../spec/goal-file.md`](../spec/goal-file.md).

Failure cases: a block already in use by something else (the step reports it, never starts on a port it was not given); two threads
created at once get different blocks; a thread from before this change still runs.

### 2. The guard behind a setting

`activeThreads()` replaces `activeThreadID()`; `max_active_threads` (default 1) replaces the refusal in `create`. Go through each caller
and decide it (the list above); the draft and chat paths compare "active at start" with "active now", which becomes "this thread's state".
Scheduled tasks skip with `skipped-project-busy` only when no slot is free. With the default at 1 every behaviour is unchanged.

### 3. The CLI names its thread

A command that acts on a thread takes `--thread`; without it, one active thread is used and several are refused (exit 6, listing them).
Update `docs/spec/exit-codes.md`, `cli-json.md`, and the verify-cli scenario that covers the commands.

### 4. The safety layer

Shared-repo git calls (`worktree add`, `fetch`, `gc`, the ship pushes) run one at a time per project, and retry once on a lock-file error.
`max_concurrent_checks` (default 2): a check over the cap is refused with a message naming the running ones. Doctor stays exclusive.

### 5. The app for N live threads

The New goal flow stops abandoning the active thread. The rail shows every live thread with its attention mark. Quit lists and stops all
live work (`liveWork` and `runningProjectPath` become per-thread), and a crash with several turns open ends each with one `turn.ended`
(`recoverOrphanedTurn` per thread). Screenshots with `pr-shots`.

### 6. Ship onto a moved base

Two threads from the same `main` will touch the same files. Accept and ship rebase onto the new base or fail with a message saying what
conflicted; the review screen says the base moved since the thread started.

### 7. Soak and raise the default

A fake-claude soak with three threads at once, with crashes, hangs, ignored SIGTERM and leftover children, asserting one `turn.ended` per
`turn.started` per thread and no leftover process. Then the default goes above 1, and
[`later/thread-until-merged.md`](../later/thread-until-merged.md) is unblocked.

## Failure cases the plan owns

- Two threads never share a port, a worktree, a session or a log.
- A step over `max_concurrent_checks` is refused, never queued and never silently slowed.
- A git lock error is retried once, then reported with the command, never swallowed.
- Quit and a crash end every live turn; each thread says how it ended.
- A command with several active threads and no `--thread` refuses and lists them.

## Risks

- A project whose checks use a shared service (a test database, a mock API) still collides; Workbench gives the thread id and ports, the
  project's script uses them.
- Three builds at once are slower, not wrong; the check cap is the only brake, on purpose.
- Slice 2 touches `Codable`, concurrency and process code: it takes the `release-build` label, and the soak is its gate.
