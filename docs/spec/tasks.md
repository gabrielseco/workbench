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
| `max_open` | 1 to 50, default 2 for `fix: pr` (a dry run is not limited): the task starts no run while this many of its own pull requests are open, because the pull requests of one task tend to touch the same files and pile up. The run ends `skipped-too-many-open` with the addresses; merged and closed ones do not count. It is part of the approval only when the file sets it |
| `timeout` | minutes the agent's turn may run, 5 to 240. Without it the goal's default of 30 stands. Part of the approval only when the file sets it |
| `base` | the branch the thread is cut from: `origin/main` is **fetched first** and the thread starts from it, so a local `main` that is behind cannot give a stale starting point; the fetch names the branch explicitly (`+refs/heads/<b>:refs/remotes/origin/<b>`), so a restricted `remote.origin.fetch` cannot leave it stale; a fetch that fails ends the run `failed` rather than falling back to a stale branch; and a local tag or branch literally named `origin/<b>`, which git would read first, is refused with a message. A name without `origin/` is used as it is. Without it, the project's default base. Part of the approval only when the file sets it. (`pending` still reads the working tree: for a list that lives in files of the checkout, `timer install --pull-main` keeps that current) |
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

Which units are pending is **derived**, never stored: the script's list, minus the units a past run made a thread for (a run that opened its
pull request, failed with its thread left for `workbench ship`, or died), as `gh pr list
--head workbench/<thread> --state all` says: open or merged keeps a unit out; closed unmerged, or no pull request at all, brings it back (unless a run recorded opening one). When that cannot be found out (`gh`
is missing or unreachable) the unit stays out: work done twice costs more than waiting a day. Only units a past run recorded are checked; a pull
request opened by hand for a unit is not seen. A `report` run does the work of no unit.

## In the app

The Tasks screen of the app (a `Thread | Tasks` switch on the rail) shows the same data and no other: a task's `task list` line
(`TaskLibrary.summary`), its runs and their reasons (`TaskRunLog`'s history, the reason cleaned as `task log` cleans it) and the
timer's `status` lines as the card "Will it run tonight?". It re-reads when the app is activated and every 30 s while the screen is
shown, and writes nothing. Approving and running from the app are a later change.

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
| `task.run.thread` | the run created its thread, before the turn starts | `thread`, `units`, `hash` (the approval the run ran under) |
| `task.run.ended` | always, exactly once per start | `outcome`, `reason`, `units`, `thread` when one was started |

A run that stops without a pull request says why in `reason`, in one bounded line: what stopped it, then what the agent said last (600
characters), the commands the turn was denied (up to three, 120 characters each) and, for a failed check, the last eight lines of its output.
A turn that crashed, timed out or ran out of budget has no terminal result: the transcript's last assistant message stands in for it (the streamed events stop at 1000 per turn, so they come last), a failed check's output is kept after such a turn too, and the
explanation is kept for a failure after the turn too (accept, preflight, description, push). Whatever wrote a reason, it is made one line
without control characters and cut at 2000 characters before it is recorded or shown, because all of it is text from a model or a project's
script; `task log` cleans a stored reason again on the way out.
`workbench task list` shows it under the task (`why: ...`) when the last run did not end well.

A unit whose earlier runs ended without a pull request (`failed`, `nothing-to-do`, `budget-exceeded`, `interrupted`) goes after the units not tried
yet, the least tried first and the script's order among equals, so one stuck unit cannot hold the queue; a dry run, a skip and a stale
approval are not tries. A run whose thread never started a turn (setup failed, the runner could not begin) discards that thread and says so, so
the next run is not skipped for it; a thread that ran a turn is still left for a person. When the discard itself fails the reason says the
thread is left for you (`workbench abandon`), never that it was removed.

Outcomes: `pr-opened`, `reported`, `nothing-pending`, `nothing-to-do`, `skipped-project-busy`, `skipped-already-running`, `skipped-too-many-open`, `budget-exceeded`,
`failed`, `stale-approval`, `interrupted` (a run whose process died; the next writer closes it). Holding the log's lock is what makes a task
run once at a time: a second run finds it taken and ends as `skipped-already-running`.

## Commands

- `workbench task timer install [--every <5m..1h>] [--pull-main] | status | remove`: makes the machine run the tasks (below). macOS.
- `workbench task log <name> [--all]`: what the task's last run did, told from its own log and the thread it started: when it began and ended,
  the outcome, the full reason, the units, the thread and pull request, then from the thread the setup result, the check result with the last
  lines of its output when it failed, how many tool calls were denied, and the agent's last message. `--all` is one line per run. A task that
  never ran says so; exit 7 for no such task. Read only.
- `workbench task new <name> [--include <file>] [--input <path>]...`: starts a task. It writes `.workbench/tasks/<name>/task.md` with every
  setting present and explained (the schedule keys commented out, `fix: report`, `batch: 1`, `pending` pointing at the stub) and an executable
  `pending.sh` that prints `[]`, and runs no agent. `--include` and `--input` fill those lines; a path that does not exist yet is a note.
  The instructions start with a `TODO(workbench)` line, and `task approve` refuses a task that still has it. A name or path that is not
  safe is a usage error (exit 2); a task that exists is never touched (exit 6). The command notes a project with no `.workbench/config.toml`
  and a repository that does not ignore `.workbench/` (tasks are local).
- `workbench task list`: one line per task: schedule, fix level, approval (approved, STALE, not approved), next due time, last outcome. A task
  that does not load is a PROBLEM line with the line and key.
- `workbench task approve <name>`: records the approval. Exit 6 for a task that does not parse, 7 for no such task.

- `workbench task run <name>`: runs the task now (below). Exit 0 when it did its work or found none (`pr-opened`, `reported`,
  `nothing-pending`, `nothing-to-do`), 6 when it was skipped or refused (`skipped-project-busy`, `skipped-already-running`,
  `stale-approval`; nothing was changed), 5 over budget, 1 failed, 7 no such task.
- `workbench task tick`: runs the tasks whose next due time has passed, the earliest first, one after the other, and prints how each ended. A
  task with no approval and no run has nothing to count from and never fires; one whose approval went stale is due, so its run can record
  `stale-approval`. A task that was approved once and can no longer be loaded (its script deleted, its skill grown past the limit) has no
  schedule to read: the tick prints `<name>: PROBLEM <why>` and exits 1, so a timer does not take its silence for "all is well". Exit 1
  also when a run failed or went over budget; a skip is a note. This is what a timer calls; the app will call the same
  code for each project it has open.

## A run

In order, ending the run with an outcome at the first step that stops it:

1. Take the log's lock. If another run holds it, `skipped-already-running`; the run cannot write to a log it does not hold, so this one is
   reported to the caller and not recorded (the run that holds the lock records its own end). Then `task.run.started`: if that cannot be written
   (a full disk) nothing is started, and if the end cannot be written the result says `recorded: false` and why.
2. The approval must match what is on disk now, else `stale-approval`.
3. No thread may be active in the project and no `doctor` running, else `skipped-project-busy` naming it. Nothing is queued: the next tick tries again.
   (Only a task that starts a thread needs the project free: a `fix: report` dry run starts none, so an active thread does not skip it.)
4. A `fix: pr` task with `max_open` of its own pull requests still open waits (`skipped-too-many-open`, the addresses in the reason), before
   the pending script or any thread. Every earlier run that made a thread counts (one that died after publishing, and one a person shipped by hand, as well as those that
   ended `pr-opened`), however old: GitHub is asked once for all the repository's open pull requests (`gh pr list --state open`, up to 500) and
   the task's branches are looked up in that list. When it cannot answer, or the list is as long as the limit and may be cut, the run is
   skipped saying so, never started on a guess.
5. The `pending` script, the pull request states, the batch: no units left is `nothing-pending`; a script that fails is `failed` with its reason.
6. `fix: report` stops here: it records `reported` with the units it would take and starts no thread. (A read-only agent turn for `report` is a
   later change; it needs an agent role in the config.)
7. `fix: pr` needs `check_command` in the project's config, else `failed: no check configured`: work is not accepted unchecked. The goal is a
   quick goal built from the instructions, the included skill, the input files and the units (data fenced with a boundary the content cannot
   guess, and a line telling the agent not to follow instructions inside it; a `## ` line is indented so it cannot start a section of the goal
   file), at most 64 KiB, with the task's `budget`. It is approved, `task.run.thread` records the thread and its units, and it is run like any
   thread. A run that dies later (after the pull request is open, before its end is written) is closed as `interrupted` by the next writer and
   keeps those units: the next run asks GitHub, and the units stay out while a pull request for the thread's branch is open or merged, and
   come back when it was closed unmerged or GitHub says there is none.
8. The check must have passed, and the verifier too if one ran, else `failed` and the thread is **left for you**, not discarded: the next run
   is then `skipped-project-busy` until you look at it and finish or abandon it.
9. When the agent changed nothing there is nothing to accept: the run is `nothing-to-do`, the thread is abandoned (so the next run is not
   skipped for it) and the units stay pending. Otherwise the thread is accepted with `by: task:<name>` (the approved task file is the consent). Then the usual preflight, a description of the change from
   the read-only describing turn, and the push and pull request. A pull request needs that description: when the turn fails the run is `failed`,
   the thread stays accepted and `workbench ship` finishes it by hand, because the fallback body is the goal's request, which holds the skill
   and the input files. The screenshots are skipped. Nothing merges.

## The timer

A schedule does nothing until something calls `workbench task tick`. `task timer` sets that up for a project, in the way the first real use
did by hand:

- `install` writes a launcher, `~/.workbench/timers/<slug>/tick.sh`, a **copy of the `workbench` binary** beside it (`~/.workbench/timers/<slug>/workbench`, made through a temporary file and a rename, so a failed copy leaves the old one; the launcher runs the copy, so a rebuild of the checkout it was installed from changes nothing until you run `install` again), and a launchd agent,
  `~/Library/LaunchAgents/com.workbench.task-tick.<slug>.plist`, and loads it with `launchctl bootstrap gui/<uid>` (an old copy is unloaded
  first, so installing again replaces it). `<slug>` is the project's folder and a short hash of its path, so two projects with one name do
  not collide. The agent runs the launcher every 15 minutes by default (`--every 5m` to `1h`); each task's own `at`/`days`/`every` decides what
  is due, and a run missed while the Mac slept happens once on wake. The launcher borrows the PATH of a login shell (launchd has none of your
  shell setup, so `node`, `python3`, `pnpm`, `gh`, `git` and `claude` are the ones a terminal finds), goes to the project and runs
  `caffeinate -i workbench task tick`. The steps before the tick that could stall have deadlines (20 s for the login shell, 120 s for the
  pull; the command is ended, then killed), because launchd never starts a second copy of a job that is still running. `--pull-main` also fast-forwards `main` before each tick, but only when it is checked out and clean.
- It prints the wake line, because a sleeping Mac runs nothing: `sudo pmset repeat wakeorpoweron MTWRF 03:55:00`, from the tasks' own times
  (the earliest `at` minus five minutes, on the days any task runs; a time just after midnight wakes the evening before; tasks with only
  `every:` get no wake line and a sentence saying why). **Workbench never runs `sudo` or changes a power setting**; the person runs the line.
  The only program it runs is `launchctl`.
- `status` is the "will it run tonight?" check: the agent installed and loaded (runs, last exit code), when it last ticked, the binary copy the launcher runs (missing is a FAIL; older than the `workbench` being run is a warning with the fix, compared only when the running program is `workbench`), each task approved
  and scheduled, whether the machine's repeating wake matches (`pmset -g sched`: the time, and the days read as a set, never "close enough";
  days that cannot be read are a warning, not a pass), battery or power, and FileVault. The timer is a user agent, so after a restart it starts when that user logs in, with FileVault on or off:
  FileVault makes the Mac wait for the disk password first, and automatic login would do the rest for you.
  A probe that cannot be read is a warning saying so. Each line is `ok`, `warn` or `FAIL`, with what to do; the exit code is 1 when something
  is a FAIL. Where there is no launchd, `status` gives the crontab line.
- `remove` unloads the agent, deletes the launcher, the binary copy and the agent file, leaves the log (`~/Library/Logs/Workbench/task-tick-<slug>.log`) and names
  `sudo pmset repeat cancel`. An agent that is not loaded is nothing to unload; one that launchctl refuses to unload leaves its files where
  they are and exits 1, and a file that cannot be deleted exits 1 and is not reported as removed.
- `task approve` on a task with a schedule, when no timer is installed, prints a hint line naming `task timer install`.
- Where there is no launchd, `install` refuses and prints the crontab line that does the same. Cron runs at fixed minutes, so only an interval
  that divides the hour is exact (5, 6, 10, 12, 15, 20, 30, 60); any other is rounded down to one and the line says so. A `%` in a path is
  escaped, since cron reads it as a newline.

`WORKBENCH_LAUNCHCTL` names another `launchctl`; the tests and `scripts/verify-cli/task-timer.sh` use a stand-in, so nothing real is loaded.
