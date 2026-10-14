# Exit codes

`workbench ship` (P2.5). Other commands use 0, 1 and 2; `run` and `send-back` have their own 3 to 5
(see friction #13: to be unified).

| Code | Meaning | Prints |
|---|---|---|
| 0 | Shipped; or the person answered no at the prompt, which prints `nothing changed` and no URL (as `accept` and `discard` do), so a script that needs a PR should use `--yes` and read the last line | the PR URL as the last line of stdout |
| 1 | Any other failure: no terminal and no `--yes`, `gh` missing or logged out, no `origin`, dirty worktree, `gh` failed, timeout | the reason on stderr |
| 2 | Usage: unknown option or argument | the reason on stderr |
| 3 | Thread not accepted (active, discarded, abandoned, unknown, or none waiting) | the reason on stderr |
| 4 | Already shipped | the reason on stderr, then the recorded URL as the last line of stdout |
| 6 | `--watch`: a check failed or was cancelled | the final list of checks on stdout, the reason on stderr |
| 7 | `--watch`: checks still running at the time limit, or none reported within two minutes | the list so far, the reason on stderr |
| 5 | Push rejected by origin, or origin's branch is not an ancestor of ours (a force would be needed) | the remote's message on stderr, credentials removed |

`--watch` is read-only: no event, no file. Exit 0 with `--watch` means every check passed (or was skipped). It
ends at 30 minutes by default (`--timeout` 1 to 240), polls every 15 s (`--interval` 1 to 300) and gives up
with exit 1 after three failed polls in a row.

Every failure is resumed by running `workbench ship` again: nothing is recorded until the PR exists.
