# Portability: other stacks, more projects

**Status:** probe 1 (expenses-backend, Elixir) run on 2026-10-14, see the end of this file; nothing built yet. Written down on 2026-10-13 so it is not lost.
**Trigger:** the first time Workbench is used on a repo that is not this one, or when P2 and P2.5 are done,
whichever comes first. P3 (the app) should not be designed before one other repo has been tried.

Workbench is built and proven on one Swift package. Most of it does not know that; a few things do without
looking like it, because this repo never needs them.

## Already portable

| Part | Why |
|---|---|
| Goal file, event log, review flow | no stack knowledge |
| Worktree and git runner | plain git |
| `check_command` | any single command (`npm test`, `mix test`, `pytest -q`) |
| Tool allowlist | per-project config in `.workbench/config.toml`, not code |
| Project instructions | `AGENTS.md`, with `CLAUDE.md` as the fallback |
| Which repo | `Project.locate` finds the repository from any directory; state lives in that repo's `.workbench/`, so two repos share nothing |

## What this repo hides

| # | Problem | Why it is invisible here | What it looks like elsewhere | Likely shape |
|---|---|---|---|---|
| 1 | **A fresh worktree has no dependencies or build outputs.** It is a clean checkout of the committed base. | No packages; a cold build takes about a minute. | Next.js has no `node_modules`, Elixir no `deps/` or `_build`, Python no venv. Each run needs an install the allowlist does not permit. | `setup_command` in the config, run by Workbench after the worktree is cut: bounded, recorded like a check, its failure stops the thread before a turn is spent. |
| 2 | **Gitignored files are not there**: `.env.local`, local database settings, keys. | Nothing needed. | Tests that read the environment fail; an app does not start. | Files made available to the *check* and the setup, not to the model's file tools. Needs its own design: anything in the worktree is readable by the model. |
| 3 | **Git hooks run in the worktree.** | No hooks. | A `pre-commit` (husky, lefthook) that needs installed dependencies makes every `git commit` of the run fail. | `git_hooks = "run" or "skip"`; the check after the turn is the gate either way. |
| 4 | **The environment is a short list** (`PATH`, `HOME`, …). | Swift needs nothing else. | Version managers (nvm, asdf, mise, pyenv) and `JAVA_HOME`, `GOPATH`, `CARGO_HOME` are missing; the run fails until `env_pass` is set. | `workbench init` suggests them per stack; keep `env_pass` explicit. |
| 5 | **One plain command.** `check_command` cannot contain `&&` or a pipe. | `scripts/check.sh` already wraps it. | `cargo test && cargo clippy` needs a wrapper script; a monorepo wants a check per package. | Keep the rule; a per-package check can be a goal field later. |
| 6 | **Review checklists are written for one repo.** `pr-review` and `deliver` name this repo's invariants. | They fit. | Confident, irrelevant findings. | A shared base plus a short per-repo checklist; `scripts/codex-review.sh` already takes the spec as an argument. |
| 7 | **Nothing knows the stack**, so `workbench init` writes a generic config. | One example is enough. | Every repo rediscovers its allowlist by being denied. | Detect `package.json`, `mix.exs`, `Cargo.toml`, `pyproject.toml`, `Package.swift` and propose the allowlist and check command. |

## Many projects

- **State is already per repo**, so nothing global stops two repos running side by side today.
- **One active thread** is one check (`activeThreadID`); the plan calls lifting it "deleting a guard, not a
  migration".
- **The only new storage is a list of project roots**, kept outside any repo, for the app to show. That is
  D6 revisited, and not before one other repo has been used.

## What P2 must not do meanwhile

Keep review, accept and send-back stack-free: a diff, a check result and the criteria. No Swift-specific
paths, no assumption that a check is quick, no assumption that a worktree can build on its own.

## How to try it (when the time comes)

Pick one repo that is not Swift, give Workbench a small real goal, and write every point where it breaks
into this file, in the order they happen. Do not fix anything during the probe: the list is the product.
Good candidates are the Next.js and Elixir repos next to this one.

## Probe 1: expenses-backend (Elixir), 2026-10-14

**Task:** record the crm write operations in the API contract and make them clock-stable, the same kind of
outcome as expenses-backend#323. Base `main`, #323 left unmerged to compare. `check_command = "mix test"`,
`mix test`, `mix format` and `mix api.contract*` allowed. Debug build of Workbench at `6b9f2ee`, real `claude`.

**Result:** turn 1 succeeded ($2.72), check failed in 0s, nothing verified. 19 operations recorded by hand
(`examples.json` +836), one clock fix in `goal.ex`, docs updated, one untracked scratch file. The thread was
neither accepted nor sent back; see below.

**Where it broke, in order** (nothing was fixed during the probe; rows are in
[`FRICTION.md`](../plan/FRICTION.md) #26 to #31):

| # | What happened | Hits problem | Row |
|---|---|---|---|
| 1 | No `deps/` or `_build/` in the worktree; `mix deps.get` was denied (network, and not in the allowlist). The run could not format, test or regenerate anything | 1 | #27 |
| 2 | `UPDATE_API_EXAMPLES=1 mix test <file>`, the documented way to regenerate examples, was denied by the prefix rule | 5, 7 | #28 |
| 3 | Brace expansion, heredocs, `python3`, `env`, `rm` and pipes were denied one call at a time | 7 | #29 |
| 4 | The goal's proofs named commands the worktree could not run; found only when the run said so | none (goal side) | #30 |
| 5 | Out-of-scope bullets cannot wrap; found at `goal approve` | none (spec) | #31 |
| 6 | Progress was invisible from `status` while the turn ran | none (CLI) | #26 |

**What held, stack-free:** goal approval, the worktree and branch, the event log, `review` (diff, denied
tools with the turn and seq, criteria with their proofs), and the model reporting honestly what it could not
prove. It found a real backend gap (`createConcert` and `updateConcert` return `expenseSlug: null` because the
expense association is never loaded), the same kind of finding as #323's schema fixes.

**Not answered:** whether the output matches #323's quality. That needs a green check, which needs problem #1
solved first. Not addressed: #2 (gitignored files; the test database needed none here), #3 (no git hooks in
this repo) and #4 (mise put `mix` on `PATH`, which is in the allowlist).

**Reading:** problem #1 is not cosmetic on a stack with an install step. Without a `setup_command` the first
turn is spent discovering it, and the run's own account of the work is unverifiable. It is the first thing to
build when this file moves from "not started".
