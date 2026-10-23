# Exit codes and errors

A code means one thing everywhere; the table says what. What each command can return is under
[By command](#by-command).

| Code | Kind | Meaning |
|---|---|---|
| 0 | | Done. Also: the person answered no at a prompt and `nothing changed` was printed. |
| 1 | `failed` | Something went wrong that is not one of the rows below: git, `gh` or the network failed, a timeout, a partial result, a turn that ended `failed` or `interrupted`. |
| 2 | `usage`, `invalid-config`, `invalid-goal` | The command line, `config.toml` or the goal file is wrong. |
| 3 | `stopped` | A turn or `doctor` was stopped. |
| 4 | `timed-out` | The turn timed out. |
| 5 | `budget-exceeded` | The turn went over its budget. |
| 6 | `refused` | A precondition is not met and nothing was changed. |
| 7 | `not-found` | The thread, event or file named does not exist. |
| 10 | `not-accepted` | `ship`: the thread is not accepted. |
| 11 | `already-shipped` | `ship`: already shipped. |
| 12 | `push-rejected` | `ship`: origin rejected the push. |
| 13 | `check-failed` | `ship --watch`: a check failed. |
| 14 | `no-result` | `ship --watch`: no result in time. |
| 15 | `findings` | `pr-review`, `review-stage`: the reviewer found something to fix. |

## Help

`workbench help`, `workbench help <command>` and `workbench <command> --help` (or `-h`) print help on stdout and exit 0.
Help needs no project, reads nothing and writes nothing. A command's help is its own entries in the usage block
(`goal`, `grant` and `plan` have several forms; `help plan show` prints that form alone), then `changes:`,
`example:`, `--json:` and `exit:` lines. `--help` or `-h` that is an option's value (`run --feedback --help`) is a value;
`log -f` is a flag. `help <unknown>` is a `usage` error that lists the commands.

A `usage` error stays one line on stderr (or one `error.message` with `--json`) and, for a known command, ends with that
command's synopsis and `(workbench help <command>)`.

## By command

One table per command: the codes it can return. Any command can also exit 1 for an unexpected failure
(git, the disk).

### `new`

| Code | Kind | When |
|---|---|---|
| 0 |  | project created |
| 2 | `usage` | wrong command line |
| 6 | `refused` | the target is not empty, or its parent is inside another repository (`--nested` allows that) |

### `init`, `config`, `version`

| Code | Kind | When |
|---|---|---|
| 0 |  | done |
| 2 | `usage`, `invalid-config` | wrong command line, or a config that does not parse |

### `doctor`

| Code | Kind | When |
|---|---|---|
| 0 |  | the declared setup, check and verify passed (review-stage warnings never change the code) |
| 1 | `failed` | the setup, check or verify did not pass, or Screen Recording is missing for a desktop app, or its worktree could not be removed |
| 2 | `usage`, `invalid-config` | wrong command line or config |
| 3 | `stopped` | stopped by Ctrl-C |
| 6 | `refused` | a thread has a live run (a turn or check), another doctor is running, or there is no config |

### `goal new`

| Code | Kind | When |
|---|---|---|
| 0 |  | thread created |
| 2 | `usage` | wrong command line, or `--from` names a file whose `budget_usd`, `turn_timeout_min` or `model` is not valid (the message names the key; nothing is created) |
| 2 | `invalid-goal` | the `--from` file is not a well-formed goal |
| 6 | `refused` | the name is taken, another thread is active, or `doctor` is running |

### `goal approve`

| Code | Kind | When |
|---|---|---|
| 0 |  | approved |
| 2 | `invalid-goal` | the goal file does not parse or is incomplete |
| 6 | `refused` | a proof names a command a run cannot execute (`--allow-unrunnable-proofs` goes ahead) |
| 7 | `not-found` | no such thread |

### `run`

Each turn also puts a read-only copy of the approved goal at `.workbench/goal-copy/goal.md` in the thread's worktree (replaced
on every turn, so an edit to it lasts until the next one and never reaches the goal the approval covers), so an editor
opened with `open` shows the goal beside the diff. `.workbench/` is already kept out of git, so no run, `accept` or
`ship` commits it; when git would not ignore the path (the project un-ignored it) nothing is written.

| Code | Kind | When |
|---|---|---|
| 0 |  | the turn succeeded |
| 1 | `failed` | the turn ended `failed` or `interrupted`, setup failed, or `claude` was not found |
| 2 | `invalid-goal`, `invalid-config` | the goal or config is wrong |
| 3 | `stopped` | the turn was stopped |
| 4 | `timed-out` | the turn timed out |
| 5 | `budget-exceeded` | the turn went over its budget |
| 6 | `refused` | a live runner, the goal is not approved, a proof names a command the run cannot execute, or the thread already has a successful turn and no `--feedback` was given |
| 7 | `not-found` | no such thread |

### `send-back`

| Code | Kind | When |
|---|---|---|
| 0 |  | the turn succeeded |
| 1 | `failed` | the turn ended `failed` or `interrupted`, setup failed, or `claude` was not found |
| 2 | `usage`, `invalid-goal`, `invalid-config` | no note, a bad `--budget`, or a wrong goal or config |
| 3 | `stopped` | the turn was stopped |
| 4 | `timed-out` | the turn timed out |
| 5 | `budget-exceeded` | the turn went over its budget |
| 6 | `refused` | a live runner, a proof names a command the run cannot execute, or no turn has run yet |
| 7 | `not-found` | no such thread |

### `stop`

| Code | Kind | When |
|---|---|---|
| 0 |  | a stop was requested, or nothing was running |
| 7 | `not-found` | no such thread |

### `log`, `status`, `review`

| Code | Kind | When |
|---|---|---|
| 0 |  | done |
| 2 | `usage` | wrong command line |
| 7 | `not-found` | no such thread, event or patch path; with `--json`, also when there are no threads at all |

`review` lists the commits on the thread's branch that are not on its base under `Commits` (between the
criteria and the diff, at most 10); `review --json` has them as `commits` (`[{sha, subject}]`, see `cli-json.md`).

### `open`

| Code | Kind | When |
|---|---|---|
| 0 |  | the editor's launcher returned 0 (`opened <path> in <editor>`), or `--print` printed the path |
| 1 | `failed` | the launcher exited non-zero (its last output line is in the message), was killed, could not be started, or did not return within 10 seconds (it is stopped) |
| 2 | `usage`, `invalid-config` | `--editor` with `--print`, a bad `--editor` value, or a bad `editor` in the project's or the global config (named in the message) |
| 6 | `refused` | nothing is launched: the thread has no worktree (shipped, accepted, discarded, abandoned, or not run yet; the message points to `--goal`), with `--goal` the thread has no `goal.md`, its worktree resolves outside `.workbench/worktrees/`, no editor is set (pass `--editor`, set `editor`, or use `--print`), no active thread, or the editor cannot be found (the message names what was tried) |
| 7 | `not-found` | no such thread |

### `grant`

| Code | Kind | When |
|---|---|---|
| 0 | | listed, or the decision is on record (also when the same decision already was) |
| 2 | `usage` | no or more than one of `--once`, `--thread`, `--never`; a scope without a number; a target that is not a number like `3` or `3.2` |
| 6 | `refused` | the thread has ended or a run is live; a compound named whole (grant a part); text that cannot be written as a fixed pattern; a pattern `[tools] denied` covers or the project's tools cannot take; `unsafe` without `--allow-dangerous`, or `unsafe` with `--thread` |
| 7 | `not-found` | no such thread, denial number or part |

### `judge`

| Code | Kind | When |
|---|---|---|
| 0 |  | a verdict was recorded and printed |
| 1 | `failed` | no verdict this time: no `claude`, a timeout, a budget stop, or an answer that was not usable (recorded, with the reason) |
| 2 | `usage` | wrong command line, or a `--model` or `--budget` that is not valid |
| 6 | `refused` | no turn has run, the turn was judged already (`--again` asks once more), a run is live, or another command holds the thread (a second judge, a send-back) |
| 7 | `not-found` | the thread named does not exist |

### `verifier`

| Code | Kind | When |
|---|---|---|
| 0 |  | the verifier ended on its own with an answer; its report and files were printed and recorded |
| 1 | `failed` | no report this time: no `claude`, a timeout, a stop, a crash, a budget stop or an answer that was not usable (recorded, with the reason) |
| 2 | `usage` | wrong command line |
| 6 | `refused` | the project turned the verifier off (`[verifier] enabled = false`); no turn has run; the turn was verified already (`--again` runs it once more); the thread has no worktree; the skill is missing, empty, a symlink or too large at the base commit; a run is live or another command holds the thread (a second verifier, a judge, a send-back) |
| 7 | `not-found` | the thread named does not exist |

### `plan`

| Code | Kind | When |
|---|---|---|
| 0 | | a plan was recorded and printed |
| 1 | `failed` | no plan this time: no `claude`, the base commit could not be read or checked out, a stop, a timeout, a budget stop, or an empty answer (recorded, with the reason) |
| 2 | `usage` | wrong command line, or a `--model` or `--budget` that is not valid |
| 6 | `refused` | the goal is a draft or changed since approval, this goal has a plan already (`--again` makes another), the thread has ended, a run is live, or another command holds the thread (a judge, another plan) |
| 7 | `not-found` | the thread named does not exist |

### `plan show`, `plan edit`

| Code | Kind | When |
|---|---|---|
| 0 | | `show` printed the plan (or said there is none); `edit` wrote the draft or recorded the edit |
| 2 | `usage` | wrong command line, such as `--apply` with `--from` |
| 6 | `refused` | `edit`: there is no plan to edit, no draft to apply, an empty or unchanged text, an unreadable file, a draft or changed goal, an ended thread, a run is live, or another command holds the thread |
| 7 | `not-found` | the thread named does not exist |

### `pr-review`

| Code | Kind | When |
|---|---|---|
| 0 |  | the review ended `VERDICT: CLEAN` (recorded, findings printed) |
| 1 | `failed` | no verdict this round: no `codex`, the branch moved while the review was starting, Codex was at capacity three times, crashed, timed out, was stopped, or its answer did not end in exactly one `VERDICT:` line (recorded, with the reason; it counts as a round). Also: origin could not be read |
| 2 | `usage` | wrong command line, or a `[pr_review]`, `[review]` or `[review.stage.<name>]` config that is not valid |
| 6 | `refused` | nothing was spawned or recorded: the thread has no recorded pull request, `max_rounds` reviews of this pull request already ran (`--again` does not lift that), the branch was reviewed as it is (`--again` asks once more), origin no longer has the branch, a run is live, or another command holds the thread (a judge, another review) |
| 7 | `not-found` | the thread named does not exist |
| 15 | `findings` | the review ended `VERDICT: FIX`: the findings are printed and recorded |

### `review-stage <name>`

The same codes as `pr-review`, for one round of the stage `<name>` (`review-stage pr-review` is `pr-review`), with
these differences:

| Code | Kind | When |
|---|---|---|
| 0 |  | the review ended `VERDICT: CLEAN`, or the stage was skipped because its `applies_to` matches no file the pull request changes (recorded as `skipped`, never as clean; no reviewer ran) |
| 1 | `failed` | as `pr-review`, and also: the stage reads `proof` and the latest proof (the verifier's) left no PNG, is from before the latest turn, or never ran |
| 2 | `usage` | no stage name, or the `pr-review` cases |
| 6 | `refused` | `<name>` is not in `review.stages` (nothing runs), `max_rounds` of this stage already ran for this pull request (counted over its own rounds; `--again` does not lift that), or the `pr-review` cases |

### `accept`

`-m` only applies when something is left to commit; work the agent already committed keeps its messages. Given
with nothing to commit, `accept` still accepts (exit 0) and prints, after its result,
`-m ignored: the work was already committed (<n> commit(s) on <branch>); nothing to commit`.

| Code | Kind | When |
|---|---|---|
| 0 |  | accepted, or the answer at the prompt was no (`nothing changed`) |
| 1 | `failed` | the commit failed, so nothing was accepted |
| 2 | `usage` | wrong command line |
| 6 | `refused` | no terminal to ask on (pass `--yes`), nothing to accept, the thread has ended, or it changed after it was shown |
| 7 | `not-found` | no such thread |

### `ship`

| Code | Kind | When |
|---|---|---|
| 0 |  | the PR is open (and with `--watch`: every check passed or was skipped) |
| 1 | `failed` | git, `gh` or the network failed; with `--watch`: the answer at the prompt was no (no PR was made, so 0 would claim passing checks), or three failed polls in a row |
| 2 | `usage` | wrong command line |
| 6 | `refused` | a live runner, the worktree is missing or on another branch, uncommitted work, no `origin`, `gh` missing or not logged in, the goal's base (the branch the pull request would target) is not on `origin` (push it first or change the goal's base; checked before anything is pushed, and nothing is recorded), or no terminal to ask on (pass `--yes`) |
| 7 | `not-found` | no such thread |
| 10 | `not-accepted` | the thread is not accepted: still active, discarded, abandoned, unknown, or none waiting |
| 11 | `already-shipped` | the recorded URL is the last line of stdout |
| 12 | `push-rejected` | origin rejected the push, or its branch is not an ancestor of ours (for a thread that continues a branch: the branch moved after the thread started) |
| 13 | `check-failed` | `--watch` (`-w`): a check failed or was cancelled |
| 14 | `no-result` | `--watch` (`-w`): checks were still running at the time limit, or none appeared within two minutes |

With `--review-loop` (not with `--watch`) the same command goes on after the pull request is open, and its exit code is how the loop stopped:

| Code | Kind | The loop stopped because |
|---|---|---|
| 0 |  | the review is clean, or the person answered no before a push (`nothing pushed` is printed and the follow-up waits for them) |
| 1 | `failed` | the reviewer gave no verdict (no `codex`, a crash, no `VERDICT:` line), or a follow-up's turn failed |
| 2 | `usage` | `--review-loop` with `--watch` or `--screenshots` |
| 3, 4, 5 | `stopped`, `timed-out`, `budget-exceeded` | Ctrl-C ended the review or the follow-up's turn, or the turn timed out or went over its budget |
| 6 | `refused` | there is no terminal to ask on and no `--yes` (nothing is spent), or `pr-review` refused (no pull request, a run is live) |
| 13 | `check-failed` | the follow-up's check did not pass; nothing was pushed and the follow-up is left awaiting review |
| 15 | `findings` | findings are left: `max_rounds` is reached with the last review still `VERDICT: FIX`, or a follow-up changed nothing so the findings were not acted on |

### `clean`

| Code | Kind | When |
|---|---|---|
| 0 |  | done, or a dry run |
| 1 | `failed` | GitHub could not be asked about some threads; they were kept |
| 2 | `usage` | wrong command line |

### `discard`

| Code | Kind | When |
|---|---|---|
| 0 |  | discarded, or the answer at the prompt was no |
| 1 | `failed` | the worktree or branch could not be removed |
| 2 | `usage` | wrong command line |
| 6 | `refused` | no terminal to ask on (pass `--yes`), the thread has ended, or it has a live runner |
| 7 | `not-found` | no such thread |

### `abandon`

| Code | Kind | When |
|---|---|---|
| 0 |  | abandoned |
| 1 | `failed` | git refused to remove the worktree because it has uncommitted changes (`--force` removes it anyway) |
| 2 | `usage` | wrong command line |
| 6 | `refused` | the thread has already ended |
| 7 | `not-found` | no such thread |

## Errors

Text mode: one line on stderr, `workbench: <kind>: <message>`; a message that has several lines (a goal's
problems) is joined with `; `. `run` and `send-back` also print their turn's outcome this way (kinds `failed`,
`stopped`, `timed-out`, `budget-exceeded`).

`--json` mode (`status`, `review`, `log`): one object on stdout, nothing on stderr:

```json
{"v": 1, "error": {"kind": "not-found", "code": 7, "message": "no thread 'g-x'"}}
```

## Notes

`ship --watch` (short form `-w`) is read-only: no event, no file. It ends at 30 minutes by default (`--timeout` 1 to 240),
polls every 15 s (`--interval` 1 to 300) and gives up with exit 1 after three failed polls in a row.
With `--watch`, answering no at the prompt exits 1 (no PR was made, so 0 would claim passing checks), and a
named thread is never replaced by another one.

Every `ship` failure is resumed by running `workbench ship` again: nothing is recorded until the PR exists, except
`branch.ahead` (commits added after `accept`), which is written once per branch head before the push.
