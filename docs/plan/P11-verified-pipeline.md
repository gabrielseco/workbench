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

## Phase 0: a manual pass, and what it found

Before writing the runner, the loop was run by hand with today's commands on a real Triage task: *Everything is
ordered with the viewer's own pull requests first, newest created first* (Triage PR #71, 2026-10-17). Commands, in
order: `goal new`, `goal approve`, `run`, `review`, `judge`, `review-stage design`, `accept`, `ship`,
`review-stage design`, `pr-review`. Numbers: the turn took 85 s and $0.37, the check 12 s, verify 35 s, the judge
$0.10. The judge, the design stage and `pr-review` all answered met / CLEAN, and the PR description carried the
screenshot, the criteria table and the check result. So the steps work; what drifted from the plan is the joins.

| # | What the plan assumed | What happened | Fix |
|---|---|---|---|
| 1 | The design stage runs before `ship` | `review-stage design` before `ship`: "refused: this thread has no recorded pull request. Run `workbench ship` first". It only runs on a PR | Stages take the thread's branch and worktree when there is no PR (friction row 61 is the same gap for `pr-review`) |
| 2 | A proof belongs to a commit | `proof.added` has name, path, bytes and sha256, no commit. `pr-shots` names the file by the branch head *when it publishes* (`...-972aa0f.png`), not when it was taken | Record the head when the proof is taken; publish refuses a proof whose commit is not the head (task 1) |
| 3 | Something says which step is next | Nine commands, each with its output read by hand, and nothing says which comes next except a hint after some | The lifecycle document and `workbench next` (task 6); not a runner |
| 4 | A fix after the PR is re-verified | `ship` removes the worktree once the PR is open (`--keep-worktree` keeps it), so a later verify needs a follow-up thread's own worktree | Say it in the document: a fix is always a follow-up thread; `--keep-worktree` is not needed |
| 5 | The judge catches a proof that does not show the criterion | It answered `met` on all five, and wrote as concerns that the screenshot shows only the viewer's own PRs, so the order of the others' is never seen, and that no test covers `visibleItems` using the order. The design stage said the same. A gate on `met: false` would never have fired | Not gated: a partial proof is for the person to see. The judge's concerns go into the PR description (task 0.3) |
| 6 | The screenshot can show an ordering | It was the owner's live data, a window clipped at the sidebar, and it cannot show a boundary between own and others' PRs | Triage side: a fixture state for verify (a fixed list of PRs), and a second named screenshot per ordering goal |
| 7 | The design stage has a before and a minimum-size capture | It had one screenshot ("no before or minimum-size capture was supplied") | Triage side: the goal names the captures; the P6 pilot's dark and minimum-size shots are not in `verify.sh` |
| 8 | The model can run a narrow test | It was denied `sed -i ... && swift test --filter ...`: the allowlist is per command and a compound is refused. It went on with the full check | Minor: say in `doctor` that a compound command is refused; Triage can allow the two commands separately |
| 9 | A verify run is silent | Building the app for verify makes macOS ask about the Keychain. `verify.sh` gives the build its own bundle id (`dev.rogal.triage.verify`) so it never touches the installed app, and the items the app reads (GitLab, Linear, Anthropic) belong to the installed app, so each is asked again for the new id. The script signs with "Triage Local Signing" so the answer can stick, but `security find-identity -p codesigning` lists it as `CSSMERR_TP_NOT_TRUSTED` with 0 valid identities. **Confirmed 2026-10-17: it is the GitLab token** (`dev.rogal.triage.gitlab`). `verify.sh` copied `gitlabHost` from the installed app, so the build fetched GitLab and read the token; the dialog also blocked the first refresh, so the screenshot showed "No open PRs yet". The untrusted certificate was not the cause | **Done in Triage #72:** `gitlabHost` is no longer copied; `VERIFY_GITLAB=1` keeps it for a goal about GitLab. Not checked: Linear and Anthropic items (the build does not read them). A run that waits on a dialog is a hang, so a fixture mode that reads no secret is still the long-term answer |
| 10 | The screenshot is readable | The proof is the window as it opens: 2000 × 1304 px, about the app's minimum (`frame(minWidth: 1000, minHeight: 600)`). The sidebar labels are cut ("ng", "equest..."), the detail pane runs off the right edge, and only four items fit. `verify.sh` and `snap.sh` capture the window with `screencapture -l` and never set its size | Triage side: `verify.sh` sets the window to a fixed larger size (for example 1440 × 900) before the first capture, and the goal can name a second capture at the minimum size for the design stage. **Window size done in Triage #72** (`ax.swift resize`, `VERIFY_WINDOW_SIZE`, default 1440x900; the screen clamped the height to 851, the sidebar and detail pane are whole and the list loads). Workbench side: the judge and design reviewer are told the image's pixel size, so a clipped capture is named in their concerns |
| 11 | A review of the change catches what the proof cannot | Codex's `$pr-review` of Triage #72 found that the new `resize` verb, without `TRIAGE_PID`, fell back to the *installed* app and would have resized it. The judge and the screenshot could not show it: the run always passed the PID | Fixed in #72 (a guard before the app is chosen; the first attempt sat after the lookup and passed its test for the wrong reason). A script verb that drives the app must refuse a missing PID. It is also a reason to keep `pr-review` after the proof, not instead of it |

### What a partial proof is

The judge says a criterion is `met` when the evidence it was given shows the criterion's literal text holds. A
**partial proof** is evidence that is true but does not cover the whole criterion. On Triage PR #71 the criterion was
"Everything lists the viewer's own pull requests before the others', newest created first in each group". The
screenshot showed four PRs, all the viewer's, in descending number. What it shows is correct, and the first half is
visible. The half that matters, own PRs *then* others', is never on screen, and the creation dates are not either,
only inferred from the numbers. The judge said `met` and, in its concerns, said exactly that. The design stage and
`pr-review` noticed the same and passed it too.

Why it matters to the loop: a `met: false` gate only fires on a violation, and a partial proof is not one. It would
pass every round while nothing shows the ordering. The same happens with a test that exists but never reaches the
code (the judge's second concern: no test calls `visibleItems`).

How the plan treats it (task 0.3): **it does not gate.** A partial proof is evidence the person can still use, and the
owner reads the PR before merging, with the screenshot, the criteria and the concerns in front of them. A rule that
sent every incomplete capture back to the model would add a round, a cost and a judgement ("is this clause shown?")
the judge is not good at, to protect a step the owner does anyway. So:

- The judge's `concerns` are printed in `review` as today **and written into the PR description** under the criteria
  table (a short "Judge concerns" list, bounded), so what the judge doubted is on the page the owner reads.
- The loop's rule stays one-sided: only `met: false` with evidence starts a follow-up turn.
- The proof's size is still given to the judge and the design reviewer (row 10), so a clipped capture is named as a
  concern, not left for the owner to notice.
- Revisit only if the pilot's owner reads show a partial proof was missed in the PR: then a `proof_complete` field is
  the next step, not the first.

## Phase 0 tasks

The loop is not built before these join problems are fixed, each its own PR:

| Task | Result | Gate |
|---|---|---|
| 0.1 Proof knows its commit (row 2) **(built, #114)** | the commit and tree on the verify step's start (removed since, P10) and `proof.added`; `ship` skips the screenshots when the committed tree is not the proof's, or when the pull request's branch on `origin` is not this thread's head; `review` says current, stale or unknown | tests: commit after verify then ship, proof at head, a moved PR branch, an old log reads "unknown", a worktree filter is not run |
| 0.2 Stages without a PR (row 1) | `review-stage <name>` and `pr-review` run on the thread's branch when no PR is recorded, in the same throwaway checkout. **Done:** such a round is counted under `pr` 0, reads the local branch tip and diffs against the recorded base commit | the existing stage tests plus a thread with no `pr.opened` |
| 0.3 Judge concerns reach the PR (row 5) | the judge's `concerns` (and the proof's pixel size, row 10) are given to it and written, bounded, into the PR description under the criteria | `ship` fixtures: with concerns, without, over the limit |
| 0.4 Triage fixture state (rows 6, 7, 9 and 10) | `verify.sh` can launch with a fixed PR list, no Keychain read and a fixed window size, and the goal names more than one capture | a recorded run with the ordering visible across the own/others boundary and no Keychain dialog and a window no part of which is cut. **Done:** window size and the Keychain prompt in Triage #72; the fixed PR list is shown in the recorded run, so the task counts as done |
| 0.5 Repeatable goals **(built, #118)** | `goal new <name>` appends a random suffix (`<name>-<4 hex>`, from an injectable generator) when the thread id or the branch `workbench/<id>` already exists, retrying on a clash, and prints the id it chose; the first run keeps the plain name and the id passes `SafeNames`; `goal new <name> --from <goal-file>` copies the file's request, criteria and out of scope into a new draft (never its status, hash or id), so one goal can be run many times and compared (task 9) | tests: the same name twice in one day, a leftover branch (the generator is made to clash once, then the retry takes a free suffix), `--from` with a missing file, a file with no criteria, and a goal already approved elsewhere (comes in as a draft) |

Rows 3, 4 and 8 are covered by the runner and by notes in `doctor`. Task 0.5 is not a row: it came from closing
Triage PR #71 so the same goal could run again (`goal new` refuses a repeated name on the same day).

## Direction: a lifecycle document, not a runner

Decided 2026-10-17, after the manual pass. The loop is a sequence, and a person (or Claude, or the UI) can walk it
by reading a list. Building a runner that decides, retries, resumes and enforces caps was machinery for a problem
that does not exist yet, and "skip design when the project has none" is a sentence in a document, not code
(`review-stage` already exits 0 as skipped when `applies_to` matches nothing).

So, in place of task 6:

- **A lifecycle document** (a skill, `deliver`'s sibling, and the same list in the app): the steps in order (goal, run,
  check, verify, judge, design, ship, `pr-review`, merge), the command for each, what its result means, what to do on
  a failure (a follow-up turn, as P5 does), and when to skip. A cap is a sentence too: after three rounds, stop and ask.
- **`workbench next [id]`**, read-only: reads the log and the head commit and prints the next step and why ("judge:
  verify passed at 972aa0f and no judge has run for it"). The skill and the UI ask it, so they agree. It runs nothing.
- The log stays the state, so a stop, a crash or a hand-run command needs no resume logic: ask `next` again.

What is given up: nothing stops a model from skipping a step (`next` shows it), and there is no cap across steps
(only `pr-review`'s `max_rounds` and each turn's budget). Both are accepted until the pilot shows they matter.

What this changes below: the `[pipeline]` config and `PipelineRunner` (task 6) become `next` and the document; tasks
2 and 4 (a failed verify and the judge going back to the model) become steps in the document that use today's
follow-up mechanism; phase 0 is unchanged, because those are joins a document cannot fix.

## Decisions

1. **Verify, judge and design run before the PR.** For a project whose app starts in seconds (a Mac app, a mocked
   web app) proving the change early is cheap, and a change that does not show its criteria never becomes a PR.
   `pr-review` needs the PR, so it is the only stage after `ship`.
2. **A proof belongs to a commit.** `proof.added` and `verifier.started` record the head commit
   they ran at. A proof whose commit is not the thread's head is *stale*: `review` says so, the judge and design
   stage refuse to read it, and `ship` / the publish step refuse to publish it. Nothing re-takes it silently; the
   loop re-runs verify.
   *Built as:* stale is decided by the **tree** (everything in the worktree, committed or not), not the commit, so
   an amend or a rebase that keeps the content does not discard a screenshot; the commit is recorded for the reader.
   `pr-shots` names its file by the branch head when it publishes, which the freshness check has just shown holds the
   same tree, so it is not given the commit.
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

[verifier]                                    # P10; it is the `verify` step; `verify_command` is gone
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
  `verify` with `[verifier] enabled = false`) is refused at config load. A UI-less project lists
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
| Events (`docs/spec/event-log.md`) | `commit` on `proof.added`, `verifier.started`; `pipeline.started`, `pipeline.step`, `pipeline.ended` with `reason` (clean, round cap, cost cap, stopped, failed) |
| Proof | `ProofSet.head(commit:)` and a stale check used by `review`, judge, design and publish |
| `Verify` | a failed or missing-criterion result builds a follow-up request; runs the verifier ([P10](P10-skill-verifier.md)); `verify_command` is removed in P10 PR 6 |
| `Judge` | `--gate` returns the not-met criteria with evidence as the follow-up request |
| `Ship/ShipScreenshots.swift` | `PRProof.publish(number:, worktree:)`: refuses a stale proof, no PNGs means no edit, a failure is a note |
| `Config` | `[pipeline]` and its refusals; `doctor` prints the order and the budget |
| Loop | `PipelineRunner` walks `before_ship`, calls `ship`, walks `after_ship`, returns to check after each fix, enforces the caps |
| `review`, `--json` | proof at head, the pipeline's last step and round count; keys added never renamed |

## Tasks

Each task is its own PR, in this order.

| Task | Result | Gate |
|---|---|---|
| 1. Proof knows its commit (phase 0.1) | the `commit` field, the stale check, `review` prints it; `ship` refuses a stale proof | tests: commit after verify then ship; proof at head; no commit recorded in an old log reads as "unknown", not stale |
| 2. Failed verify goes back | a verify failure or a missing named screenshot becomes a follow-up request | tests with the fake claude and a verify script that fails, passes, and leaves no file |
| 3. P10 verifier (config, doctor, turn) | `[verifier]`, `workbench verifier`; P10 tasks 1 and 2 | P10's failure list |
| 4. Judge as a gate | `judge --gate`; not met with evidence becomes a request, concerns do not | a judge fixture for met, not met, concern only, bad JSON |
| 5. `PRProof.publish` | the publish step is a function of a PR number; `ship` uses it | the ship tests, publish twice, a failing tool, a stale proof |
| 6. Lifecycle document and `workbench next` (replaces the runner) **(`next` built: judge, stages, accept, ship)** | the document, and a read-only `next` that derives the next step from the log and the head | `next` fixtures: each step due, skipped, done at an older head, a stopped turn, a thread with no `[review]` stages |
| 7. Triage setup | `verify-app.sh`, the `/verify` Workbench section (P10 task 4), `[pipeline]` in Triage's config, `docs/DESIGN.md` inputs | `doctor` clean in Triage; a recorded dry run |
| 8. The pilot | one small Triage feature through the whole loop | a PR, below |
| 9. Compare (uses 0.5) | the same goal five times with the recipe files and with the pipeline: cost, time, rounds, how often the screenshot shows the state | numbers in this file |

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
