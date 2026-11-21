# Series

A series is an ordered list of goals to run one after another, in one project or several (P27, [plan](../plan/P27-series.md)).
This page is what is built: the file, its checks, `series list|show|approve`, the state of each step (`series status`) and running a
series (`series run`). Rebasing a stack after a parent merges (`series rebase`) is built; the app view is a later task of the plan.

```
.workbench/series/invoice-shortcut/
  series.md        the steps
  p1.md p2.md p3.md  one goal file per step, as `goal new --from` takes it
  approval.json    written by `series approve`: {hash, approved_at}
  steps.jsonl      written by the driver: one {step, thread, at} per step it started (the latest line of a step counts)
```

## series.md

```markdown
---
budget_usd: 40.00            # optional, USD for the whole series
---
## 1
project: ~/rogal/expenses-backend
goal: p1.md
base: main

## 2
project: ~/rogal/expenses-backend
goal: p2.md
base: after 1                # the branch of step 1's thread (same project)

## 3
project: ~/rogal/expense-tracker
goal: p3.md
after: 1                     # waits for step 1 to be clean
env: API_CONTRACT_REF=step:1 # the branch of step 1's thread
```

A step is the heading `## N` (numbered 1, 2, 3 in order, at most 10) and `key: value` lines. Comments are `#` after two spaces,
as in a goal file.

| key | meaning |
|---|---|
| `project` | required: an absolute path or `~/…`, no `..`. A git checkout with `.workbench/config.toml` |
| `goal` | required: a file name ending `.md` in the series folder (not `series.md`). Parsed as a goal file; a goal file that is a link is refused |
| `base` | `main`-like branch name, or `after N`: cut from the branch of step N's thread (N earlier, same project). Default: the project's base |
| `after` | earlier steps (comma-separated) that must be clean first; `base: after N` implies N |
| `env` | 1 to 5 `NAME=value` pairs, comma-separated: `NAME` in capitals, digits and `_`; `value` is `step:N` (the branch of step N's thread) or a plain word of letters, digits and `. _ / @ : + -` |

A step names only earlier steps, so there is no cycle to detect. The goals of stacked steps are files, not threads: a thread for a
step is made when the step starts, because `goal new --after` needs the parent's pull request ([goal file](goal-file.md), "Stacking").

## Checks

Loading checks everything at once and lists every problem with its line or step (exit 6, nothing changed): the keys above, the
project of each step, every goal file (it must parse as `goal new --from` reads it, be a regular file and be 256 KiB or less),
and that a `base: after N` step is in the same project as step N.

## Approval

`series approve <name>` records one hash over the budget, every step's keys and the words of every goal file (whitespace-only edits
do not change it). A change to any of them makes the series **STALE** in `series list` and `show`. `approval.json` is local like the
rest of `.workbench/`.

## Commands

| command | does |
|---|---|
| `series list` | each series with its step count and `approved`, `STALE` or `not approved`; one that does not load shows `PROBLEM` and why |
| `series show <name>` | the steps as they will run: project, goal, where each starts, what it waits for, `env` |
| `series status <name>` | where each step is and which steps could start now (below). Read only; asks `gh` for the checks |
| `series run <name>` | runs the approved series (below) |
| `series report <name> [--out <file>]` | what the series built, what its reviews found and what answered each finding, from the logs (below) |
| `series rebase <name>` | after a parent's pull request is merged, retargets and replays the step stacked on it (below) |
| `series approve <name>` | records the approval and prints the steps. Starts nothing, creates no thread |

Exit codes: 0, 2 usage, 6 the series is not valid or not approved, 7 no such series; for `series run` also 1 stopped and 14 a step waits.

## Where a step is

Derived each time from the step's thread and what GitHub says now about its pull request (state and head, `gh pr view`; the log only knows what went through Workbench, so a merge or a push made elsewhere is seen there) (in the step's own project, named by `steps.jsonl`) and its pull request's checks; nothing
is stored but the thread name.

| state | when |
|---|---|
| `pending` | no thread yet; `status` says which steps it waits for |
| `running` | a thread with no pull request, not ended |
| `waiting` | the pull request is open and something is missing: no checks yet, checks running or unreadable, no review yet, a round running, the review asked for fixes, or the last review was of an older commit |
| `clean` | **the pull request is open, every check is `pass` or `skipping`, and the last review round was of the head commit GitHub has now with the verdict `clean`**; a repository that reports no checks at all counts as passed once the pull request is 2 minutes old (the grace `ship --watch` allows: CI registers late); or it is merged (a person's merge is the decision that matters, so a merged pull request needs neither) |
| `STOPPED` | needs a person: a check `fail`ed or `cancel`led (once nothing is still running; a cancelled check is never clean, whatever `gh` exits with), a review round with no verdict, the pull request closed unmerged (read from GitHub), the thread discarded or abandoned, or accepted and never shipped |

A step is ready when it is `pending` and every step in its `after` is `clean`; **nothing is ready while any step is `STOPPED`**.
`status` prints the states, then `stopped at step N` or `ready to start: step …`.

## Running a series

`series run <name>` is a foreground loop that refuses a series that is not approved (or STALE). Each round it reads the states, then:

1. **stopped anywhere:** it ends (exit 1) naming the step and why; nothing new starts.
2. **every step clean:** it ends (exit 0).
3. **a step is ready** (pending, every `after` clean): it runs that step, one at a time, then goes back to 1. Steps in different
   projects still run one after the other.
4. **nothing is ready and nothing is stopped:** a step waits for something that is not the driver's to do (checks still running, a
   review that asked for fixes, a thread that has not opened its pull request, a project at its thread cap): it ends (exit 14) naming it.

A step runs the same commands a person would, each as a child `workbench` process in the step's project, with the step's `env`
(`step:N` resolved to `origin/<the branch of step N's pull request>`): `goal new <series>-<N> --from <goal file>` (with
`--after <step's parent thread>` for `base: after N`, or `--base <branch>`), `goal approve`, `run`, `accept -m "chore: <title>" --yes`,
and `ship --yes --review-loop`. The thread is recorded in `steps.jsonl` as soon as `goal new` prints it. So the review loop,
the timeouts and every budget are the ones those commands have, and each thread's goal keeps its own `budget_usd`.

- **Stop rule:** the first command that exits non-zero ends the series. While the thread has no pull request the reason is written
  to `steps.jsonl` and `status` shows STOPPED; once one is open its own state is read. Nothing is retried. Fix the step with the usual
  commands (`next`, `send-back`, `accept`, `ship`); when it reads clean, `series run` continues from the next step.
- **A step is accepted only if its work was checked:** `run` exits 0 for a turn that succeeded even when the project's check then
  failed, so after `run` the driver reads the thread's log: the check must have run for the latest turn and passed, and a verifier
  that ran must have passed (the judge is advice and does not decide). Otherwise the series stops before `accept`, nothing is
  accepted or pushed, and the step is fixed by hand (`send-back`). A project with no `check_command` is not run unattended.
- **Series budget:** before a step starts, what the steps' threads have cost (their logs' `cost_usd`, with the follow-up threads of
  their review rounds) plus that step's own goal budget (`budget_usd` of the goal file, else
  the project's default) must fit in the series `budget_usd`; otherwise the series stops before spending it. A step's review-loop follow-ups have caps of their own and are counted when the
  next step is about to start, so a series can end a little over its budget.
- **A project at `max_active_threads`** (`goal new` exits 6, nothing changed) makes the series *wait* (exit 14), not stop.
- **Ctrl-C** ends the running command cleanly (it ends its own turn), stops the wait for checks, and the series stops.
- **One run at a time:** `series run` holds `run.lock` in the series folder; a second one is refused (exit 6). A start marker is
  written to `steps.jsonl` before `goal new`; a run that died between making the thread and recording it is found by the next one
  (the one thread named `…-<series>-<N>` is recorded and the run stops once so you see it; several are left for you).
- **What is approved is what runs:** the series and its goal files are read again each round and the run refuses (exit 6) when they
  no longer match the approval; the goal is handed to `goal new` from a copy of the approved text (`.snapshots/step-N.md`), not
  from the file.
- Ctrl-C gives the child up to 60 s to end its turn before anything is killed.
- It never merges, and a step that was started is not started again: a step with a thread but no pull request is `running` and waits
  for a person.

## After a parent is merged

You merge the pull requests yourself, in order. A squash merge gives the parent a new commit, so the pull request of the step stacked
on it (`base: after N`) still carries the parent's old commits and targets the parent's branch. `series rebase <name>` fixes each such
step whose parent's pull request is **merged** (read from GitHub):

1. fetches the base the parent was merged into and the step's branch;
2. replays only the step's own commits: `git rebase --onto origin/<base> <the commit the step was cut from> …` in a throwaway
   worktree (`worktree.created`'s `base_commit` in the step's log is the parent's tip at the time, so the parent's old commits are not
   replayed again);
3. pushes with `--force-with-lease` on the tip GitHub reports for the pull request, so a commit pushed in between is not overwritten;
4. changes the pull request's base to that branch (`gh pr edit --base`).

A parent that is not merged yet makes the step *wait* (nothing changes); a step already on its base is reported as such, so the
command can be run again after each merge, which is how a chain of three is done. A **conflict** aborts the rebase, lists the files and
pushes and changes nothing (exit 1); resolve it by hand. A step whose own pull request is merged is skipped (the steps stacked on it come next) and a closed one is reported, not touched; a conflict or a failure ends the command so no later step is moved past it. The
branch's old head is reviewed and checked, the rebased one is not: run the review again if you want it. It never merges.

## The report

`series report <name>` is what you read when a series comes back. It is built from what is already recorded (the steps' thread logs, their
review rounds and follow-up threads) and runs no agent, so it is free and states only what the logs say. It prints Markdown and writes it
to `.workbench/series/<name>/report.md` (or `--out`). It also works on a series that is not finished: a step not started is said so.

- **Summary:** a table of the steps (goal, state, pull request, the review rounds as `FIX → FIX → CLEAN`, cost), the cost of the coding turns
  against the series budget (the Codex reviews and judge runs have no price and are not counted), and the pull requests in the order to
  merge them with the reminder to run `series rebase` between merges.
- **Per step:** the size of the pull request (`gh pr view`, when `gh` is there), turns and cost, the check, the verifier and the judge's
  reading **with the turn it is of** (it is read before the review fixes, so a criterion it found unmet may be fixed since); the agent's own
  account of what it built; the criteria with the judge's tick; the judge's concerns.
- **Review:** each round's verdict, its findings (severity and title, read from the round's findings file, which is named for the whole
  text), and the follow-up thread that answered it: its cost, its commits and what the agent said last (what it fixed and what it left).
  A round with a FIX and no follow-up is said so.
- **Also pushed outside the review rounds:** a follow-up that answers no review round (a CI fix), and threads made by hand on the same
  branch (`goal new --update <branch>`), with their commits and what they said; their cost counts toward the step. Which round a
  follow-up answers is what its own goal says (`(review round N)`): the loop's round counter also counts CI fixes, so it is not used.
- A turn that reported no cost (a provider with no dollar figure) makes the figure a lower bound, written `$1.50+`.
- Text that came from an agent is scrubbed of machine paths and of credentials of the known forms (URL credentials, authorization
  headers, GitHub tokens, query-string tokens, `NAME_TOKEN=value` pairs: not a promise about every secret an agent could print) and cut
  (1200 characters for what it built, 700 for a follow-up's account); a cut account says `workbench log <thread>` holds the whole one.
