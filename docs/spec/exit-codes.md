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

Every command can also exit 2 for a wrong command line or config, and 1 for an unexpected failure.
Only what is specific to the command is listed.

**Setup**

- `new`: 6 the target is not empty, or its parent is inside another repository (`--nested` allows that).
- `init`, `config`, `version`: only 0, 1 and 2.
- `doctor`: 1 the declared setup or check did not pass, or its worktree could not be removed; 3 stopped
  by Ctrl-C; 6 a thread is still active, another doctor is running, or there is no config.

**One thread**

- `goal new`: 6 the name is taken, another thread is active, or `doctor` is running.
- `goal approve`: 2 the goal is invalid; 6 a proof names a command a run cannot execute
  (`--allow-unrunnable-proofs` goes ahead); 7 no such thread.
- `run`, `send-back`: 1 the turn ended `failed` or `interrupted`, setup failed, or `claude` was not found;
  3 stopped; 4 timed out; 5 over budget; 6 a live runner, the goal is not approved, a proof names a command
  the run cannot execute, or feedback is needed (`run` after a successful turn) or has nothing to follow
  (`send-back` before any turn); 7 no such thread. `send-back` also 2 for a missing note or a bad `--budget`.
- `stop`: 7 no such thread. "Nothing is running" is not an error: 0.
- `log`, `status`, `review`: 7 no such thread, event or patch path (also `--json`, and `status`/`review` with
  no threads at all in `--json` mode).
- `accept`: 1 the commit failed, so nothing was accepted; 6 no terminal to ask on (pass `--yes`), nothing to
  accept, the thread ended, or it changed after it was shown; 7 no such thread. `-m` only applies when
  there is something left to commit.
- `ship`: 6 a live runner, the worktree is missing or on another branch, uncommitted work, no `origin`,
  `gh` missing or not logged in, or no terminal to ask on (pass `--yes`); 10 not accepted (still active,
  discarded, abandoned, unknown, or none waiting); 11 already shipped, the recorded URL is the last line of
  stdout; 12 origin rejected the push or its branch is not an ancestor of ours. With `--watch` (`-w`):
  0 every check passed or was skipped; 1 answered no at the prompt (no PR was made, so 0 would claim passing
  checks) or three failed polls in a row; 13 a check failed or was cancelled; 14 checks were still running at
  the time limit, or none appeared within two minutes.
- `clean`: 1 GitHub could not be asked about some threads (they were kept). A dry run is 0.
- `discard`: 1 the worktree or branch could not be removed; 6 no terminal to ask on (pass `--yes`), the thread
  has already ended, or it has a live runner; 7 no such thread.
- `abandon`: 1 git refused to remove the worktree because it has uncommitted changes (`--force` removes it
  anyway); 6 the thread has already ended; 7 no such thread.

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
