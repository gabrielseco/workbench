# Plan

**Do one thing well: one project, one thread at a time.** Concurrency, many projects, proof and Triage
integration all come later, and only after the single-thread loop is boringly reliable.

The thing we are building:

```
you write a goal → you approve it → agent works in a worktree → you see diff + checks → accept / send back / discard
```

Phases, in order. Each ends with a demo you can run, not just merged code.

| Phase | Name | Outcome | Size |
|---|---|---|---|
| [P1](P1-runner.md) | Runner | `workbench run` runs Claude on an approved goal in a worktree, logs everything, always ends cleanly | M |
| [P2](P2-review.md) | Review | `workbench review` shows diff and check results; accept, send back, discard | S |
| [P2.5](P2.5-ship.md) | Ship | `workbench ship` pushes an accepted thread and opens its PR; Claude never holds credentials | S |
| [P2.6](P2.6-harden.md) | Harden | `setup_command`, a `status` that says working or stuck, thread ids on `status` and `log`; the probe's fixes | S |
| [P2.7](P2.7-pr-sections.md) | PR sections | `ship` fills the template's Why from the goal and What changed from the diff, so no section is left empty | S |
| [P4](P4-verify.md) | Verify | (the `verify_command` of this phase was replaced by the P10 verifier) `verify_command` runs in the background and a thread ends with screenshots, a recorded result and an advisory verdict; piloted on expense-tracker, then Triage | M |
| [P5](P5-review-loop.md) | Review loop | `workbench pr-review` runs a second reviewer on the shipped PR; `ship --review-loop` feeds its findings back as turns until clean or a cap | S |
| [P6](P6-review-stages.md) | Review stages | a project declares its review stages and their order (`pr-review` is the default, design or migrations can follow) and the loop runs them in order; task 1 (config, `ReviewStage`, doctor) and task 2 (`review-stage <name>`, `proof`, `applies_to`) built | M |
| [P7](P7-judge-on-codex.md) | Judge on Codex (superseded) | unbuilt fixed-provider proposal replaced by P9; current judge remains on Claude | — |
| [P8](P8-faster-checks.md) | Faster checks | measure what a thread's check costs, map changed files to fewer suites, and run the check once where it counts | S |
| [P9](P9-agent-providers.md) | Agent providers | planned: independently select providers/models for optional goal drafting, run, judge and automated review; two providers per responsibility, shared contracts and recovery; required before P3 | M |
| [P10](P10-skill-verifier.md) | Skill verifier | planned: a verifier turn runs the project's own skill (read from the base commit, tools set by the project) to drive the app to the states a goal names and take the screenshots, instead of recipe files, with its own model and every screenshot reaching the judge and the design stage; it replaces `verify_command` and each project's `verify.sh`, and runs after a passing check by default; built, and `verify_command` is removed; six PRs (config, the turn, proof and review, the Triage side, the pilot and comparison, removing `verify_command`); Claude only, independent of P9 | L |
| [P11](P11-verified-pipeline.md) | Verified pipeline | planned: one loop (check, verify, judge, design, then `ship`, then `pr-review`) where a proof belongs to a commit, a failed step goes back to the model and any fix returns to check and verify; piloted on a small Triage feature | M |
| [P12](P12-pipeline-rough-edges.md) | Pipeline rough edges | planned: what a second sequential run of the P11 loop found in Workbench: `abandon` saves a worktree's changes then removes it, refusals that say what to do, a judge or stage result that knows its commit, a true `ship` preview; independent of P11's tasks | S |
| [P13](P13-grant.md) | Grant | planned: `workbench grant` turns a turn's denied commands into a per-command decision (once, thread, never) with a rules-based risk level, recorded in the log, so a run goes on without hand-editing `[tools]` | S |
| [P14](P14-plan-turn.md) | Plan turn | tasks 1 to 5 built (the verify-cli scenario has a recorded PASS and a recorded sabotage FAIL), the comparison planned: `workbench plan` runs a read-only turn on its own model against the approved goal and base commit, and the next `run` gets the plan in its first prompt, so a stronger model can decide and a cheaper one can code; a provider seam for P9 | M |
| [P15](P15-agent-ergonomics.md) | Agent ergonomics | `doctor` after approve, per-command help, a criterion backed by the named tests the check ran; typed proofs written down for later | S |
| [P16](P16-run.md) | Run | built: `[run]` declares how a project's app is started (a command and a ready check); Workbench starts it for the verifier, hands it the port and PID, and ends it with the turn, so the verifier no longer launches the app through its own helper; launch only, not `verify_command` back; piloted on Triage and expense-tracker | S |
| [P17](P17-faster-tests.md) | Faster tests | task 1 built (profile); the repo's own `swift test` from 178 s to about 60 s without weakening a test: measure per-test cost serially, clean fixtures, size the gate, fewer and parallel git calls in the commands the tests drive, shorter by-design waits, fewer CLI spawns | M |
| [P18](P18-linux.md) | Linux | built: the #221 probe shipped as small PRs so more PRs can run CI at once (portable crypto and zlib, a platform contract, the Linux implementation, orphan adopters instead of `ppid == 1`, a loopback ready check on sockets, a build cache and a 5 ms exit poll); PRs run lint and Linux (about 2m20s per job), macOS runs on `main` and nightly; no shards were needed | M |
| [P19](P19-swiftui-app.md) | SwiftUI app | planned: the window and menu bar from the mockups in [`../mac-app/`](../mac-app/), one slice per screen (goal, run, review, ship, menu bar) over a core-derived thread spine and an amber "needs you" rule; refines P3; starts after P9's gate | L |
| [P3](P3-app.md) | App | One window that does the whole loop without the terminal | M |

**P3 starts only after P9's acceptance gate passes.** P9 replaces P7 rather than adding a second,
conflicting provider-selection design. P8 remains independent check-performance work.

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
| D2 | Permissions (current Claude adapter; generalized in P9) | `claude -p --permission-prompts none --restricted` + one fixed `--tools`/`--allowedTools`/`--disallowedTools` set (never bare file tools) + budget; worktree is the boundary. Verified in [P1 spikes](P1-spikes.md) | Prompt per tool call over a control channel (rejected: needs the engine we removed) | P1 |
| D3 | Process model | **One process per turn/attempt**, stdin `/dev/null`. Claude uses first-turn `--session-id` then `--resume` (S4); P9 makes native session support optional and provider-qualified | One long-lived process per thread (rejected: idle eviction, queueing, resume races) | P1 |
| D4 | Goal format | Markdown with YAML front matter, see [`spec/goal-file.md`](../spec/goal-file.md) | JSON (worse to write and review by hand) | P1 |
| D5 | Event log | JSON lines, append-only, see [`spec/event-log.md`](../spec/event-log.md) | SQLite (heavier, harder to inspect) | P1 |
| D6 | Where data lives | Everything under the repo's `.workbench/` (gitignored): `threads/<id>/`, `worktrees/<id>/`, `config.toml`. One project means no global store | `~/Library/Application Support/` (needed again once there are many projects) | P1 |

### Provider decisions (P9, proposed until implemented)

- **D7 — Responsibilities and providers:** goal drafting, run, judge and automated review own their prompts, policy,
  inputs and validators; adapters own CLI/protocol translation over the existing process layer. No
  general workflow engine. Same-provider evaluations use independent sessions; vendor diversity is optional.
- **D8 — Capability boundary:** native controls must enforce the requested permissions. Unsupported
  combinations fail explicitly; no silent provider fallback or weaker policy. Unknown cost is not zero,
  and removing a hard dollar cap requires explicit spending approval.
- **D9 — Compatibility:** retain Claude run/judge and Codex review defaults. Preserve historical logs
  and state transitions; add normalized activity and attempt recovery before the app depends on them.

[P9](P9-agent-providers.md) defines configuration, contracts, migration and the measurable gates. D2
remains the current Claude policy; P9 extends it through tested native provider controls, not a new
Workbench permission engine. Historical phase documents describe their original implementation.

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
- **Thread**: a goal, a worktree and an event log, with a coding session when supported (currently Claude). Exactly one is active.
- **Turn**: one coding execution: a prompt in, activity out, terminal result (currently a `claude` process).
- **Provider** (P9): the adapter for an agent CLI, independent of the responsibility it executes.
- **Review stage**: a named automated read-only review rubric from P6; distinct from the local `review` display and human decision.
- **Run result**: the terminal record of a turn (`succeeded`, `failed`, `stopped`, `timed_out`,
  `budget_exceeded`, `interrupted`).
- **Check**: the project's own command (tests, lint), run by Workbench after a turn.
