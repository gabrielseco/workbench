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
days: weekdays                  # daily | weekdays | mon,wed,fri | monthly | monthly:15; default daily
batch: 2                        # units per run, 1 to 20; default 1
include: .claude/skills/bump/SKILL.md   # a skill's text goes into the prompt (skills are not loaded in safe mode)
inputs: [countries.txt, fixtures/]      # files or directories the agent reads, any format
pending: .workbench/tasks/bump/pending.sh
fix: pr                         # report (default) | pr
# history: 3                    # with `fix: report` only (a pr task is refused it): the data blocks of the last 3 reports, 1 to 6
budget: 3.00                    # USD per run
---
Bump the next countries. Follow the skill exactly.
```

| key | meaning |
|---|---|
| `at`, `days` | due at that time on those days. A run missed while the machine was off happens once on the next tick, not once per missed slot. `days: monthly` is the 1st of the month, `days: monthly:15` the 15th (1 to 28, so every month has the day; anything else is refused with the line and key): due on the first tick on or after that day at `at`, counted from the start of the last run (or the approval), so a month missed is run once and the next slot is the following month's, with no drift |
| `every` | `5m` to `30d`, counted from the start of the last run. `at` and `every` together are refused |
| `batch` | how many pending units one run takes |
| `include` | one file, up to 16 KiB, whose text is added to the prompt |
| `inputs` | up to 20 paths, 200 files and 32 KiB in all (across every path), regular files only, hidden files skipped. The engine never parses them: the agent reads them, fenced as untrusted data |
| `pending` | the script that names the units (below) |
| `fix` | `report`: one read-only turn, in a checkout of the base as committed (the agent of `[agents.plan]`, with Read, Glob and Grep and, when the task sets `mcp_tools`, exactly those MCP tools; never the working tree), whose answer is kept as `.workbench/tasks/<name>/reports/<time>.md` (cut at 256 KiB) and whose first line is the run's reason. It starts no thread, changes and opens nothing, and costs at most the task's `budget` (the project's default budget when it sets none). `pr`: does the work in a thread and, when the check and the verifier pass, accepts it and opens the pull request. Nothing merges |
| `max_open` | 1 to 50, default 2 for `fix: pr` (a `fix: report` run is not limited): the task starts no run while this many of its own pull requests are open, because the pull requests of one task tend to touch the same files and pile up. The run ends `skipped-too-many-open` with the addresses; merged and closed ones do not count. It is part of the approval only when the file sets it |
| `timeout` | minutes the agent's turn may run, 5 to 240. Without it the goal's default of 30 stands. Part of the approval only when the file sets it |
| `base` | the branch the thread is cut from: `origin/main` is **fetched first** and the thread starts from it, so a local `main` that is behind cannot give a stale starting point; the fetch names the branch explicitly (`+refs/heads/<b>:refs/remotes/origin/<b>`), so a restricted `remote.origin.fetch` cannot leave it stale; a fetch that fails ends the run `failed` rather than falling back to a stale branch; and a local tag or branch literally named `origin/<b>`, which git would read first, is refused with a message. A name without `origin/` is used as it is. Without it, the project's default base. Part of the approval only when the file sets it. (`pending` still reads the working tree: for a list that lives in files of the checkout, `timer install --pull-main` keeps that current) |
| `labels` | 1 to 5 labels put on the pull request a `fix: pr` run opens, `labels: [seed-preview, bot]`. Each name is 1 to 50 of letters, digits and `- _ . : /`, with no duplicates (case is ignored, as GitHub does); anything else is refused at load with the line and key. Part of the approval only when the file sets it, so editing them makes the task STALE. Only a task run adds them; `workbench ship` of an ordinary thread adds none |
| `mcp_tools` | `fix: pr` or `fix: report`: MCP tools the task's runs may call, `mcp_tools: mcp__linear__get_issue, mcp__linear__save_issue` (1 to 10, each exactly `mcp__<server>__<tool>`: no wildcard, no duplicate; anything else is refused at load with the line and key). The servers are **never** defined here: each name's server must have a `[mcp_servers.<name>]` table in `.workbench/config.toml`, or the task is refused at load (`task list` shows PROBLEM, `workbench doctor` warns). Part of the approval only when the file sets it, so editing the list makes the task STALE. See "MCP tools" below |
| `history` | `fix: report` only, 1 to 6 (anything else is refused at load with the line and key; `fix: pr` is refused too, see "Report history"): the last N reports of this task from before today are read from `reports/` and added to the prompt, newest first, each as its final `data` block fenced as untrusted data. Part of the approval only when the file sets it, so editing it makes the task STALE. See "Report history" below |
| `budget` | USD cap for the coding turns of one run. The read-only turn that describes the change for the pull request has its own allowance of up to $0.50 on top, so a `fix: pr` task costs at most `budget` + $0.50 |

A task with neither `at` nor `every` is run by hand only.

## MCP tools

`mcp_tools` lets one task call named tools of an MCP server (the use case: `update-contract-details-tracker` patches a Linear issue at 21:00) while every other run stays as it is.

```toml
# .workbench/config.toml
[mcp_servers.linear]
type = "http"                        # "http" or "sse" with an https url, or "stdio" with command and args
url = "https://mcp.linear.app/mcp"   # no secret goes here
```

```yaml
# .workbench/tasks/update-contract-details-tracker/task.md
at: 21:00
fix: pr
mcp_tools: mcp__linear__get_issue, mcp__linear__save_issue
```

For that task's turns only (for `fix: report`, its one report turn), Workbench writes a temporary file (mode 600) holding just the servers the listed tools belong to, starts `claude` with `--mcp-config <file> --strict-mcp-config`, appends exactly the listed tools to `--allowedTools` (`--disallowedTools` still wins); any other `mcp__` entry in `[tools].allowed` or a thread grant (a different tool, or a whole server) is left out of that turn, and deletes the file when the turn ends, however it ends. Goal runs, other tasks, the verifier and the read-only turns (plan, PR description, and a report without `mcp_tools`) never get a server. A `[mcp_servers.*]` table alone loads nothing.

**What was measured** (claude 2.1.316): `--safe-mode` turns MCP servers off even with `--mcp-config --strict-mcp-config`, so a task with `mcp_tools` runs **without `--safe-mode`**; `--disable-slash-commands` stays, so skills and commands stay off. That means the user's settings and hooks, and the worktree's `CLAUDE.md` and project settings, load for that task's runs. `--allowedTools mcp__linear__get_issue` allowed that tool and refused `save_issue` of the same server.

**Warnings.**
- Each listed tool is a **capability for an unattended run** (a write one if the tool writes). List only what the task needs; a read tool and a write tool are two entries.
- A remote server needs the login you did in your own `claude` (`/mcp`). Workbench passes no new variable: the run finds it through `HOME` and `CLAUDE_CONFIG_DIR`, which it already passes. Without it the tools are simply not there and the task says it could not call them.
- Only Claude as the coding agent: with `[agents.run]` on Codex a task with `mcp_tools` is refused before any turn.

**`fix: report` with MCP tools.** A report turn is `Read`, `Grep` and `Glob` in a checkout of the base, no Bash, no file changes. With `mcp_tools` it also gets the temporary `--mcp-config <file> --strict-mcp-config` file (mode 600, deleted when the turn ends) and `--allowedTools` for exactly the listed tools, and nothing else from MCP. So a task can query a data source (the use case: a monthly Snowflake query kept as a report) and keep the answer under `reports/<time>.md` with the first line as the run's reason, opening no thread and no pull request. The prompt tells the agent it may read and call only those tools.

What this **loosens**: that one turn runs **without `--safe-mode`** (the CLI turns MCP off under it), so the user's settings and hooks load, as for `fix: pr`; the checkout is the base as committed, so the project's own `CLAUDE.md` and project settings come from it. `--disable-slash-commands` stays, `--restricted` stays, and the tool list stays `Read`, `Grep`, `Glob` plus the listed tools. A report task **without** `mcp_tools` is unchanged and still runs under `--safe-mode`.

What it does not loosen: a report task with MCP tools can read through MCP and can change no file, but **every listed tool is still a capability for an unattended run**: a tool that writes (a `save_` or `execute_` tool on a server that mutates) writes, report or not. List only read tools for a report, and a read tool and a write tool are two entries. The 256 KiB cut-off on a report stays. Only Claude: with `[agents.plan]` on Codex a report task with `mcp_tools` ends `failed` before any turn.

A task that acts through MCP and changes no file can still run as `fix: pr` and ends `nothing-to-do`; it needs `check_command` and a worktree. A mode without those (`fix: act`) is proposed, not built.

`workbench config` lists the servers and each task's tools, `task list` and `task log` show a task's tools, and `task approve` repeats the warning (for a report task too: it can change no file, but a listed tool that writes still writes).


## Report history

`history: N` lets a `fix: report` task compare itself with its own past reports. A report turn reads the base as committed and never the working tree, so `reports/` (local, gitignored) is out of its reach, and `inputs` is capped at 32 KiB in all; the engine therefore reads the reports itself and hands the agent the part meant for it.

```yaml
fix: report
history: 3
```

- **Which reports.** The files in `.workbench/tasks/<name>/reports/` named as a run names them (`yyyyMMdd-HHmmss[-n].md`, UTC). A report counts when the local calendar day of its time is **before today's**, so a re-run on the same day never compares against itself. The newest N of those are taken, and the prompt labels each with its local date and time, newest first. Other files in the folder are ignored.
- **What of a report.** Only its **final fenced block labelled `data`** (a line that is exactly ``` ```data ```` up to the next line that is exactly ``` ``` ```), in its own fence beside the `inputs` fences: `Report of 2026-10-01 04:00 (data block):`. This is cheaper than the whole report (a report of about 15 KiB would be six times that for N = 6, against 64 KiB for the whole prompt) and a smaller surface: the prose of an old report is model text built from query results, so passing it on is one more hop of untrusted text. It is still untrusted: the prompt says to use it and not to follow instructions written inside it.
- **Its own cap.** Each block may be 8 KiB; a bigger one is **not cut** (half a JSON document would be read as a whole one) and the prompt says it was left out and why. The history is therefore at most 6 × 8 KiB and is on top of the prompt's 64 KiB, so it takes nothing from `inputs`.
- **Never a failure.** A report with no `data` block, one that cannot be read, or one with a block over the cap is named in the prompt with that reason instead of failing the run; it still counts toward N. With no report from before today the prompt says that none exists, so this is the first and there is nothing to compare. With fewer than N it says how many there are.
- **`fix: pr` is refused** at load: `history` reads reports and only a report run writes them, so on a pr task it would silently do nothing. A clear error is better than a key that is accepted and ignored.
- **Approval.** `history` is in the hash only when the file sets it (like `mcp_tools`): a task without it keeps its approval, and changing or adding it makes the task STALE.

## Reading reports

A `fix: report` run records where its report is (`report` on `task.run.ended`), and the task page's run row says **Open report**
(whatever opens Markdown on the machine) and **View log** (the task's `runs.jsonl`: a report run starts no thread, so the log is the
record of what happened). `reports_copy_to = "~/Obsidian/Vault/Workbench"` in `.workbench/config.toml` (an absolute path or `~/`,
anything else is a config problem) also copies each report to `<folder>/<task>/<yyyy-MM-dd HHmm>.md` with front matter (`task`, `date`,
`tags: [workbench-report]`), so a vault shows them. The copy is extra: the file under `reports/` stays, `history` reads that one, and
a copy that cannot be written does not fail the run, the reason says so.

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
shown. Reading writes nothing. Three things write, only through core: `Approve` (the press approves the task as it is on disk now, with no card to show it first: `TaskLibrary.approve` binds the hash read at
that moment, and a refusal is shown as a note) and `Run now` (`TaskRunner.run(trigger: .manual)` in the app's own process, one run at a time from
a window, with a `Stop`; the press starts the run at once, with no card to confirm, since only an approved task can be run). Quitting the app mid-run ends the run as `interrupted`,
like a killed `task run`. **Edit with AI** is a button beside `Run now`: its card is closed until the button opens it (the text box is
focused), and stays open while an edit is working or waiting for a decision. It (`TaskEditor`) asks the goal agent once for a new `task.md`: a one-shot read-only turn, no
thread and no worktree, so it needs no active-thread slot and works beside one. The agent is given the file's text and the request, each
quoted as data, and returns the whole file; core checks that it loads exactly as the file would (`TaskLibrary.loadText`: the keys, the
MCP servers, the script and skill files) and shows what it changes: each setting approval binds to as old → new, apart from the
instructions' line diff. Nothing is written until `Accept`, which writes only over the file the proposal was made from (another edit in
between refuses it) and is refused while a run of the task is going; it never approves, so an approved task reads STALE until `Approve`.
The cost is the goal draft's cap (`TaskEdit.budgetUSD`, the same value as `GoalDraft.budgetUSD`); the goal agent is `[agents.goal]`.
The CLI is `workbench task edit <name> (--request "<text>" | --request-file <path>) [--accept]`: it prints the changes and writes
nothing without `--accept`; refused (exit 6) with no goal agent, a task that does not load or a run going, and exit 1 when the agent's
answer was not a usable task file. An edit leaves nothing in the run log.

A run's row on the task page has a **Details** toggle. Opened, it reads the run's detail (`TaskRunDetail`, the one reader `task log` also
renders from): how long it took, what it cost (the turns' `cost_usd` added; unknown is shown as unknown, never $0), how setup and the check
went with the check's output when it did not pass, the tool calls it was refused, and the agent's last message, each cleaned and bounded as a
reason is. It is read when the row is opened and never with the task list, so the 30 s refresh does not read a thread's log. A run that has
not ended shows only how long it has gone; a run with no thread, or whose thread was removed, says so. A warning that names the timer's
tick log offers **Open log** when the file is directly in the user's own `~/Library/Logs/Workbench`, named `task-tick-*.log`, and exists.

**New task…** (a quiet link under the rail's Scheduled list, **File ▸ New Task…** with ⇧⌘N, and a button on the empty Tasks page; the rail's one `+`, on Threads, starts a goal, as ⌘N does) opens a screen with a name and the person's words.
The name is checked as it is typed (`TaskScaffold.isUsableName`, and not an existing task or folder). **Propose** (`TaskEditor.proposeNew`) gives
the goal agent the scaffold's template without its script line (`TaskEdit.newTemplate`) and the words, each quoted as data, in the same
one-shot read-only turn as an edit (no thread, `[agents.goal]`, the same cost note), asked not to add `mcp_tools`, `pending`, `include` or
`inputs` and to keep `fix: report` unless the words say otherwise. The answer must load as a task of that name and must not keep the
scaffold's placeholder; it is shown as what it would create (every setting it sets as `not set → value`, every instruction line added).
**Accept** makes the folder (claimed exclusively, so two accepts of one name, or a folder made meanwhile, cannot both succeed and the loser
never touches the winner's files) and `task.md`, and opens the task's page: not approved, and nothing run. **Create empty task** needs no
agent: it is `TaskScaffold.create`, the template `task new` makes, `task.md` and `pending.sh` with the placeholder `task approve` refuses.

An ended run's opened Details also has **Fix this with AI**: it opens the task's Edit with AI card with the run as the request
(`TaskEdit.runRequest`: when it started and how, how it ended and why, the check's result and output, the refused calls, the agent's last
message; each only when known, the words from outside quoted behind `> `, cleaned and bounded to 4 KiB, ending with what to answer),
under anything the person had typed, scrolls to it and focuses the box. It waits until the run's detail has been read (so the box has all
of it), is not offered for a run that has not ended, and is off while an edit is working or has a proposal waiting. It asks the agent
nothing: the person adds their words, or presses Propose.

The app also watches while it runs, whatever screen or window is up: every 30 s and when it is activated it re-reads the open
project's tasks (their runs, without the timer's probes) and tells you, once, when a task breaks or goes stale: a run that ended
`failed`, `budget-exceeded` or `interrupted` (until a later run ends well), or an approval that is STALE now (until it is approved
again). A skip, `pr-opened` and `reported` never do. What is already there when the app or the project is opened is counted and
never announced, and a reason announced once is not announced again (a CI failure on the same commit that went green and failed again, or the same app relaunched; the latest 200 are kept per app, not per log); the menu bar item counts them and its popover opens them; looking at the task on the Tasks screen marks its current items seen (an app preference: nothing is written to the
run log), and a newer failure of the same task is a new reason. `Pause notifications` is an app preference too.

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
| `task.run.ended` | always, exactly once per start | `outcome`, `reason`, `units`, `thread` when one was started, `report` (the report file, relative to the project root) for a `fix: report` run |

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

- `workbench task timer install [--every <5m..1h>] [--pull-main] | refresh [--all] | status | remove`: makes the machine run the tasks (below). macOS. `refresh` brings an installed timer up to date with the binary it runs from: it replaces the timer's copy by rename, rewrites the launcher and the agent file only if they differ (keeping the interval and `--pull-main`), reloads the agent only when its file changed (unloading would end a running tick), never replaces the copy with an older binary and never touches the wake schedule. `--all` does it for every installed timer; the post-merge hook runs it after rebuilding, so a pull of main reaches the timers. `status` warns when the copy is older than the binary it runs from and names `refresh`.
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
- `workbench task list [--pending]`: one line per task: schedule, fix level, approval (approved, STALE, not approved), next due time, last outcome. A task
  that does not load is a PROBLEM line with the line and key.
  `--pending` adds `pending: <left> of <listed>` by running the task's pending script (60 s, as a run would) and asking GitHub about the
  pull requests of units an earlier run took; a task that is not approved, or was edited since, is not run (`not checked (...)`: its script is
  not what was approved), and a script that fails shows `unknown (why)`.
- `workbench task approve <name>`: records the approval. Exit 6 for a task that does not parse, 7 for no such task.

- `workbench task run <name> [--dry]`: runs the task now (below); `--dry` makes a `fix: report` task list what it would take instead of asking the agent. Exit 0 when it did its work or found none (`pr-opened`, `reported`,
  `nothing-pending`, `nothing-to-do`), 6 when it was skipped or refused (`skipped-project-busy`, `skipped-already-running`,
  `stale-approval`; nothing was changed), 5 over budget, 1 failed, 7 no such task.
- `workbench task tick [--all]`: runs the tasks whose next due time has passed, the earliest first, one after the other, and prints how each ended. A
  task with no approval and no run has nothing to count from and never fires; one whose approval went stale is due, so its run can record
  `stale-approval`. A task that was approved once and can no longer be loaded (its script deleted, its skill grown past the limit) has no
  schedule to read: the tick prints `<name>: PROBLEM <why>` and exits 1, so a timer does not take its silence for "all is well". Exit 1
  also when a run failed or went over budget; a skip is a note. This is what a timer calls; the app will call the same
  code for each project it has open.
  `--all` does that for every project that has a timer installed, one after the other: the folders are those the agents in
  `~/Library/LaunchAgents/com.workbench.task-tick.*.plist` run in (there is no other list of projects). A folder that is gone or is no longer
  a repository (even when a parent folder is one: that is not ticked in its place) is printed as `PROBLEM` and fails the pass; the first Ctrl-C ends the run in progress and starts no later project.

## A run

While a run goes it says what it is doing, as short lines: the turn starting, the agent's tool calls (at most one every 2 s, each one
line without control characters, 240 characters at most), the setup, the check and the verifier. `task run` prints them indented; the app
shows the last one. The run's own words about how the turn ended come once, with its explanation.

In order, ending the run with an outcome at the first step that stops it:

1. Take the log's lock. If another run holds it, `skipped-already-running`; the run cannot write to a log it does not hold, so this one is
   reported to the caller and not recorded (the run that holds the lock records its own end). Then `task.run.started`: if that cannot be written
   (a full disk) nothing is started, and if the end cannot be written the result says `recorded: false` and why.
2. The approval must match what is on disk now, else `stale-approval`.
3. No thread may be active in the project and no `doctor` running, else `skipped-project-busy` naming it. Nothing is queued: the next tick tries again.
   (Only a task that starts a thread needs the project free: a `fix: report` run starts none, so an active thread does not skip it.)
4. A `fix: pr` task with `max_open` of its own pull requests still open waits (`skipped-too-many-open`, the addresses in the reason), before
   the pending script or any thread. Every earlier run that made a thread counts (one that died after publishing, and one a person shipped by hand, as well as those that
   ended `pr-opened`), however old: GitHub is asked for all the repository's open pull requests at once (`gh pr list --state open`, up to 500) and
   the task's branches are looked up in that list. A timeout or an error that reads like no network is asked again, up to 3 times in all, 5 s
   apart; any other failure is not. When it still cannot answer, or the list is as long as the limit and may be cut, the run is
   skipped saying why (gh missing, timed out, gh's first line of complaint with credentials removed, and "looks like no internet connection"
   when it reads that way), never started on a guess.
5. The `pending` script, the pull request states, the batch: no units left is `nothing-pending`; a script that fails is `failed` with its reason.
6. `fix: report` stops here: it asks the read-only agent (above), saves the answer under `reports/` and records `reported` with the first line of the report and where it is, or `failed` with why (no config, the agent is not installed or ran out of budget, an empty answer). `task run <name> --dry` instead lists the units it would take and starts no agent: `reported` with `dry run: would take ...`.
7. `fix: pr` needs `check_command` in the project's config, else `failed: no check configured`: work is not accepted unchecked. The goal is a
   quick goal built from the instructions, the included skill, the input files and the units (data fenced with a boundary the content cannot
   guess, and a line telling the agent not to follow instructions inside it; a `## ` line is indented so it cannot start a section of the goal
   file), at most 64 KiB, with the task's `budget`. It is approved, `task.run.thread` records the thread and its units, and it is run like any
   thread. A run that dies later (after the pull request is open, before its end is written) is closed as `interrupted` by the next writer and
   keeps those units: the next run asks GitHub, and the units stay out while a pull request for the thread's branch is open or merged, and
   come back when it was closed unmerged or GitHub says there is none.
8. The check must have passed, and the verifier too if one ran, else `failed` and the thread is **left for you**, not discarded: the next run
   is then `skipped-project-busy` until you look at it and finish or abandon it.
9. When the agent changed nothing there is nothing to accept: the run is `nothing-to-do` (the app shows it as `done`: the turn and check passed, there was just nothing to ship), the thread is abandoned with `by: task` (shown as `Succeeded`, not `Abandoned`; so the next run is not
   skipped for it) and the units stay pending. Otherwise the thread is accepted with `by: task:<name>` (the approved task file is the consent). Then the usual preflight, a description of the change from
   the read-only describing turn, and the push and pull request. A pull request needs that description: when the turn fails the run is `failed`,
   the thread stays accepted and `workbench ship` finishes it by hand, because the fallback body is the goal's request, which holds the skill
   and the input files. The screenshots are skipped. Nothing merges.
   When the task has `labels`, they are added as the pull request is opened: each is created first (`gh label create --force`, which keeps the colour of one that exists) and then put on the pull request. A label that cannot be created or added is only noted: the run still ends `pr-opened`, the thread is shipped as usual, and `reason` is one bounded line naming each label and why (`the pull request is open, but label 'x': ...`). A pull request found already open for the branch is not labelled.

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
  `every:` get no wake line and a sentence saying why; a `days: monthly` task runs on a day of the month, which `pmset repeat` cannot name, so it adds no wake: `install` says the machine must be awake and logged in on or after that day (a run missed while it was off happens once on the next tick), and so does `status` when no other task gives a wake). **Workbench never runs `sudo` or changes a power setting**; the person runs the line.
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
