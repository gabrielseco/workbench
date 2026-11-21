# Series

A series is an ordered list of goals to run one after another, in one project or several (P27, [plan](../plan/P27-series.md)).
This page is what is built: the file, its checks and `series list|show|approve`. Running a series (the driver, the stop rule, stacked
pull requests after a merge) is later tasks of the plan.

```
.workbench/series/invoice-shortcut/
  series.md        the steps
  p1.md p2.md p3.md  one goal file per step, as `goal new --from` takes it
  approval.json    written by `series approve`: {hash, approved_at}
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
| `series approve <name>` | records the approval and prints the steps. Starts nothing, creates no thread |

Exit codes: 0, 2 usage, 6 the series is not valid, 7 no such series.
