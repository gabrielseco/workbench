# Workbench

A small macOS app for handing a coding task to Claude and getting back work you can trust.

```
Write a Goal → you approve it → Claude works in an isolated worktree
             → it shows the diff and check results → you accept, send it back or discard
```

Workbench is a sibling of [Triage](../triage) (the PR inbox). It is deliberately a separate app: it is
prototyped on its own first, and only then do we decide how the two talk to each other.

**Scope, on purpose:** one project, one thread at a time. Do that well first; concurrency, many projects,
screenshot proof and Triage integration are in [`docs/later/`](docs/later/README.md).

**Status:** the Swift package and CLI are built; the SwiftUI app is planned. Current coding and judging
use Claude, automated review uses Codex. [P9: Agent providers](docs/plan/P9-agent-providers.md) plans
independent provider/model selection for goal drafting and each execution responsibility and is required before SwiftUI development.
Start at [`docs/plan/README.md`](docs/plan/README.md).

## Checking a change

Run `scripts/check.sh` from any directory: it runs the banned-API check, `swift build` and `swift test`, as CI
does, and stops at the first step that fails.

## Starting a project's app

A project that has a UI says how to start it in `.workbench/config.toml`, and Workbench starts it for the verifier on a
free port, waits until it is ready and ends it with the turn (see [P16](docs/plan/P16-run.md)):

```toml
[run]
command = "npm run dev:mock"
ready_url = "http://localhost:{port}/"   # or ready_line = "a line the command prints when it is up"
```

## What a thread is

The thread is the unit of work. There is exactly one active at a time, and it is exactly:

| Part | What it is |
|---|---|
| A **goal** | A markdown file: the request, checkable criteria, out of scope. Approved by you before anything runs. |
| A **worktree** | An isolated git worktree and branch where the work happens. The safety boundary. |
| A **session** | One Claude Code session, resumed across turns. |
| An **event log** | Everything that happened, appended as JSON lines. The source of truth for the UI. |

## Principles

These come from what went wrong when this was built inside Triage.

1. **The boundary is the worktree, the allowlist and the budget.** Not a clever parser. Claude Code enforces
   permissions; Workbench only decides which tool set a thread runs with.
2. **No prompts mid-run.** Approval happens once, on the goal. Anything outside the allowlist is denied
   automatically (`--permission-prompts none`) and shows up in the review.
3. **One owner per subprocess, no blocking waits.** Every run ends in a recorded terminal state, including when
   it is killed, times out or crashes. A run that cannot say how it ended is a bug.
4. **Everything is a file.** Goal, events, result: inspectable, diffable, resumable, easy to test.
5. **Reliability is an acceptance criterion.** "100 runs, zero hangs" is a gate, not a hope.
6. **Small slices that end in a demo.** A phase is done when you can use it, not when the checklist is long.
7. **One thing well before more things.** If a feature needs the word "concurrent", it waits.

## Layout (planned)

```
workbench/
  README.md
  docs/plan/     P1 runner, P2 review, P3 app (this is where we are)
  docs/spec/     goal file and event log formats
  docs/later/    deferred: concurrency, proof, Triage
  Package.swift  WorkbenchCore library + `workbench` CLI   (P1, P2)
  App/           SwiftUI app                               (P3)
```
