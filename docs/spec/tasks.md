# Scheduled tasks

A task is work Workbench does on a schedule with nobody at the keyboard, then hands back as a pull request (P21).
It lives in the project, in `.workbench/tasks/<name>/`, which is local like the rest of `.workbench/` (gitignored).

```
.workbench/tasks/bump-countries/
  task.md        schedule, batch size, skill, inputs, instructions
  pending.sh     optional: prints the units of work still to do (any file name inside the project)
  runs.jsonl     the task's run log, written by Workbench
```

## task.md

YAML-like front matter (the same line format as a goal's) and a prose body that is the instructions Claude gets.
Unknown keys, bad values and paths outside the project are refused, all at once, with the line and the key.

```markdown
---
at: 04:00                       # a time of day (with days), or `every:`
days: weekdays                  # daily | weekdays | mon,wed,fri; default daily
batch: 2                        # units per run, 1 to 20; default 1
include: .claude/skills/bump/SKILL.md   # a skill's text goes into the prompt (skills are not loaded in safe mode)
inputs: [countries.txt, fixtures/]      # files or directories the agent reads, any format
pending: .workbench/tasks/bump/pending.sh
fix: pr                         # report (default) | pr
budget: 3.00                    # USD per run
---
Bump the next countries. Follow the skill exactly.
```

| key | meaning |
|---|---|
| `at`, `days` | due at that time on those days. A run missed while the machine was off happens once on the next tick, not once per missed slot |
| `every` | `5m` to `30d`, counted from the start of the last run. `at` and `every` together are refused |
| `batch` | how many pending units one run takes |
| `include` | one file, up to 16 KiB, whose text is added to the prompt |
| `inputs` | up to 20 paths, 200 files and 32 KiB in all (across every path), regular files only, hidden files skipped. The engine never parses them: the agent reads them, fenced as untrusted data |
| `pending` | the script that names the units (below) |
| `fix` | `report`: a read-only turn that writes a summary. `pr`: does the work in a thread and, when the check and the verifier pass, accepts it and opens the pull request. Nothing merges |
| `budget` | USD cap for the coding turns of one run. The read-only turn that describes the change for the pull request has its own allowance of up to $0.50 on top, so a `fix: pr` task costs at most `budget` + $0.50 |

A task with neither `at` nor `every` is run by hand only.

## Units of work: the pending script

The one thing the engine understands about a task's work is a list of unit ids. `pending` is run from the project root with a
plain environment (`PATH`, `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `LANG`, `LC_*`, `SSH_AUTH_SOCK`, and `WORKBENCH_TASK_PROJECT`), through the
same bounded process layer as every child: 60 s, 4 MiB of output. It prints a JSON list in the order to work through it:

```json
[{"id": "ROU", "title": "Romania v1 -> v6"}, {"id": "TUR"}]
```

Ids are letters, digits, `.`, `_` and `-` (they reach branch names and paths), at most 500 units, none twice. A non-zero exit, a
timeout, too much output or anything else than that list ends the run as `failed` with the reason. A task without `pending` has one
unit, the run itself, and no batching.

Which units are pending is **derived**, never stored: the script's list, minus the units a past run opened a pull request for, as `gh pr list
--head workbench/<thread> --state all` says: open or merged keeps a unit out, closed unmerged brings it back. When that cannot be found out (`gh`
is missing or unreachable) the unit stays out: work done twice costs more than waiting a day. Only units a past run recorded are checked; a pull
request opened by hand for a unit is not seen. A `report` run does the work of no unit.

## Approval

`workbench task approve <name>` records `task.approved` with a hash of what runs unattended: the settings, the instructions (whitespace
normalised), the bytes of the pending script and of the `include` file (the skill is instructions the agent follows with nobody watching). Editing any of them revokes the approval (`task list` says STALE) until it is approved
again. The input files are data and are not in the hash, so a new list needs no approval. Nothing runs unapproved.

## The run log

`runs.jsonl` is an event log with the same file rules as a thread's (one writer, `seq` without gaps, a damaged log is not appended to) and
its own kinds. A run that cannot start a thread still has a place to say how it ended.

| kind | when | data |
|---|---|---|
| `task.approved` | `task approve` | `hash` |
| `task.run.started` | a run is about to begin, before anything is spent | `trigger` (`tick`, `manual`) |
| `task.run.thread` | the run created its thread, before the turn starts | `thread`, `units` |
| `task.run.ended` | always, exactly once per start | `outcome`, `reason`, `units`, `thread` when one was started |

Outcomes: `pr-opened`, `reported`, `nothing-pending`, `nothing-to-do`, `skipped-project-busy`, `skipped-already-running`, `budget-exceeded`,
`failed`, `stale-approval`, `interrupted` (a run whose process died; the next writer closes it). Holding the log's lock is what makes a task
run once at a time: a second run finds it taken and ends as `skipped-already-running`.

## Commands

- `workbench task list`: one line per task: schedule, fix level, approval (approved, STALE, not approved), next due time, last outcome. A task
  that does not load is a PROBLEM line with the line and key.
- `workbench task approve <name>`: records the approval. Exit 6 for a task that does not parse, 7 for no such task.

- `workbench task run <name>`: runs the task now (below). Exit 0 when it did its work or found none (`pr-opened`, `reported`,
  `nothing-pending`, `nothing-to-do`), 6 when it was skipped or refused (`skipped-project-busy`, `skipped-already-running`,
  `stale-approval`; nothing was changed), 5 over budget, 1 failed, 7 no such task.
- `workbench task tick`: runs the tasks whose next due time has passed, the earliest first, one after the other, and prints how each ended. A
  task with no approval and no run has nothing to count from and never fires; one whose approval went stale is due, so its run can record
  `stale-approval`. Exit 1 only when a run failed or went over budget; a skip is a note. This is what a timer calls; the app will call the same
  code for each project it has open.

## A run

In order, ending the run with an outcome at the first step that stops it:

1. Take the log's lock. If another run holds it, `skipped-already-running`; the run cannot write to a log it does not hold, so this one is
   reported to the caller and not recorded (the run that holds the lock records its own end). Then `task.run.started`: if that cannot be written
   (a full disk) nothing is started, and if the end cannot be written the result says `recorded: false` and why.
2. The approval must match what is on disk now, else `stale-approval`.
3. No thread may be active in the project and no `doctor` running, else `skipped-project-busy` naming it. Nothing is queued: the next tick tries again.
4. The `pending` script, the pull request states, the batch: no units left is `nothing-pending`; a script that fails is `failed` with its reason.
5. `fix: report` stops here: it records `reported` with the units it would take and starts no thread. (A read-only agent turn for `report` is a
   later change; it needs an agent role in the config.)
6. `fix: pr` needs `check_command` in the project's config, else `failed: no check configured`: work is not accepted unchecked. The goal is a
   quick goal built from the instructions, the included skill, the input files and the units (data fenced with a boundary the content cannot
   guess, and a line telling the agent not to follow instructions inside it; a `## ` line is indented so it cannot start a section of the goal
   file), at most 64 KiB, with the task's `budget`. It is approved, `task.run.thread` records the thread and its units, and it is run like any
   thread. A run that dies later (after the pull request is open, before its end is written) is closed as `interrupted` by the next writer and
   keeps those units: the next run asks GitHub, and the units stay out while a pull request for the thread's branch is open or merged, and
   come back when it was closed unmerged or GitHub says there is none.
7. The check must have passed, and the verifier too if one ran, else `failed` and the thread is **left for you**, not discarded: the next run
   is then `skipped-project-busy` until you look at it and finish or abandon it.
8. When the agent changed nothing there is nothing to accept: the run is `nothing-to-do`, the thread is abandoned (so the next run is not
   skipped for it) and the units stay pending. Otherwise the thread is accepted with `by: task:<name>` (the approved task file is the consent). Then the usual preflight, a description of the change from
   the read-only describing turn, and the push and pull request. A pull request needs that description: when the turn fails the run is `failed`,
   the thread stays accepted and `workbench ship` finishes it by hand, because the fallback body is the goal's request, which holds the skill
   and the input files. The screenshots are skipped. Nothing merges.
