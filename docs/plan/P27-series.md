# P27: Series

**Outcome:** a multi-phase plan runs from the first goal to the last without a person starting each phase. You approve the series once;
Workbench runs step 1 through its review loop to a clean pull request, starts step 2 on top of step 1's branch, then step 3 (which may
be in another project), and stops, with a message, at the first step that cannot finish. Nothing merges; you merge the stack at the end.

**Why now:** the loop for one goal works (run, check, verify, judge, review rounds, ship). A plan with phases (for example
`expenses-backend/.claude/plans/invoice_photo_shortcut_plan.md`: backend 1, backend 2, then the frontend in `expense-tracker`) is
driven today by a person or by Claude starting each goal by hand, because nothing records "goal B follows goal A", and a goal cut from
`main` cannot see the PR of the step before it, which Workbench never merges.

## What exists, and what this adds

Already built, and reused as it is:

- A goal can start from a branch of `origin` (`base: origin/<branch>`, `goal new --update`). A stacked step needs no merge first.
- `auto_advance` runs the judge and the review stages after a passing turn; `ship` ends at an open PR; CI and the review verdict say
  when a thread is clean.
- `read_also` lets a goal read another checkout (the backend, from the frontend).
- The scheduled-task timer (P21) ticks with the app closed.
- State is derived from the event log; there is no second copy of it.

New: an ordered **series** of steps, a rule for where each step starts, a driver that moves from one step to the next, and a stop rule.

## The series file

Built in task 2; the format, checks and approval are written in [`../spec/series.md`](../spec/series.md). In short: a folder
`.workbench/series/<name>/` with `series.md` (an optional `budget_usd` front matter and one `## N` section per step with
`project`, `goal`, `base`, `after`, `env`), one **goal file** per step, and `approval.json`.

A step's goal is a **file**, not a thread: a stacked step cannot have a thread before its parent has a pull request, because
`goal new --after` needs one. The driver (task 3) makes each step's thread when the step starts, from its goal file, and approves
it on the series' approval.

## A step is clean

A step is **clean** when its thread has shipped, its PR is open, the PR's checks are all `pass` or `skipping` (never "the command
exited 0": a cancelled check exits 0), and the last review round's verdict is `CLEAN`. This is derived from the thread's log and from
`gh pr checks --json name,bucket`; the series stores none of it.

## Approval

`workbench series approve <name>` records one approval over the series file and the words of every goal file it names (built, task
2). A change to either makes the series STALE and nothing starts (the rule tasks have). Goals are written before the series starts:
criteria that depend on an earlier step's result stay general, or the plan splits the step. Re-drafting a later goal from the
earlier PR is out of v1.

## The driver

`workbench series run <name>` (and the timer tick, so it survives a closed terminal) does, per tick and per series:

1. Read each step's state from its thread: `pending`, `running`, `clean`, `stopped(reason)`.
2. Start every `pending` step whose `after` steps are all `clean` and whose project has room under `max_active_threads`
   (never queued: a step over the cap waits for the next tick and says so in `series status`).
3. A running step is not touched; its own `auto_advance` and review loop are the loop.
4. A step that **stops** stops the series: check failed past its send-backs, judge disagreement, the goal's budget, the series
   budget, a review not clean after its rounds, a refused approval, a crash. Steps already running finish their turn (one
   `turn.ended` per `turn.started` still holds); nothing new starts; `series status` and a notification say which step and why.
5. All steps `clean` is the end: one line per PR in order, and the merge order to follow.

`series status` prints the steps with state, PR, cost so far, and what each is waiting for. `series stop` stops new starts and stops
running steps the way `workbench stop` does. A step that stopped is fixed by hand (`send-back`, or a new turn) and `series run`
continues from where it was; a series never retries a step by itself.

## Stacked pull requests

A step with `base: after N` opens its PR against step N's branch, not `main`, so its diff is only its own. When step N merges,
`workbench series rebase <name>` (and the driver, when it sees the parent merged) retargets the child to `main` and rebases it
with `--onto` and force-with-lease, the way stacks are rebased by hand today. When the rebase conflicts, the series stops at that
step and says so; it never resolves a conflict itself. Squash merges change the parent's SHA, so the rebase is by `--onto` on the
parent's old tip, not a plain `rebase main`.

## Scope

In: the series file and its validation, approval, the driver and its stop rule, `after`/`base: after` ordering, `env` with
`step:N`, stacked PR targets and the rebase after a parent merges, `series status`, a series budget.

Out: merging (Workbench never merges), re-drafting a later goal from an earlier PR, a series that spans more than one
`max_active_threads` window at once (steps run in order unless independent), branches of steps in two different projects based on
each other, editing a series while it runs, a queue.

## Tasks (one PR each)

1. **Stacked base for a goal** (built, #544). `goal new --after <thread>` writes `base: origin/<that thread's branch>`; `ship` opens the PR
   against that branch; the PR description says it is a stack. Tests: the base is the parent branch's tip, the worktree sees the
   parent's files, the PR target is the parent's branch, a parent that was never shipped is refused with a message. Verify-cli
   scenario (`goal-after.sh`) on the fake claude.
2. **Series file** (built). Parse and validate (`SeriesDefinition`, `SeriesLibrary`), `series list`, `series show`, `series approve`. Tests: every refusal in
   "The series file", a changed goal or file makes it STALE, a cycle, an `env` that is not a safe name. Verify-cli `series-file.sh`.
3. **Driver, one project.** Split in two PRs. **3a (built): the read-only part**: `steps.jsonl`, the clean rule and the ready rule (`SeriesScheduler`), `series status`. **3b (built): the runner**: `series run`, which starts each step by running `workbench` (goal new, approve, run, accept, ship --review-loop) as child processes in the step's project instead of reimplementing the review loop, the stop rule, the series budget. Ctrl-C replaces a `series stop`; the timer tick is not built. 3a and 3b together are: `series run|status|stop`, the clean rule, the stop rule, the series budget, the timer tick. Tests with
   the fake claude: two steps in order, step 2 starts only when step 1 is clean (a cancelled check is not clean), a failed step
   stops the series and step 2 never starts, a crash and restart resumes without starting a step twice, `stop` ends the running
   thread with one `turn.ended`. `max_active_threads` full: the step waits and `status` says why. Verify-cli `series-run.sh`
   (real claude, capped).
4. **Cross-project and `env`.** A step in another project starts when its `after` steps are clean; `step:N` resolves to the
   parent branch as `origin/<branch>`; `read_also` of the parent's checkout is added to the goal run. Tests: a missing project,
   a `step:N` of a step that has no branch yet, an `env` value that reaches the check and the verifier. In expense-tracker (a
   separate PR there): `npm run api:sync` takes the ref from `API_CONTRACT_REF`, and `api:check` accepts a pin that was a branch
   commit now merged by squash by re-hashing the contract files instead of requiring the SHA.
5. **Rebase after merge** (built: `series rebase`, run by hand after each merge; the driver does not call it, so a series run never moves a pull request you have not merged). Retarget, `--onto`, force-with-lease, stop on a conflict, a chain one merge at a time. Tests: a squash-merged parent, a conflict, a parent that is still open (nothing happens), a three-step chain.
   on a conflict. Tests: a squash-merged parent, a conflict, a parent that is still open (nothing happens).
6. **The app.** A series card in the inbox: steps, their states, the step that stopped and why. Core is already derived; this is
   display. verify-app scenario: a series running, a series stopped.

Tasks 1 to 3 cover phases 1 and 2 of a single-project plan. Task 4 is what the three-phase invoice plan needs.

## Facts to check before task 1

- How `ship` picks a PR's base: whether it takes one other than the project's default base. If it does not, task 1 starts there.
- Whether `gh pr checks --json name,bucket` is what `ship` and the merge guard already use, so "clean" is one function.
- How the P21 timer finds the projects to tick, and whether a series in step 1's project is enough for it to be found.

## Decisions

- **Stacked, not wait-for-merge.** A merge is a person's act, and waiting for it is the point where autonomy stops. A merge also
  changes SHAs; the stack is rebased after, which `series rebase` does.
- **Goals are approved up front.** Predictable and reviewable; the cost is general criteria for dependent steps.
- **The series stops, it does not retry.** A step that failed needs a person; a second try by itself spends budget on the same
  cause.
- **One home for the file.** Cross-project steps are named by path, validated at load.
