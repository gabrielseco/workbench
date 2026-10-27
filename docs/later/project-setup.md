# Project setup: doctor, guided init, checks by project size

**Status:** `workbench doctor` built (see `docs/spec/goal-file.md`); the rest below is still notes, from a
design conversation on 2026-10-14. Revisits item 7 in
[portability](portability.md) ("detect the stack and propose"), which this replaces.
**Trigger:** the first time a config turns out wrong only after a paid turn (friction #27 was that), or when
a second project is set up by hand.

## Principle: the user declares, Workbench verifies

- **Workbench does not guess what to run.** No stack detection that fills in `check_command`,
  `setup_command`, `env_pass` or the allowlist. A wrong guess is worse than an empty line.
- **The config is the only source of what counts as validated.** `check_command` is the config's string,
  run with the child environment allowlist; nothing in the worktree chooses it.
- **Leaving it unset is a choice, said out loud.** With no `check_command` a turn ends with no check
  evidence.

## `workbench doctor` (built)

Proves the declared setup works before a goal exists.

1. Cut a throwaway worktree at the base commit.
2. Run `setup_command`, then `check_command`, exactly as declared, with the same machinery and environment
   a thread uses (so an `env_pass` mistake shows up here and not in turn 1).
3. Report each step: exit code, duration, the end of the output, the `env_pass` hint on a failed setup.
4. Also report: `claude_path` resolves; `check_command` is covered by `tools.allowed`; which `model` applies
   (set in config, or the CLI default).
5. Clean up the worktree.

It never runs a command the user did not write. Optional later: record a "verified" stamp (config hash and
result) so `goal approve` can say "config unverified".

## Guided `init`

`init` stays a template. After writing it, it points at what to fill in and in what order:

1. `check_command`: what proves a change is not broken.
2. `setup_command`: what a fresh worktree needs (install step), if anything.
3. `env_pass` and `tools.allowed`: only if doctor says so.
4. Run `workbench doctor`.

At most, a hint next to a commented line when a marker file is present ("found `mix.exs`"). A hint is text,
not a value written to the config.

## Checks by project size

`check_command` runs once after every turn, in the worktree, with the turn timeout. It must be one plain
command, so anything composite is a repo-owned script (`scripts/check.sh`, friction #9).

| Project | Per-turn check | Setup | Where the full gate is |
|---|---|---|---|
| Small (this repo, a Swift package, a small Node app) | The whole thing: build, lint, tests. Seconds to a couple of minutes, so run all of it. | `npm ci`, `mix deps.get`, or none | The same check; CI repeats it |
| Large (slow suite, monorepo) | A script that scopes by the files the thread touched: `git diff --name-only $(git merge-base HEAD origin/main)` picks lint on those files, types (usually whole-project, they do not scope), tests related to the changes | Same, cached if possible | CI, after the PR is open (the ship phase already watches it) |

The per-turn check answers "did this turn break the obvious things?". It does not have to be the full gate.

### Open questions for large projects

- **Base for scoping.** Workbench passes the check nothing about the thread's base commit, so a scoping
  script finds it by itself. A `WORKBENCH_BASE` variable would be a cheap addition.
- **Cheap per turn, heavy at the end.** One command runs after every turn today. Options: a second key
  (`final_check_command`, run on the last turn or on `ship`), which keeps both declared; or one command and
  an env flag the script reads (less visible). Lean: the second key, but only once a large project hits it.
- **Literal prefix.** The check is allowed as `Bash(<command>:*)`, so a script must be invoked exactly as
  written in the config.

## Presets by stack (idea)

A named preset per stack (`node`, `elixir`, `swift`) that a config inherits, so the commands and the
allowlist entries are a starting point shared across projects. The user still picks and edits the result,
and an AI assistant can help write the config; Workbench does not choose for them. Later, once two or
three projects have settled on the same shape.

## Not decided

- Whether `doctor` is its own command or `init --verify`.
- Whether `goal approve` blocks on an unverified config or only warns (lean: warn).

## Context

- The default model is not set by `init`: `[agents.run] model` is commented out in `Config.exampleTOML`, so
  `claude` uses its own default. The models in the template are examples only. Setting `model = "opus"` in a
  project's `[agents.run]` pins every coding turn.
