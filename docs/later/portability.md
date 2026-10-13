# Portability: other stacks, more projects

**Status:** not started, written down on 2026-10-13 so it is not lost.
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
