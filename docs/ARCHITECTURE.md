# Architecture

How Workbench is put together and why. This is the short version a new reader (or an agent) needs before opening the
code; the formats are specified in [`spec/`](spec/), the rules for changing it are in [`../AGENTS.md`](../AGENTS.md), and
the reasoning behind each phase is in [`archive/`](archive/README.md) and [`plan/`](plan/README.md).

## The shape

```
 Workbench.app (SwiftUI)         workbench (CLI)
   Sources/WorkbenchApp            Sources/workbench
            \                       /
             WorkbenchCore  (Sources/WorkbenchCore)
   ┌────────────┬──────────────┬─────────────┬───────────────┐
   Thread       Process        EventLog      Agent           Task, Grant, Goal, Config, Git, Worktree
   (the loop)   (spawn, exit)  (the state)   (Claude, Codex) 
```

The app and the CLI are two front ends over one library and share no logic of their own: the app calls the same
`ThreadService` the CLI does. A change to behaviour belongs in `WorkbenchCore`, where it has tests that also run on Linux.

## A thread is the unit of work

A thread is a **goal** (a markdown file), a **worktree and branch** (the safety boundary), an optional agent
**session**, and an **event log**. Everything lives under the project's `.workbench/`, which is git-ignored:
`threads/<id>/` (goal, `events.jsonl`, transcripts, proof) and `worktrees/<id>/`. The id is validated by `SafeNames`
before it reaches a path or a git argument.

The loop, each step a command and a screen:

```
goal approved → worktree → setup → turn (agent) → check → verifier → judge → review stages
              → you: accept / send back / discard → ship (push, open PR) → PR review → clean
```

A failed step is sent back to the agent as the next turn and its fix starts again at the check. Workbench never merges.

## The event log is the state

`threads/<id>/events.jsonl` is append-only JSON lines with a gapless `seq`, written by one writer. The UI, `status`,
`review`, `next` and the feed are all derived from it (`ThreadState`, `ThreadSpine`, `FeedBuilder`); nothing keeps a second
copy. A crash is recovered by reading the log, not by trusting memory. The agent's own output is kept verbatim in
`transcript/turn-<n>.jsonl`, and the log keeps only a normalized `agent.activity` summary plus cost and refused calls on
`turn.ended`. Format and every event kind: [`spec/event-log.md`](spec/event-log.md).

## The process layer

This is where the first attempt (built inside Triage, then reverted) failed, so it is the most constrained part. Every
child, whether an agent, the project's check or the app being verified, goes through these rules
(`Sources/WorkbenchCore/Process`):

1. **One spawn function, `Spawner`.** `posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT`, stdin `/dev/null`, its own
   process group. A child can then never keep a descriptor it was not given (a long-lived agent once held the event log's
   lock for the whole run). Foundation's `Process`, `waitUntilExit` and `readDataToEndOfFile` are banned in `Sources/`
   (`scripts/check-banned-apis.sh`).
2. **One owner, one terminal event.** The runner owns a child from spawn to its end and always writes exactly one
   `turn.ended` per `turn.started`: on success, failure, stop, timeout, crash and after a restart (`recoverOrphanedTurn`).
3. **No blocking waits, and never one kqueue event.** Exit comes through `ChildExitWatcher`, which polls behind the event,
   peeks with `waitid(WNOWAIT)` before reaping and reports a vanished child as lost. The first version trusted the event
   alone and hung in about 3 of 8 full test runs.
4. **A tree sweep.** Tools the agent starts are not in its process group, so a group kill misses them. Workbench records
   descendants before escalating (SIGTERM, a 5 s wait, then SIGKILL) and sweeps orphans left in a worktree on startup.
5. **Everything is bounded:** line size, log size, output, timeout and budget.
6. **Tested against a fake.** `Sources/fake-claude` can hang, crash, ignore SIGTERM and leave children; the soak runs
   100 fake turns and CI fails on a hang or a leftover process.

Linux is first-class for the library and the CLI: `Process/Platform*.swift` is the one seam where macOS and Linux differ.

## Agents are providers

Goal drafting, chat, planning, coding, judging and review are separate **roles**, each configured in
`[agents.<role>]` with its own provider (Claude, Codex, or OpenCode through one OpenAI-compatible gateway, for the roles proven on it so far, coding included: `docs/plan/P28-opencode-provider.md`), model and effort. A provider adapter (`Sources/WorkbenchCore/Agent`)
turns a role's request into a CLI invocation and its output into normalized activity, over the same process layer; there is no
general workflow engine. Rules that hold across providers:
- **Native controls enforce the permission,** not a Workbench parser. A combination a provider cannot enforce fails
  explicitly; there is no silent fallback to a weaker policy.
- **Unknown cost is not zero.** A turn that reports none shows as unknown, and removing a hard dollar cap needs the goal's
  approval.
- **A judge or reviewer uses its own session,** never the one that wrote the code; using another vendor is optional.

## Safety model

- **The boundary is the worktree, an allowlist and a budget.** There are no prompts mid-run: approval happens once, on the
  goal, and a call outside the allowlist is denied, recorded and shown in the review (`workbench grant` turns it into a decision).
  `permissions = "auto"` lets the agent's own classifier decide inside the worktree.
- **The agent never holds credentials.** `ship` pushes and opens the PR, not the agent.
- **Untrusted text is validated before it reaches git or a path** (`SafeNames`, `Config` validation) and fenced when it goes
  into a prompt.
- **A person decides, once, at the right place.** For a thread, accept, send back, discard, ship and merge are yours, and Workbench
  never merges. A scheduled task is the one exception to "accept and ship": a `fix: pr` task you approved accepts its own work and
  opens a PR when its check and verifier pass ([`spec/tasks.md`](spec/tasks.md)); the approval is bound to the hash of the task file
  and its pending script, so an edited task must be approved again, and the PR is still yours to merge.

## Concurrency

A project allows `max_active_threads` active threads (default 3). Each has its own worktree and a stable port block for the run,
the check and the setup; checks are capped by `max_concurrent_checks`. There is no queue and no scheduler: a thread over the cap
is refused with a message. Shared-repo git calls are made safe to overlap, and every other piece of state is per thread.

## Where things live

| Looking for | Look in |
|---|---|
| The thread loop, review, ship | `Sources/WorkbenchCore/Thread/` (`ThreadService`, `ThreadRunner`, `Check/`, `Judge/`, `Verifier/`, `Review/`, `Ship/`, `PRReview/`) |
| Spawning and exit | `Sources/WorkbenchCore/Process/` |
| The log | `Sources/WorkbenchCore/EventLog/` |
| Providers | `Sources/WorkbenchCore/Agent/` |
| Goal file, goal editing | `Sources/WorkbenchCore/Goal/` |
| Scheduled tasks | `Sources/WorkbenchCore/Task/` |
| Config (`.workbench/config.toml`) | `Sources/WorkbenchCore/Config/` |
| The feed the app shows | `Sources/WorkbenchCore/Feed/`, then `Sources/WorkbenchApp/Feed*` |
| CLI commands | `Sources/workbench/Commands*.swift` |
| Visual rules for the app | [`DESIGN.md`](DESIGN.md) |

## What was learned first

Building this inside Triage produced about 5.6k lines and then a revert. The causes shaped everything above: a fragile process
layer (a long-lived agent with a stdin channel, drain queues and `waitUntilExit`); our own permission engine re-deciding what the
agent already decides, where each review found another bypass; heavy gates applied to every change; layers added before the one
below was boringly reliable; and concurrency, many projects and proof designed before one thread worked. So: small slices that
end in something you can run, reliability tests as acceptance criteria, and a feature waits in [`later/`](later/README.md)
until the one before it is used daily.
