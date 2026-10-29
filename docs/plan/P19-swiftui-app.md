# P19: SwiftUI app

Status: plan, nothing built. Written 2026-10-27. Starts only after [P9](P9-agent-providers.md)'s acceptance gate passes (task 5
is open). Refines [P3](P3-app.md): the layout, the screens and the menu bar come from the mockups in
[`../mac-app/`](../mac-app/) (1 Goal, 2 Run, 3 Review, 4 Ship + PR review, 5 Menu bar), which replace P3's single column.
P3's acceptance criteria that still hold are carried over below. This document describes future behaviour; `docs/spec/`
still describes the shipped CLI.

**Outcome:** one macOS window, and a menu bar item, in which you write and approve a goal, watch the agent work, review the
result, ship it and read the PR review, without the terminal. The app reads the event log and calls `WorkbenchCore`; it
decides nothing the CLI would not.

```
Goal ──▶ Run ──▶ Review ──▶ Accept ──▶ Ship ──▶ PR review ──▶ Clean
 1        2        3                    4          4
                     └─ every screen is a view of the thread's log; the menu bar (5) is the same state, closed window
```

## Why now, and why this shape

The loop works in the terminal. The 20-real-tasks gate in the [README](README.md) needs a surface a person can use all day, and
the thing the terminal does worst is **telling you when Workbench is waiting for you**. Everything else (diff, checks,
criteria) is a rendering of state that already exists. So the plan is: one derive function for "where is this thread and does
it need me" in core, tested on Linux, and five thin screens over it. If a screen needs a decision the core cannot yet
make, the core change comes first as its own PR.

## The thread spine

The left rail of every window. It is the thread's state machine drawn as seven steps, read from the log by a pure function.

| Step | Done when | Current when | Sublabel (examples from the mockups) |
|---|---|---|---|
| Goal | a `goal.approved` matches the goal file's hash | no approved goal, or approval is stale | `Writing`, `Approved 14:02` |
| Run | the latest turn ended and nothing is open | a turn, check, setup or verifier is open, or the goal is approved with no turn | `Turn 1 · working`, `Turn 1 · $1.88`, `Turn 2 · $1.54 (send-back)` |
| Review | `review.decision` exists | a turn ended and there is no decision | `Needs you` |
| Accept | `review.decision: accepted` | (never current: it is the decision Review ends in) | `1 commit` |
| Ship | `pr.opened` | accepted, no PR | `PR #482 open` |
| PR review | latest round `clean` and the PR's checks pass | a PR is open | `1 finding open` |
| Clean | `branch.removed` or `worktree.removed` after merge | PR merged or closed | |

- **One function.** `ThreadSpine.derive(state:goal:pullRequest:)` in `WorkbenchCore`, next to `ThreadState`, pure, returning the
  seven steps with a mark (`done`, `current`, `needsYou`, `pending`, `failed`) and a sublabel. The app renders it and stores
  nothing. This is how P3's "UI state drifts from the log" risk is closed: the app has no second state machine.
- **`ThreadState` does not yet read the pull request** (`pr.opened` has a kind constant and nothing derives from it). Task 0
  adds `pullRequest` (number, url, head sha) to `ThreadState`, and, for CI, the latest known checks summary.
- Steps are never skipped or reordered. A discarded or abandoned thread shows Review as the last step with the decision.
- The footer chips are `Event log <n>` (the last `seq`, opens the raw log) and `Doctor <state>`.
- A follow-up thread from `ship --review-loop` shows its `lineage` (root, round) under the title; there is still one spine.

## The amber "needs you" rule

Colour has four meanings and no others. **Blue**: Workbench is working, or this is your current step. **Green**: done.
**Grey**: not yet. **Amber**: **the thread cannot go on until you decide, and you can decide now.** Red is for something broken
(a corrupt log, a provider that is not installed) and for destructive buttons; it is not "needs you".

`Attention.derive(spine:state:report:)` in core returns `none`, `working` or `needsYou(reason, since: seq)`. It is `needsYou`
exactly in these cases:

| Case | Reason shown | Why it is yours |
|---|---|---|
| A turn ended (any result: succeeded, failed, stopped, timed out, over budget, **interrupted**) and there is no decision | `Review · turn 2 done 4 min ago` | accept, send back or discard is a human call |
| The review lists a criterion only a person can verify, or one the judge says is not met | `C3 by hand` | the verifier cannot press the export menu; Workbench cannot close it |
| The PR's latest review round says `fix`, or a CI check failed | `1 finding open`, `CI failed: unit tests` | send it back, or reject the finding |
| The PR is open, CI is green and the latest round is `clean` | `Ready to merge` | Workbench never merges |
| A PR review round or `ship` ended `ok: false` | `Review round 2 failed: at capacity` | rerun or give up |

It is **never** amber for: a running turn, check, verifier or judge; a denied call during a run (the Run screen says "nothing
interrupts you here"; denials surface in Review); a draft goal (it is the user's own work in progress, blue and `Writing`);
CI that is still running; a quiet turn (the Run screen says `quiet for 4m`, which is information, not a request); a merged
PR waiting for `Clean` (housekeeping, grey badge, no notification). With one active thread the count is 0 or 1; the menu bar
keeps the numeral of the design because it costs nothing and survives the day the scope rule lifts.

`needsYou` carries the identity the notification de-duplicates on (task 5): the `seq` it began at for a state the log
records, and for the two CI-driven rows the pull request's head sha, since a GitHub check change writes no event. A relaunch
is not a new reason to interrupt anyone, and neither is the same commit's CI failing again after a rerun: one notification per
reason per commit, on purpose. A new commit is a new identity.

## What the app is made of

- **A `WorkbenchApp` SwiftUI executable target in this package**, macOS only. The Linux PR gate must still build, so the target
  is declared under `#if os(macOS)` in `Package.swift`. It links `WorkbenchCore`, which keeps the release-build flag
  workaround in `Package.swift` (SwiftPM refuses unsafe flags from a dependent package, so the app cannot live in its own).
- **One `@Observable` store** per window: opens the project, holds `[Event]` and the derived `ThreadState`, `ReviewReport`,
  `ThreadSpine` and `Attention`, and tails the log incrementally. It polls the log's size at 250 ms while a runner is live and
  2 s otherwise and re-derives on change; the poll is the design, FSEvents only if it shows up in a profile. **There is no
  `EventLogTail` (dropped 2026-10-28):** the poll `stat`s the log (size and mtime, plus the threads folder's mtime) and, only when
  something moved, re-reads the whole file with `EventLogReader` off the main actor, which also covers a log that shrank or was
  replaced (`workbench compact`). The largest log in this repo is 112 KB and the 58 of them total 823 KB, so a re-read costs about
  450 KB/s at the 250 ms poll; an incremental follower is one function in the store if a profile ever says otherwise. The store keeps the
  events it derived from, not the raw bytes. A run started in a terminal therefore appears in the app, and the
  other way round.
- **No process code in the app.** The app calls `ThreadRunner.run(RunOptions)` (it already takes a notice callback), `ThreadService`
  and `ReviewLoader`. Anything that today shells out inside the CLI target (`gh`, `git`, the ship sequence) is lifted into
  core first. The app target has no `Process`, `Subprocess`, `posix_spawn` or shell strings; `scripts/check-banned-apis.sh` is
  extended to `Sources/WorkbenchApp/` in task 0, and that edit is the only change to the script.
- **Runs live in the app's process.** Closing the window does not end a run: the app stays resident for the menu bar (the Run
  mockup says so). **Stop is `ThreadRunner.stop()` on the runner the app owns**, which records `stopped` itself. `requestStop(id:)` sends SIGTERM
  to the pid in `runner.json`, so it is used only for a run another process holds, and is never sent when that pid is the
  app's own (the CLI's SIGTERM handler lives in the CLI target; the app has none and installs none for its own runs).
  Quitting (⌘Q) with a live run asks, then calls `stop()` and waits up to 6 s for the recorded `stopped`; a crash or force quit leaves the turn for `recoverOrphanedTurn()` on the next open, which the app shows as
  `interrupted` and offers to run again. A run started elsewhere shows as running (`runnerPID`) and stops through the same call.
- **Ids and paths** come through `SafeNames` and `Project`; the repo picker validates a git repo before it is remembered. The one
  project is remembered in app preferences (not in `.workbench/`). "Open in editor" and "Open worktree" use `EditorLauncher`.

## Slices

One slice per PR (a slice that needs core work lands that first, as its own PR). Each ends in a demo run by hand on a real repo;
a real turn costs money, so the demo goals are small, with a stated budget. Every PR shows its screen next to the mockup.

### Task 0: Core first, then the shell and spine

**Core PR** (Linux-tested, no UI; `ThreadState.pullRequest`, `ThreadSpine` and `Attention` are built, with `workbench status` as their first consumer, see `docs/spec/cli-json.md`): `ThreadState.pullRequest`; `ThreadSpine`; `Attention`; fixtures of logs for each state of
the two tables above (`Tests/Fixtures/`, built with the same recorder the legacy fixtures use).
**App PR:** the target and its CI (below), window with toolbar (project pill, `base:`, state pill, spend meter), the spine, the
footer bar, repo picker, remembered repo, and the empty and error states (no project, not a git repo, no thread, log corrupt,
`.workbench/` missing).

- **Reads:** `Project`, `ThreadStore.activeThreadID/newestThreadID/state(of:)`, `ThreadState` (`lastTurn`, `openTurn`, `decision`,
  `totalCostUSD`/`knownCostUSD`, `lineage`, `agentUse`), `EventLogReader`; events `thread.created`, `goal.*`,
  `turn.*`, `review.decision`, `pr.opened`, `branch.removed`, `worktree.removed`.
- **Doctor chip** runs `Doctor.run(base:)` **on click only** and reads `Not run` at open: core stores no doctor result and doctor runs
  the project's own setup and check in a throwaway worktree, so its cost is the project's (1.0 s on this repo, unbounded on a project
  whose setup installs packages) and an automatic run at open could not be bounded.
- **CI:** a path-filtered macOS job for PRs that touch `Sources/WorkbenchApp/` (the PR gate otherwise runs lint and Linux only).
  The PR touches `Package.swift`, so it carries `release-build` ([AGENTS.md](../../AGENTS.md#shipping-a-change)).
- **Demo:** open this repo; pick it from a clean install; the spine for a recorded thread of each state matches the fixtures;
  relaunch and nothing changed; point it at a non-git folder and a corrupt log and each says what to do.

### Task 1: Goal (mockup 1)

**Core first** only if the "checkable" check has no public entry point: the app needs the per-criterion answer behind the
`--allow-unrunnable-proofs` refusal (`Goal/ProofCommands.swift`, `ScreenshotProof`, `TestProof`), as data, not as text. Confirm at
the start of the slice.

- **Shows:** title, `goal.md` path, Request, Criteria (id, text, proof chip), `N of M checkable`, Out of scope, the `Heads up`
  note for a criterion whose proof Workbench cannot run (the verifier-cannot-press-a-menu case), Run limits (model, budget or
  `no dollar cap: bounded by N min per turn`, turn timeout), Allowed tools (`[tools] allowed` plus the thread's grants), the
  `Draft · not approved` / `Approved` / `Changed since approval` pill, `Nothing runs until you approve.`
- **Reads:** `GoalFile`, `Goal`, `GoalBody`/`Criterion`, `GoalProblem`, `ApprovalState`, `Config` (`agents.run`, `[tools]`,
  `turn_timeout_min`), `GrantLedger`, `AgentUse`/`ApprovedAgent`, `DoctorReport`; events `goal.saved`, `goal.approved`
  (`hash`, `budget_usd`, `spend_policy`, `provider`, `model`), `goal.draft.started/finished`.
- **Does:** `ThreadService.newThread` (the template), `Open in editor` (`EditorLauncher`), re-read the file when it changes (same
  poll), `ThreadService.approve`, then `ThreadRunner.run` for **Approve and run**. Approve and run is two operations in order,
  never one: a failed approve starts nothing.
- **The goal is not edited in the app.** The file is the source of truth and the editor is the user's own; the app validates and
  displays. The Run limits chips are read-only, with a pointer to the goal file. (A text editor in the window is the thing P3
  warned would become its own project.)
- **1b (built):** `New goal…` opens a sheet with one question, "What needs to be done?", and Create hands the text to
  `ThreadService.draftGoal` as a new thread. The thread name is made from the request's first line (editable under "Thread name"),
  so nothing but the request is asked for. The sheet stays open while the drafter works, with Stop; a draft that fails or is
  stopped writes nothing and the sheet keeps the text and says why. Without `[agents.goal]` the sheet offers "Draft with Claude / Codex":
  `GoalAgentSetup` appends the table to `.workbench/config.toml` (put back as it was if the config would not load; refused when
  the table exists, there is no config, or the file is over 256 KiB) and the draft runs. A quit waits for a running draft to end. The new thread opens as a draft, with `Open in editor` for changes.
  Screenshots (paste, drop or `Add screenshots…`, up to 5) go to the drafter and are kept in the thread's `attachments/`, linked from
  the goal's request; the coding run does not read them yet (Claude's turns are confined to the worktree: it needs its own design).
  The drafter's model is never shown as the coding model.
- **Failure states:** invalid goal (the `GoalProblem` text, Approve disabled), placeholders remain, provider executable missing or
  capability refused (`AgentFailure` text from core), goal changed after approval (pill and spine step go back, Run disabled),
  draft failed or stopped (the previous goal is untouched, said so).
- **Demo:** `New goal` → say what needs to be done → the drafted goal opens (edit it in the editor if needed) → the criteria turn checkable → approve → spine step is green
  with the time; edit the file after approving and watch it return to draft with Run disabled.

### Task 2: Run (mockup 2)

- **Shows:** `Turn n · started N min ago · isolated worktree`, the `Working` pill, the current-activity card (latest activity and
  elapsed), the event log with `All / Edits / Denied` filters, the Budget panel (`$1.12 of $8.00`, turn limit, a bar),
  `So far` (files changed, tests passing, denied calls), `Open worktree`, `Stop turn`, and the line "You can close the window."
- **Reads:** `ThreadState.progress` (`toolCalls`, `deniedCalls` and their `…Known` flags, `elapsed(now:)`, `quietFor`),
  `openTurn`, `openCheck`, `totalCostUSD`/`knownCostUSD`, `agentUse`, `approvedAgent`; events `turn.started`, `agent.activity`
  (`text`, `tool` with `name`/`summary`, `permission_denied` with `tool`, `usage`, `diagnostic`, `unknown`, `dropped`),
  `agent.attempt.*`, `check.started/ran` (`tests_passed`, `tests_failed`), `setup.ran`, `verifier.*`, `run.*`, `orphans.swept`,
  `turn.ended`; the turn's transcript file for the "Raw log" disclosure.
- **Does:** `ThreadRunner.run` (from task 1 or `Run again`), `ThreadRunner.stop()` for a run the app owns, `ThreadService.requestStop` for one a terminal holds; `send-back` is task 3.
- **What the mockup shows that the log does not carry, and what the app does instead:**
  - `+61 −8` on an edit line: shown only if the activity's `summary` has it; the app never parses the text for numbers.
  - The full command of a denied call: during the turn the log has the tool name only (`permission_denied.tool`); the command
    arrives on `turn.ended.denials`. Live rows say `denied Bash`, and the row fills in when the turn ends.
  - `Tests passing 9 / 9`: from `check.ran` after the turn; during the turn it is `not run yet`, not a guess.
  - A provider that streams no tool or denial events (Codex today): counts are `unknown`, never `0`; a provider with text only
    shows the text; a cost never reported is `unknown`, not `$0.00`. A `dropped` record is a visible gap row ("42 items not
    stored"), since a turn stores at most 1000 items.
- **Live list:** the poll (4 Hz while working) reads the log only when it changed; the list is lazy and holds the stored activity of
  the latest turn (core stores at most 1000 items), never a transcript file (the Raw log disclosure is a later addition).
- **Failure states:** setup failed (the thread has not started; says so), provider not found, run refused (`busy`, another
  holder), turn `failed` / `timed_out` / `budget_exceeded` / `interrupted` (the reason, then on to Review), stuck (`quiet for`).
- **Demo:** run a small goal; watch activity stream; deny one command and see it in the list; stop at the half-way point and see
  `stopped` and a usable window inside 6 s; start a second turn, quit the app mid-turn, relaunch: the turn reads "the runner is gone" (the app writes no log;
  `recoverOrphanedTurn` runs when a runner starts), log intact, `Run again` records `interrupted` and goes on.

### Task 3: Review (mockup 3)

**Core first:** the YOU column and "Checked by hand" (see Open decisions) need a way to record a person's mark on a criterion.
Recommendation: one new event kind, `criterion.reviewed` (`id`, `mark`: `agreed` or `by_hand`, `turn`), appended through a
`ThreadService` method that holds the log; the event log spec changes in the same PR and `review` prints the column, so a CLI
verify-cli scenario ships with it. Without it the YOU column is left out and "Checked by hand" is not a button.

- **Shows:** `Review · Turn 2 finished 4 min ago · 6 files · +184 −31`, the banner for a criterion that needs a person, the
  criteria table (id, text, proof, **Check** / **Judge** / **You**), Evidence thumbnails, Denied calls grouped with a count and
  the note that the run worked around them, Changed files with `+/−`, `1 of 4 assessed`.
  Buttons: `Discard`, `View diff`, `Send back…`, `Accept work`, `Open in editor`; spend meter in the toolbar.
- **Reads:** `ReviewLoader.load(id:)` → `ReviewReport` (`criterionStatuses`, `diff: DiffSummary`, `commits`, `branchTip`,
  `state.review`: `check`, `judge`, `verifier`, `notes`, `deniedTools` with `identity` for grouping, `fullInput`),
  `CriterionStatus` (`passed`, `failed`, `manual`, `evidence`, `missing` and `screenshots`), `JudgeVerdict` and its concerns,
  `Review.Verifier` and the `proof.added` files (`sha256`, `commit`, `tree`: a screenshot from before the latest change is
  marked stale, as core already decides), `ReviewLoader.patch(id:path:)` for View diff, `GrantLedger` and
  `ThreadService.grantCandidates` for "grant only if you want them next time".
- **Does:** `acceptPlan` then `accept` (and `discardPlan` then `discard`): the plan is shown in a confirmation, and the app
  passes it as `shown:` exactly as the CLI does, so what is confirmed is what runs. `Send back…` takes a note and an optional
  one-turn budget and calls `ThreadRunner.run(RunOptions(feedback:, budgetOverride:))`; the failed check's output goes in as the
  CLI sends it. `judge(…)` on demand (advisory). `grant(…)` per denied command with scope `once`, `thread` or `never`; an unsafe
  level needs the same explicit extra step as `--allow-dangerous`.
- **Rules the screen keeps:** a criterion is never shown as met because a row is green (`Check` and `Judge` are advisory, the
  judge's evidence is quoted, a `missing` screenshot is never met); Accept is enabled with undecided criteria, and says how many;
  a `stopped`, `timed_out`, `failed` or `interrupted` turn is reviewable with its partial work, as the log already allows.
- **Failure states:** worktree gone or diff unreadable (`Diff.unavailable(reason:)`), goal file invalid (criteria unknown, not
  empty), no check configured, no judge run, evidence files missing on disk, `accept` refused (nothing committed).
- **Demo:** the turn from task 2 ends; the review matches the log; send back with a note and see turn 2 start; grant one denied
  command for `once`; mark a criterion by hand; accept; the spine shows `1 commit` and the branch has it.

### Task 4: Ship and PR review (mockup 4)

**Core first (two PRs):**
1. **Lift the ship sequence into core.** Preflight, description, push, open PR, screenshots and the confirmation are orchestrated in
   `Sources/workbench/CommandsShip.swift`, which the app cannot link. Move it to `ThreadService` (`ship(id:options:)` returning the
   steps as it goes) and make the command a thin caller. Behaviour-preserving: the existing ship suites pass unchanged, and no
   CLI output or flag changes, so no verify-cli scenario is needed (say so in the PR).
2. **`ThreadService.prChecks(id:)`**: one `gh pr checks` read into `PRChecksSummary` (the parser exists; `watchPR` is a loop with
   a deadline and is not what a screen wants). The app polls it every 30 s while the Ship screen or an open PR is showing, and
   stops when the PR ends.

- **Shows:** `Pushed and opened N min ago. Workbench never merges for you.`, the PR card (title, `#number`, `branch → base`,
  `Open on GitHub`), CI checks (name, duration, state), `PR review · round r of max`, the findings text of the latest round and
  its verdict, `Waiting on you`, and the footer `Clean becomes available once the PR is merged.`
- **Reads:** `ShipPlan`/`ShipPreflight`, `PRChecksSummary`/`PRCheck`, `ReviewLoop.latestPRReview` and `PRReviewRecord`,
  `prReviewFindings`, `latestReviewStages` (each stage with its record), `ReviewConfig` (`max_rounds`, stages), `pullRequestBranchTip`
  and `ReviewReport.prReviewIsStale`; events `pr.described`, `pr.opened`, `pr.refreshed`, `proof.published`, `branch.ahead`,
  `pr_review.started/finished`, `review_stage.started/finished`, `worktree.removed`, `branch.removed`.
- **Does:** `ship` (with a confirmation, because it publishes), `prReview` / `reviewStage` (`Run round 2`), `ReviewLoop.startFollowUp`
  for **Fix findings** (the findings quoted, as core already does), `cleanMerged` for `Clean thread` (dry run first, shown, then
  confirmed). Never merge, never post review comments (posting is the user's call, as in `pr-review`).
- **Findings are text in v1.** The mockup's per-finding `Fixed / Rejected / Open`, `Verify` and `Reject with note` need a
  per-finding state the core does not have (a round is a markdown file and a `clean`/`fix` verdict). The screen shows the round's
  findings and verdict and offers Fix findings and Run round; per-finding triage is in [Out of scope](#out-of-scope).
- **Failure states:** push rejected, no `gh` or not authenticated, PR already open, branch moved since the review (`stale`,
  shown, round can be rerun), review at capacity or failed (`ok: false` with the reason; a failed round is never shown clean),
  max rounds reached, checks unreadable (unknown, not green), commits added after accept (`branch.ahead` note).
- **Demo:** on a throwaway repo and remote: accept, ship, watch CI go from running to green, run the review, see one finding,
  Fix findings starts the follow-up thread (its lineage shows), merge on GitHub, `Clean thread` removes the branch.

### Task 5: Menu bar (mockup 5)

- **Shows:** a status item with a count only while `Attention` is `needsYou`; the popover: project, `Needs you` pill, title,
  `Review · turn 2 done 4 min ago · $3.42 of $8.00`, the `Criteria assessed 1 of 4` row, the open-hands row (`C3 by hand · Open`),
  `Open review`, `Send back…`, `Event log`, `Pause notifications`, `Quit`.
- **Reads:** the same store as the window, so it cannot disagree with it: `Attention`, `ThreadSpine`, `ReviewReport`,
  `ThreadStore.threadWithLiveRunner`. Nothing new in core.
- **Does:** a local notification (UserNotifications) when `Attention` moves to `needsYou`; clicking it opens the window on that
  screen. De-duplicated on the `seq` in `needsYou(since:)`, so a relaunch, a wake from sleep or a second poll never repeats one.
  No notification for a state that was already `needsYou` when the app opened (the badge shows it, nothing pops). `Pause
  notifications` is an app preference, not workbench state. No sound.
- **Failure states:** notifications not permitted (the item still shows the count; the popover says so once), no project, a run
  the app lost track of (`runnerPID` gone, `interrupted` after recovery).
- **Demo:** start a run, close the window, do something else: the item stays quiet during the turn, the notification arrives
  when the turn ends, the popover matches the Review screen, Send back from the popover starts a turn, quit mid-turn stops it
  inside 6 s.

## Open decisions

1. **What is "the current thread" after accept?** The spine runs through Ship, PR review and Clean on one thread, but after
   `accept` the thread is no longer active in core (`isActive` is `decision == nil`), so core would allow a second thread while
   the first still has a PR in flight, and the app would lose the amber for it.
   **Decided (2026-10-28, from using the app):** the app's current thread is the active one, else the newest thread that is not
   cleaned. `New goal` is always offered on a decided thread; for accepted or shipped work a note names the branch and the terminal
   command (`workbench ship <id>`, `workbench clean`) that still reaches it, because the window has no thread list and `abandon`
   refuses a decided thread, so disabling the button would leave no way forward. A list is [later](../later/thread-list.md).
   (The earlier recommendation was to disable `New goal` until the thread was cleaned or abandoned.)
2. **Per-criterion hand marks (task 3's core change).** Without a recorded mark, the YOU column and `Checked by hand` cannot be
   built. Recommendation: the `criterion.reviewed` event above, with a `review` column and a verify-cli scenario. The
   alternative is to leave the column out of v1 and keep the amber `by hand` row.
3. **The "two strikes" banner.** The mockup counts verifier attempts on a criterion; the log records a verifier run per turn,
   not per criterion. Candidate rule: a screenshot proof that is `missing` after two verifier runs, or judged `not met` in two
   consecutive judged turns. Confirm against FRICTION before building; until then the banner shows only the `by hand` reason.
4. **Run lives in the app (stop on quit), or detached.** A detached `workbench run` would survive quitting, but means the app
   starts a process, which the rules forbid. Recommendation: in-process, as above.

## Out of scope

Deferred on purpose; each is in [`../later/`](../later/README.md) or named there, and the "well" gate in the
[README](README.md) still decides when any of it comes back.

- **A thread list, history of finished threads, or an inbox.** The mockups have none. One current thread.
- **A global project store.** The project pill is a menu of the projects this app has opened (an app preference, newest first, one
  window); there is no store of threads across projects (D6, [many projects](../later/README.md)).
- **Concurrency**: no second window, no two live threads, no concurrent runs or checks (the word "concurrent" goes in `later/`).
- **Thread until merged**: a shipped thread does not keep the single active slot ([thread-until-merged](../later/thread-until-merged.md)).
- **An in-app goal editor.** The goal file and the user's editor stay the source of truth.
- **Per-finding triage** (`Fixed`, `Rejected`, `Verify`, `Reject with note`): needs a per-finding record in core first.
- **Typed proofs and a mandatory verifier** ([proof](../later/proof.md)): the app shows the verifier's screenshots and the judge's
  advisory verdict and gates on neither.
- **Triage integration** ([triage-integration](../later/triage-integration.md)), profiles, and any change to the review stages or
  their order.
- **App-side process, provider or permission logic.** No provider-specific code in the app; provider, model and capability errors
  are core's text.
- **Merging, posting review comments, and pushing** other than through `ship`. Nothing the app adds can bypass an approval.
- **Windows and Linux.** The library and CLI stay portable; the app is macOS 14+.

## Reliability gates

These are the [README](README.md)'s principles applied to a UI, and each is a test or a grep, not a statement.

- **A turn always ends, and says how.** Quit mid-run (⌘Q) records `stopped`; kill the app mid-run and relaunch: exactly one
  `turn.ended` per `turn.started` with `interrupted`, `seq` without gaps, and the UI offers Run again. Tested against `fake-claude`
  (hang, crash, ignore SIGTERM, leave children) driven through the store, not through the views.
- **Stop never signals the app itself.** A test starts an owned run, stops it through the store, and asserts the app's pid was
  not sent a signal and the turn ended `stopped`.
- **Stop returns a usable window in under 6 seconds**, including a child that ignores SIGTERM and one that left descendants.
- **One writer per log.** The app appends only through `ThreadService` and `ThreadRunner`. A run held by a terminal makes the
  app's Run `busy` with the pid, not a second writer; a stale `runner.json` after a crash is recovered, not trusted.
- **Derive, don't store.** `ThreadSpine` and `Attention` are pure functions in core with fixture logs for every row of the two
  tables and for an unknown future event kind (ignored, as the log spec says). The app holds no thread state outside the log
  and the repo path.
- **No blocking waits, no process code in the app.** The grep gate extends to `Sources/WorkbenchApp/` (`Process`, `Subprocess`,
  `posix_spawn`, `waitUntilExit`, `readDataToEndOfFile`, `/bin/sh`). Main-thread work is bounded: the poll `stat`s first and re-reads the log only when it moved (a test asserts an unchanged log is not read again, via
  `EventLogReadCount`); no event-log read on the main actor.
- **Everything is bounded.** The activity list is capped to the turn's stored items (1000) with `dropped` shown; transcripts and
  the raw log are paged, never loaded whole; findings and diffs shown are the sizes core already truncates, and say when cut;
  `Event log` opens the file, not an in-memory copy.
- **Validate before git or a path.** Thread ids go through `SafeNames`; the picked repo is validated as a git repo; a goal, a
  note or a finding is data and never reaches an argument, a path or a shell string.
- **Unknown stays unknown.** A cost no provider reported shows `unknown`, never `$0.00`; a tool or denial count a provider did
  not report shows `unknown`, never `0`; CI that cannot be read is not green; a failed review round is not clean; a skipped stage
  is not a pass. A screenshot whose files are missing or stale is never shown as evidence.
- **The notification rule holds under replay.** Replaying a fixture log into the store produces exactly one notification per
  identity of `needsYou` (including a CI failure on the same head sha twice), none for the state the app opened on, and none after pause.
- **No UI hitch while a turn streams 5 000 events** (main thread never blocked over 50 ms), measured with the store fed by a
  fake that emits that stream, as P3 required.
- **CI.** The Linux PR gate keeps passing (the app target is macOS-only, core types are tested there); a path-filtered macOS job
  builds and tests the app on PRs that touch it; `release-build` on the PR that edits `Package.swift` and on any PR that adds
  concurrency code to the store. `scripts/check.sh` and the soak are not run locally ([AGENTS.md](../../AGENTS.md)).
- **Real use is recorded by hand.** Each slice's demo is run on a real repo, with its budget and what was annoying written down
  in [`FRICTION.md`](FRICTION.md); the screens go in the PR beside the mockups.

## Acceptance criteria

- [ ] P9's gate has passed before slice 0 starts, and a mixed-provider task and a provider with no text streaming display
      correctly through core contracts (carried from P3).
- [ ] From a clean install: pick a repo, write a goal, approve, run, watch, review, accept, ship, read the PR review and clean,
      with no terminal.
- [ ] Every screen matches its mockup in structure and in which colour means what; each deviation is listed in its PR.
- [ ] The spine and the amber rule are core functions with fixtures for every row above, and the app derives nothing else.
- [ ] The window can be closed during a run and the menu bar says when it needs you, once.
- [ ] Quit mid-run and relaunch: `interrupted`, log intact, run again works. Stop returns in under 6 s with a stuck child.
- [ ] Editing an approved goal visibly returns it to draft and disables Run.
- [ ] No UI hitch while a turn streams 5 000 events.
- [ ] Every empty and error state named in the slices has a screenshot and reads as actionable.
- [ ] The app target has no `Process`, `Subprocess` or shell strings (grep-enforced), and no provider-specific code.
- [ ] The ship sequence runs from core and the CLI's ship suites pass unchanged.
- [ ] The "20 real tasks" gate in the [README](README.md) is met by using this app, and the list of annoyances is written down.

## Risks

| Risk | Mitigation |
|---|---|
| The app grows its own state machine | `ThreadSpine`/`Attention` live in core with fixtures; views take them as input |
| Amber turns into noise and gets ignored | The rule is a table with a "never" list; tests replay logs for each; one notification per entry |
| The mockups show data the core does not have (hand marks, per-finding state, live denied commands, mid-turn test counts) | Each is named above with what the app shows instead, or a core PR that comes first; nothing is faked |
| Orchestration in the CLI target cannot be linked | Task 4 lifts ship into core as a behaviour-preserving PR before any UI |
| Streaming floods SwiftUI | Coalesce at ~30 Hz, virtualize, cap, and the 5 000-event gate |
| A run in the app dies with the app | Said in the UI; quit asks and stops cleanly; a crash is the recovery path the log already has |
| macOS-only target breaks the Linux gate | `#if os(macOS)` in `Package.swift`, and a Linux build in the first app PR's checks |

## Demo

On a small real task in a real repo: open the app on the repo, write the goal and approve it, close the window, do something
else, get one notification when the turn ends, open the review from the menu bar, send back one note, accept, ship, read the PR
review, fix its finding, merge on GitHub, clean. Then the failure half: stop a turn at half-way, kill the app mid-turn,
relaunch and run again, and show the log with one `turn.ended` per `turn.started`.
