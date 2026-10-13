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
| 3 | `check.sh` round | A run does not read `AGENTS.md` or `CLAUDE.md` (safe mode), so repo conventions reach it only if the goal repeats them | Load the project's instructions file whole, read from the committed base, recorded by hash in `turn.started` | done: read whole from the base commit, hash in `turn.started` |
| 4 | `check.sh` round | A run cannot push or open a PR; `deliver` did it by hand | [P2.5](P2.5-ship.md) | planned |
| 5 | after merge | The merged thread had to be ended with `abandon`, so its log says "abandoned" for work that shipped | P2 `accept`; P2.5 `pr.opened` | planned |
| 6 | `check.sh` round | `review.decision` records `"by": "user"` even when an agent ran the command, so the log cannot tell who approved or abandoned | Record the actor (user, agent name) on decisions and on `goal.approved` | open |
| 7 | `check.sh` round | A goal's `base` is a committed branch: work that depends on an unmerged PR needs `--base <branch>`, and the checkout must have no tracked changes to start a thread, so comparison work had to live in a second worktree | Documented behaviour; revisit if it keeps costing time | open |
| 8 | `check.sh` round | Criteria proofs are free text, so "it fails correctly" and "works from another directory" were claimed by reading and had to be re-run by hand before merging | `later/proof.md` (typed proofs the runner can execute) | deferred |
| 9 | `check.sh` round | `check_command` must be one plain command, so `build && test` needed a wrapper script first | Fine as is; the wrapper is now `scripts/check.sh` | closed |
| 10 | whole loop | The CLI has no machine-readable output (`--json`) and some commands assume a terminal, which makes it harder for an agent to drive | Stable `--json` for `status`, `log`, `review`; non-interactive confirmation flags (`--yes` exists on `accept` and `discard`) | open, before P3 |
| 11 | portability | A fresh worktree has no dependencies, build outputs or gitignored files, and git hooks run in it. This repo has no packages and no hooks, so it never showed | [`later/portability.md`](../later/portability.md): `setup_command`, secrets for the check only, a hooks setting, stack detection in `init` | deferred |
| 12 | P2 review of the CLI | The verbs overlap and the target is not uniform: `run --feedback`, `send-back` and `goal approve` all move a thread on; `abandon` (keeps the branch), `discard` (deletes it) and `accept` all end one, and the names do not say which; `review` falls back to the latest thread while `accept` needs the active one | Decide the verbs from what the portability probe and a few real tasks confuse, then rename once, with aliases | open, wait for use |
| 13 | P2 review of the CLI | Exit codes differ (`run` has 3, 4 and 5, the rest 0, 1, 2), and errors go to stderr in a different shape from normal output, so a script or test cannot tell "refused" from "failed" | One table of exit codes in the spec; errors as one line on stderr with a stable prefix, and in `--json` mode as an object | open, do with #10 before P3 |
| 14 | P2 review of the CLI | `Commands` was at SwiftLint's type-body limit while task 8 was added, so `discard` moved to its own file | Split `Commands` by area (thread lifecycle, review, ending) when `ship` and `--watch` land | open, with P2.5 |
| 15 | P2 review of the CLI | Long notes and commit messages are one-liners: `$EDITOR` cannot get a terminal through `Spawner` (stdin `/dev/null`, own process group) | `-F <file>` or `-` for stdin on `send-back` and `accept`; an editor only with a design discussion | open, minor |
| 16 | P2 review of the CLI | Editing the goal after approval silently returns it to draft, so a one-line fix needs `goal approve` again and nothing says why a run was refused until it is tried | `status` and `review` say "goal changed since approval" next to the next step (review already does) | open, minor |
| 17 | accept (P2 task 6) | An accepted thread keeps its worktree for `ship`, and nothing removes it afterwards; `discard` refuses an ended thread because it would delete accepted work | `ship` (or a `clean` step) removes the worktree once the branch is on `origin`, recorded in the log | open, with P2.5 |

## How to use it

- Add a row when you notice the friction, with where you saw it. Keep "what happened" to facts.
- A row is closed when a phase's acceptance criteria cover it, not when it is written into a plan.
- Before starting a phase, read the open rows: some are cheaper to fix inside the phase than after it.
