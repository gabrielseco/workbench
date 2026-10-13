# Friction log

Things done by hand, or that got in the way, while using Workbench on its own repo. This list, not an idea
of what a framework should have, is the roadmap after P2. Add an entry when you do by hand something
Workbench should have done; mark it when a phase covers it.

The direction: **everything is driven through Workbench**. That includes agents operating the CLI on your
behalf, so entries about being usable by an agent (not only by a person at a terminal) belong here too.

| # | Seen | What happened | Points to | Status |
|---|---|---|---|---|
| 1 | `check.sh` round | A script could not be made executable: `chmod` is not in the default tool set, so the run only worked after `Bash(chmod +x scripts/check.sh)` was added to the project config by hand | Goals that create scripts need a way to ask for a tool; or a profile | open |
| 2 | `check.sh` round | The run's first attempt used a shell heredoc to create files and was denied; it recovered with the file tools | The rules text could say "create files with the file tools" | open, minor |
| 3 | `check.sh` round | A run does not read `AGENTS.md` or `CLAUDE.md` (safe mode), so repo conventions reach it only if the goal repeats them | Load the project's instructions file whole, read from the committed base, recorded by hash in `turn.started` ([spec](../spec/goal-file.md), "Project instructions") | closed |
| 4 | `check.sh` round | A run cannot push or open a PR; `deliver` did it by hand | [P2.5](P2.5-ship.md) | planned |
| 5 | after merge | The merged thread had to be ended with `abandon`, so its log says "abandoned" for work that shipped | P2 `accept`; P2.5 `pr.opened` | planned |
| 6 | `check.sh` round | `review.decision` records `"by": "user"` even when an agent ran the command, so the log cannot tell who approved or abandoned | Record the actor (user, agent name) on decisions and on `goal.approved` | open |
| 7 | `check.sh` round | A goal's `base` is a committed branch: work that depends on an unmerged PR needs `--base <branch>`, and the checkout must have no tracked changes to start a thread, so comparison work had to live in a second worktree | Documented behaviour; revisit if it keeps costing time | open |
| 8 | `check.sh` round | Criteria proofs are free text, so "it fails correctly" and "works from another directory" were claimed by reading and had to be re-run by hand before merging | `later/proof.md` (typed proofs the runner can execute) | deferred |
| 9 | `check.sh` round | `check_command` must be one plain command, so `build && test` needed a wrapper script first | Fine as is; the wrapper is now `scripts/check.sh` | closed |
| 10 | whole loop | The CLI has no machine-readable output (`--json`) and some commands assume a terminal, which makes it harder for an agent to drive | Stable `--json` for `status`, `log`, `review`; non-interactive confirmation flags | open |

## How to use it

- Add a row when you notice the friction, with where you saw it. Keep "what happened" to facts.
- A row is closed when a phase's acceptance criteria cover it, not when it is written into a plan.
- Before starting a phase, read the open rows: some are cheaper to fix inside the phase than after it.
