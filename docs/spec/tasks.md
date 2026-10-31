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
| `include` | one file whose text is added to the prompt |
| `inputs` | up to 20 paths, 200 files and 1 MiB in all (across every path), regular files only, hidden files skipped. The engine never parses them: the agent reads them, fenced as untrusted data |
| `pending` | the script that names the units (below) |
| `fix` | `report`: a read-only turn that writes a summary. `pr`: does the work in a thread and, when the check and the verifier pass, accepts it and opens the pull request. Nothing merges |
| `budget` | a cap for one run |

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

Which units are pending is **derived**, never stored: the script's list, minus the units whose pull request is open or merged. A unit a past
run opened a pull request for whose state could not be found out is left out too (work done twice costs more than waiting a day); a pull
request closed unmerged brings the unit back. A `report` run does the work of no unit.

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
| `task.run.ended` | always, exactly once per start | `outcome`, `reason`, `units`, `thread` when one was started |

Outcomes: `pr-opened`, `reported`, `nothing-pending`, `nothing-to-do`, `skipped-project-busy`, `skipped-already-running`, `budget-exceeded`,
`failed`, `stale-approval`, `interrupted` (a run whose process died; the next writer closes it). Holding the log's lock is what makes a task
run once at a time: a second run finds it taken and ends as `skipped-already-running`.

## Commands

- `workbench task list`: one line per task: schedule, fix level, approval (approved, STALE, not approved), next due time, last outcome. A task
  that does not load is a PROBLEM line with the line and key.
- `workbench task approve <name>`: records the approval. Exit 6 for a task that does not parse, 7 for no such task.

`task run` and `task tick` (what a timer calls) follow in the second PR of P21.
