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
| 0 |  | the declared setup and check passed |
| 1 | `failed` | the setup or check did not pass, or its worktree could not be removed |
| 2 | `usage`, `invalid-config` | wrong command line or config |
| 3 | `stopped` | stopped by Ctrl-C |
| 6 | `refused` | a thread is still active, another doctor is running, or there is no config |

### `goal new`

| Code | Kind | When |
|---|---|---|
| 0 |  | thread created |
| 2 | `usage` | wrong command line |
| 6 | `refused` | the name is taken, another thread is active, or `doctor` is running |

### `goal approve`

| Code | Kind | When |
|---|---|---|
| 0 |  | approved |
| 2 | `invalid-goal` | the goal file does not parse or is incomplete |
| 6 | `refused` | a proof names a command a run cannot execute (`--allow-unrunnable-proofs` goes ahead) |
| 7 | `not-found` | no such thread |

### `run`

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

### `accept`

`-m` only applies when something is left to commit; work the agent already committed keeps its messages.

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
| 6 | `refused` | a live runner, the worktree is missing or on another branch, uncommitted work, no `origin`, `gh` missing or not logged in, or no terminal to ask on (pass `--yes`) |
| 7 | `not-found` | no such thread |
| 10 | `not-accepted` | the thread is not accepted: still active, discarded, abandoned, unknown, or none waiting |
| 11 | `already-shipped` | the recorded URL is the last line of stdout |
| 12 | `push-rejected` | origin rejected the push, or its branch is not an ancestor of ours |
| 13 | `check-failed` | `--watch` (`-w`): a check failed or was cancelled |
| 14 | `no-result` | `--watch` (`-w`): checks were still running at the time limit, or none appeared within two minutes |

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

Every `ship` failure is resumed by running `workbench ship` again: nothing is recorded until the PR exists.
