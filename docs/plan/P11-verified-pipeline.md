# P11: A pipeline that proves the change before it opens the pull request

Status: plan, nothing built. Written 2026-10-17. Replaces an earlier draft of this file ("ship first, then
verify"). Builds on [P2.5](P2.5-ship.md) (`ship`, `pr-shots`), [P4](P4-verify.md) (verify, the judge),
[P5](P5-review-loop.md) (`ship --review-loop`), [P6](P6-review-stages.md) (review stages) and
[P10](P10-skill-verifier.md) (a verifier that runs the project's skill). Friction rows 57 and the stale-proof gap
below.

## Why

Today the owner runs the steps by hand and in a fixed order that does not fit the work: `ship` after `accept`,
review after `ship`, the judge when asked, and nothing that says a screenshot belongs to the code now in the pull
request. Three things came out of the expense-tracker pilot (PR #150) and the discussion that followed:

1. A proof is taken once, before the PR exists, and nothing ties it to a commit. The log shows `proof.added` at
   08:54 and `pr.opened` at 09:06 with the same head sha, so that PR was right, but a commit in between would
   have published the old screenshot under the new head.
2. A failed verify only records a failure. It does not go back to the model.
3. Several fixes after review each change the code, and the screenshots in the description describe the first one.

## The loop

```
goal (write, check, approve)
  -> run         coding turn
  -> check       the project's check; failing goes back to the model (today's behaviour)
  -> verify      the app is driven to the states the criteria name; PNGs recorded with the commit
  -> judge       reads the proof against the criteria; "not met" with evidence goes back to the model
  -> design      read-only review of the diff and the proof against the project's design guide
  -> ship        push, open the PR, publish the proof (only a proof taken at this head)
  -> pr-review   read-only Codex review of the PR (bugs, invariants)
  -> final verify, at the head the PR ends on
  -> the owner reads the PR and merges
```

Any `FIX` or "not met" starts a follow-up turn (P5's mechanism: the finding is the request, the project's check
is the criteria). After it is pushed the loop returns to **check**, so every fix is re-checked and re-verified
before anything else sees it. A cap on rounds and on spend ends the loop and says what is still open.

## Decisions

1. **Verify, judge and design run before the PR.** For a project whose app starts in seconds (a Mac app, a mocked
   web app) proving the change early is cheap, and a change that does not show its criteria never becomes a PR.
   `pr-review` needs the PR, so it is the only stage after `ship`.
2. **A proof belongs to a commit.** `proof.added`, `verify.started` and `verifier.started` record the head commit
   they ran at. A proof whose commit is not the thread's head is *stale*: `review` says so, the judge and design
   stage refuse to read it, and `ship` / the publish step refuse to publish it. Nothing re-takes it silently; the
   loop re-runs verify.
3. **A failed verify goes back to the model.** The verify step's result, its log and which criteria's screenshots
   are missing become a follow-up request. A criterion with a `proof: screenshot: <name>` and no file at the head
   is "missing", never "met" (P4).
4. **The judge becomes a gate in the loop, nowhere else.** It still runs read-only, with the same JSON and the same
   rule (not met only for an evidenced violation of the literal text; doubt goes in `concerns`). In the loop a
   `met: false` with evidence starts a follow-up turn; `concerns` are shown and never act. A judge that fails to run
   or answers badly is a note, not a stop. Outside the loop `workbench judge` is unchanged and advisory.
5. **Design reads proof, so it runs after verify.** It is P6's reviewer kind with `applies_to` and the project's
   `docs/DESIGN.md`, run against the thread's checkout and diff (never `gh pr diff`, there is no PR yet).
6. **A final verify at the PR's head.** After `pr-review`'s last fix is pushed the loop has already re-verified
   (decision 2's return to check), so the final verify is a rule, not a step: the PR's description may only carry
   a proof at the head it ends on. `ship --status` (and `review`) print "proof at head: yes / stale".
7. **The loop is one command.** `ship --review-loop` (P5) grows into the whole pipeline when `[pipeline]` is set;
   without it, today's behaviour. The individual commands (`verify`, `judge`, `review-stage`, `pr-review`) stay.
8. **Providers.** The verifier and judge run on Claude, the stages on Codex; P9 decides the rest.

## Config

```toml
[pipeline]
before_ship = ["verify", "judge", "design"]   # in this order; each starts when the previous is CLEAN or skipped
after_ship  = ["pr-review"]
max_rounds  = 3                               # follow-up turns for the whole pipeline, per thread tree
max_cost_usd = 5.00                           # everything after the first turn

[review.stage.design]                         # P6, unchanged
skill = ".agents/skills/design-review/SKILL.md"
inputs = ["diff", "goal", "proof", "docs/DESIGN.md"]
applies_to = ["Sources/Triage/**", "Resources/**"]

[verifier]                                    # P10, unchanged; without it "verify" is verify_command
skill = ".claude/skills/verify/SKILL.md"
tools = ["Read", "Bash(scripts/verify-app.sh:*)", "Bash(scripts/snap.sh:*)", "Bash(swift scripts/ax.swift:*)"]
```

- Names are `verify`, `judge`, or a stage in `[review.stage.*]` (P6). Anything else is refused at config load.
- `design` before `verify` in the list is refused (it reads `proof`). `pr-review` in `before_ship` is refused (it
  needs the PR), and so is `verify` in `after_ship` (the loop returns to check and verify after a fix anyway).
- `max_rounds` counts follow-up turns over the whole thread tree (by `root`), as P6 counts stage rounds.
- No `[pipeline]` table means today's behaviour.
- **Every step is optional, none is assumed.** A step not listed does not run and leaves no event. A listed step
  that does not apply (`applies_to` matches nothing, no screenshot criterion for verify) is recorded as `skipped`
  with the reason, never as `CLEAN`. A listed step with nothing configured behind it (`design` with no stage table,
  `verify` with neither `verify_command` nor `[verifier]`) is refused at config load. A UI-less project lists
  `before_ship = ["judge"]` or `[]`.
- **Nothing verified is said, not implied.** When every `before_ship` step ended `skipped` (or the list is empty),
  `review` and the PR body say "nothing was verified before ship" rather than reporting a clean pipeline.

## Rules

- All of P6's stage rules, P10's verifier rules and P4's verify rules hold. Every `*.started` has exactly one
  `*.ended`, on stop, timeout, crash and restart recovery.
- The loop is a state derived from the log, not a second copy: which step is next comes from the last events and
  the head commit. A restart resumes it or says why it cannot.
- Stopping (Ctrl-C) ends the running step and the loop, records why, and leaves the worktree as it is.
- `ship` before the loop's `before_ship` is clean is refused with the step that is open, unless `--force-ship`
  names it (recorded). The PR is never merged.
- A stage never edits the PR description. Only `ship` and the publish function do, through `pr-shots`.

## What changes in the code

| Where | Change |
|---|---|
| Events (`docs/spec/event-log.md`) | `commit` on `proof.added`, `verify.started`, `verifier.started`; `pipeline.started`, `pipeline.step`, `pipeline.ended` with `reason` (clean, round cap, cost cap, stopped, failed) |
| Proof | `ProofSet.head(commit:)` and a stale check used by `review`, judge, design and publish |
| `Verify` | a failed or missing-criterion result builds a follow-up request; no change to `verify_command` |
| `Judge` | `--gate` returns the not-met criteria with evidence as the follow-up request |
| `Ship/ShipScreenshots.swift` | `PRProof.publish(number:, worktree:)`: refuses a stale proof, no PNGs means no edit, a failure is a note |
| `Config` | `[pipeline]` and its refusals; `doctor` prints the order and the budget |
| Loop | `PipelineRunner` walks `before_ship`, calls `ship`, walks `after_ship`, returns to check after each fix, enforces the caps |
| `review`, `--json` | proof at head, the pipeline's last step and round count; keys added never renamed |

## Tasks

Each task is its own PR, in this order.

| Task | Result | Gate |
|---|---|---|
| 1. Proof knows its commit | the `commit` field, the stale check, `review` prints it; `ship` refuses a stale proof | tests: commit after verify then ship; proof at head; no commit recorded in an old log reads as "unknown", not stale |
| 2. Failed verify goes back | a verify failure or a missing named screenshot becomes a follow-up request | tests with the fake claude and a verify script that fails, passes, and leaves no file |
| 3. P10 verifier (config, doctor, turn) | `[verifier]`, `workbench verifier`; P10 tasks 1 and 2 | P10's failure list |
| 4. Judge as a gate | `judge --gate`; not met with evidence becomes a request, concerns do not | a judge fixture for met, not met, concern only, bad JSON |
| 5. `PRProof.publish` | the publish step is a function of a PR number; `ship` uses it | the ship tests, publish twice, a failing tool, a stale proof |
| 6. `[pipeline]` and the runner | `before_ship`, `after_ship`, the return to check, the caps, resume after a restart | loop tests: each step's FIX, skipped, round cap, cost cap, stop mid-step, crash between steps |
| 7. Triage setup | `verify-app.sh`, the `/verify` Workbench section (P10 task 4), `[pipeline]` in Triage's config, `docs/DESIGN.md` inputs | `doctor` clean in Triage; a recorded dry run |
| 8. The pilot | one small Triage feature through the whole loop | a PR, below |
| 9. Compare | the same goal five times with the recipe files and with the pipeline: cost, time, rounds, how often the screenshot shows the state | numbers in this file |

## Failure cases to test

Everything in P10's list, and: a commit lands after verify and before ship; the head moves while the judge runs
(its verdict is for the old head and says so); verify passes and the judge says not met; design is skipped
because no path matches; `pr-review` finds something and the fix changes the UI (re-verify, re-publish, the
description shows only the latest proof); the round cap and the cost cap each end the loop with their reason;
`pr-shots` missing or failing (the PR is open, the note says the description has no screenshots); a restart in
every state between two steps; two pipelines on one thread (`busy`).

## The pilot: a simple feature in Triage

Success is the PR: opened by the loop with one clean pass of verify, judge and design before it existed, a proof
at the PR's head in the description, `pr-review` clean or its findings listed, the log showing every step, and
the cost and time written here.

Candidate: **order sections by creation date, the owner's own items first.** It is small, visible in one
screenshot and has a unit-testable core. The goal as it would be written (the owner answers the questions):

> Every section in Triage's middle list (Bot finding, CI failing, Merge conflict, ...) is ordered by
> `creation_date`, with the owner's own items first. (Plan: P11 task 8)

1. Within one section, items the owner created come before the others; inside each group the newest comes first.
2. The same holds in Everything and in each repository view. *(question 2)*
3. A unit test covers the order with equal dates and with no owned items.
4. `proof: screenshot: sections-ordered`: a section with owned and other items, showing the order.
5. The project's check passes.

Out of scope: how a section is grouped, the sidebar counts, snoozed items.

Questions before writing the goal: (1) "my user priority" is items the owner authored, or a priority the owner sets
per item? (2) middle list only, or Everything and the repository views too? (3) newest first within a group?

## Open questions

- **Cost of the loop.** Each round is a coding turn, the check, a verifier turn ($1), a judge ($0.50) and design.
  The cap defaults are guesses; task 9 measures them.
- **Does `judge` need its own model?** `--model` already picks a cheaper one; whether the gate should default to it
  is for task 4.
- **`accept`.** With the loop clean the owner's decision is the merge. `accept` stays as the recorded decision on a
  thread; whether `ship` requires it is left as today until the pilot says otherwise.
- **One PR or several.** A pipeline that finds a second problem unrelated to the goal does not widen it; it is a
  finding for a later goal (the scope rule in the README).
