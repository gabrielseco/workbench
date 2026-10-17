# Plan

**Do one thing well: one project, one thread at a time.** Concurrency, many projects, proof and Triage
integration all come later, and only after the single-thread loop is boringly reliable.

The thing we are building:

```
you write a goal → you approve it → Claude works in a worktree → you see diff + checks → accept / send back / discard
```

Phases, in order. Each ends with a demo you can run, not just merged code.

| Phase | Name | Outcome | Size |
|---|---|---|---|
| [P1](P1-runner.md) | Runner | `workbench run` runs Claude on an approved goal in a worktree, logs everything, always ends cleanly | M |
| [P2](P2-review.md) | Review | `workbench review` shows diff and check results; accept, send back, discard | S |
| [P2.5](P2.5-ship.md) | Ship | `workbench ship` pushes an accepted thread and opens its PR; Claude never holds credentials | S |
| [P2.6](P2.6-harden.md) | Harden | `setup_command`, a `status` that says working or stuck, thread ids on `status` and `log`; the probe's fixes | S |
| [P2.7](P2.7-pr-sections.md) | PR sections | `ship` fills the template's Why from the goal and What changed from the diff, so no section is left empty | S |
| [P4](P4-verify.md) | Verify | `verify_command` runs in the background and a thread ends with screenshots, a recorded result and an advisory verdict; piloted on expense-tracker, then Triage | M |
| [P5](P5-review-loop.md) | Review loop | `workbench pr-review` runs a second reviewer on the shipped PR; `ship --review-loop` feeds its findings back as turns until clean or a cap | S |
| [P6](P6-review-stages.md) | Review stages | a project declares its review stages and their order (`pr-review` is the default, design or migrations can follow) and the loop runs them in order; task 1 (config, `ReviewStage`, doctor) built | M |
| [P3](P3-app.md) | App | One window that does the whole loop without the terminal | M |

Sizes are relative effort (S < M < L), not dates. Deferred work lives in [`../later/`](../later/README.md).
What got in the way while using Workbench on itself is kept in [`FRICTION.md`](FRICTION.md).

## The scope rule

At any moment there is **one project** (a git repo you point Workbench at) and **one active thread**.

- Starting a new thread while another is not finished is refused with a clear message. No queue.
- There is no thread list, no project list, no inbox. There is "the current thread" and a short history.
- Nothing runs concurrently. Not turns, not checks, not two threads.

The on-disk layout is still thread-shaped (a folder per thread id) so that lifting this later is deleting a
guard, not a migration. But no code is written for the many-thread case now.

## When is it "well"? (the gate for concurrency)

We open [concurrency](../later/README.md) when all of these hold, not before:

- [x] P1 soak green on CI and locally: 100 fake runs and 10 real runs, zero hangs, one `turn.ended` per turn.
      (2026-10-13: five local soaks of 100 fake runs, 10 of 10 real runs; CI runs the fake soak on every PR.)
- [ ] P2 accept/discard leaves the repo clean every time, including after stop, timeout and crash.
- [ ] You have used P3 for **20 real tasks** on your own repos and finished them (accepted or discarded)
      without touching the terminal or hand-editing a log.
- [ ] You would let it run while you do something else. If you still watch it, it is not done.
- [ ] The list of "annoying things" from those 20 tasks has been worked down. Fix the loop before widening it.
- [ ] It has been tried once on a repo of another stack, and what broke is written down in
      [`later/portability.md`](../later/portability.md). Do this after P2, before P3 is designed around one
      repo's layout.

## What we learned first (and why the plan looks like this)

Building this inside Triage produced about 5.6k lines across PRs #54 to #58 and then a revert. The causes:

- **A fragile process layer.** A long-lived `claude` process with a stdin channel, GCD drain queues and
  `Process.waitUntilExit()` produced hangs we could sample and CI flakes we could not reproduce locally.
- **Our own permission engine.** A shell parser and path canonicalizer re-deciding what Claude Code already
  decides. Each verification round found another bypass class; the surface never ended.
- **Heavy gates on everything.** Goal files, verdicts, lifecycle events and independent verifiers applied to
  every change, including two-line test fixes.
- **Building on an unproven base.** Each layer was added before the one below it was boringly reliable.
- **Tackling everything at once.** Concurrency, many projects and proof were designed before one thread
  worked. This plan is the answer to that one.

## Design decisions

Status: **proposed** until we agree; **decided** once written into the phase that uses it.

| # | Decision | Proposal | Alternative | Decide in |
|---|---|---|---|---|
| D0 | Scope | One project, one active thread, sequential. Concurrency after the "well" gate above | Design for N threads now (rejected: it is what sank the first attempt) | decided |
| D1 | Language and runtime | Swift package: `WorkbenchCore` + `workbench` CLI, SwiftUI app in P3 | TypeScript or Python with the Claude Agent SDK handling the subprocess | **decided**: Swift holds (P1 soak) |
| D2 | Permissions | `claude -p --permission-prompts none --restricted` + one fixed `--tools`/`--allowedTools`/`--disallowedTools` set (never bare file tools) + budget; worktree is the boundary. Verified in [P1 spikes](P1-spikes.md) | Prompt per tool call over a control channel (rejected: needs the engine we removed) | P1 |
| D3 | Process model | **One process per turn.** First turn `--session-id`, every later spawn `--resume`, stdin `/dev/null`. Verified in S4 | One long-lived process per thread (rejected: idle eviction, queueing, resume races) | P1 |
| D4 | Goal format | Markdown with YAML front matter, see [`spec/goal-file.md`](../spec/goal-file.md) | JSON (worse to write and review by hand) | P1 |
| D5 | Event log | JSON lines, append-only, see [`spec/event-log.md`](../spec/event-log.md) | SQLite (heavier, harder to inspect) | P1 |
| D6 | Where data lives | Everything under the repo's `.workbench/` (gitignored): `threads/<id>/`, `worktrees/<id>/`, `config.toml`. One project means no global store | `~/Library/Application Support/` (needed again once there are many projects) | P1 |

### D1 gate: passed

The P1 soak was the gate, and it held: 500 fake runs and 10 real runs with no hang, no leftover process, no
leaked descriptor. Two things were found and fixed on the way, both by the tests that exist to find them:
a hang in the exit watcher (it trusted a single kqueue event; about 3 full test runs in 8 hung before the
fix) and an orphan sweep that missed a tool child. The Agent SDK sidecar stays the fallback if the soak ever
shows a hang again, not the plan.

What the process layer now is: one spawn function (`posix_spawn`, `CLOEXEC_DEFAULT`), one exit watcher
that polls behind the event, one runner that always ends a turn. About 700 lines, tested with a fake that
can hang, crash, ignore SIGTERM and leave children in other process groups.

## How we work on this

- **One slice per PR**, each ending in something runnable.
- **CI is build + tests + the soak test.** No goal/verdict ceremony. A short checklist in the PR is enough.
- **Independent review is for risk, not for everything.** Use it on the process layer. Skip it for UI copy
  and docs.
- **Reliability tests are first-class.** Every phase lists the failure cases it must survive.
- **If a feature needs the word "concurrent", it goes in `later/`.**

## Glossary

- **Goal**: the approved task description and criteria for a thread.
- **Thread**: a goal, a worktree, a Claude session and an event log. Exactly one is active.
- **Turn**: one `claude` process run: a prompt in, a stream of events out, exit.
- **Run result**: the terminal record of a turn (`succeeded`, `failed`, `stopped`, `timed_out`,
  `budget_exceeded`, `interrupted`).
- **Check**: the project's own command (tests, lint), run by Workbench after a turn.
