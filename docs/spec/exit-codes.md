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
| 5 | Push rejected by origin, or origin's branch is not an ancestor of ours (a force would be needed) | the remote's message on stderr, credentials removed |

Every failure is resumed by running `workbench ship` again: nothing is recorded until the PR exists.
