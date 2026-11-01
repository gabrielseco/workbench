# P21: Scheduled tasks

**Outcome:** a project can hold tasks that run on a schedule with nobody at the keyboard and come back as an open pull request: "every
weekday at 4:00 bump the next two countries", written once, reviewed in the morning. Workbench never merges.

**Spec:** [`../spec/tasks.md`](../spec/tasks.md). **Goal:** the task list, the file format, the approval, the pending script, the run log.

## Scope

In: `.workbench/tasks/<name>/task.md` (schedule, batch, include, inputs, pending, fix, budget) and the instructions below it; a pending
script that names the units of work; an approval bound to what runs unattended; a run log per task; `task list`, `task approve`,
`task run <name>`, `task tick`; sequential runs; `fix: pr` accepts its own work when the check and the verifier pass.

Out: the app timer and menu bar, CI watching, any merge, concurrency (one project, one active thread: a busy project defers the run), a
committed tasks location shared by a team, unattended credentials (signing, 1Password, waking the Mac: setup notes), writing task files by chat.

## Two pull requests

1. **The task as data** (done): `task.md` parsing and validation, schedules, approval, inputs, the pending script and unit selection, the run
   log, `task list` and `task approve`, the verify-cli scenario `task.sh`.
2. **Running it** (done): `task run` and `task tick` over the existing goal, run, check, accept and ship path; the run outcomes; recovery of a run
   whose process died; the scenario `task-run.sh` with the fake claude and a stand-in `gh`. `fix: report` was a dry run; its read-only agent turn is built now (`TaskReport`, `task run --dry` for the old behaviour);
   `task list`'s pending count and ticking every project (`--all`) are left for later.

## After the two pull requests

- **`task timer`** (done): `install`, `status`, `remove` and the approve hint; the machine part of "run it at 4:00", without `sudo`.
- **`task new`** (done): the scaffold, free and without an agent. A `task draft` that has an agent write `task.md` and the pending script from a
  pasted request needs the agent role in the config that `fix: report`'s read-only turn needs too, so the two come together.
