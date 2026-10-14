# Exit codes and errors

One table for every command. A code means one thing everywhere.

| Code | Kind | Meaning |
|---|---|---|
| 0 | | Done. (Also: the person answered no at a prompt and `nothing changed` was printed, as `accept` and `discard` do; scripts use `--yes`. With `ship --watch`, 0 means every check passed, or was skipped.) |
| 1 | `failed` | `doctor`: the declared setup or check did not pass, or its worktree could not be removed. Something went wrong that is not one of the rows below, including a turn that ended `failed` or `interrupted`: git, `gh` or the network failed, a timeout, a partial result. |
| 2 | `usage`, `invalid-config`, `invalid-goal` | The command line, `config.toml` or the goal file is wrong. |
| 3 | `stopped` | `run`, `send-back`: the turn was stopped. `doctor`: stopped by Ctrl-C. |
| 4 | `timed-out` | `run`, `send-back`: the turn timed out. |
| 5 | `budget-exceeded` | `run`, `send-back`: the budget was exceeded. |
| 6 | `refused` | A precondition is not met and nothing was changed: no terminal to ask on (pass `--yes`), a live runner, a proof naming a command the run cannot execute (`goal approve`, `run`, `send-back`), `doctor` with a thread still active, another doctor running or no config, a dirty worktree, no `origin`, `gh` missing or logged out, the thread ended, nothing to accept. |
| 7 | `not-found` | The thread, event or file named does not exist. |
| 10 | `not-accepted` | `ship`: the thread is not accepted (still active, discarded, abandoned, unknown, or none waiting). |
| 11 | `already-shipped` | `ship`: already shipped. The recorded URL is the last line of stdout. |
| 12 | `push-rejected` | `ship`: origin rejected the push, or its branch is not an ancestor of ours (a force would be needed). |
| 13 | `check-failed` | `ship --watch`: a check failed or was cancelled. |
| 14 | `no-result` | `ship --watch`: checks were still running at the time limit, or none appeared within two minutes. |

## Errors

Text mode: one line on stderr, `workbench: <kind>: <message>`; a message that has several lines (a goal's
problems) is joined with `; `. `run` and `send-back` also print their turn's outcome this way (kinds `failed`,
`stopped`, `timed-out`, `budget-exceeded`).

`--json` mode (`status`, `review`, `log`): one object on stdout, nothing on stderr:

```json
{"v": 1, "error": {"kind": "not-found", "code": 7, "message": "no thread 'g-x'"}}
```

## Notes

`ship --watch` is read-only: no event, no file. It ends at 30 minutes by default (`--timeout` 1 to 240),
polls every 15 s (`--interval` 1 to 300) and gives up with exit 1 after three failed polls in a row.
With `--watch`, answering no at the prompt exits 1 (no PR was made, so 0 would claim passing checks), and a
named thread is never replaced by another one.

Every `ship` failure is resumed by running `workbench ship` again: nothing is recorded until the PR exists.
