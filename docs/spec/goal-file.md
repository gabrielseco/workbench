# Goal file

A goal is one markdown file per thread: `goal.md`. It is written by you (or drafted by Claude and edited
by you), then **approved**. Nothing runs before approval, and a change after approval returns it to draft.

## Shape

```markdown
---
id: g-2026-10-12-retry-backoff
title: Add retry with backoff to the sync client
status: approved            # draft | approved
base: main                  # branch the worktree is cut from
budget_usd: 5.00            # hard cap passed to the CLI
turn_timeout_min: 30        # runner kills the turn after this
model: opus                 # optional; --model for every turn of this thread
approved_at: 2026-10-12T20:10:00Z
approved_hash: 3f2a...      # hash of everything below the front matter
---

## Request

Add exponential retry with jitter to `SyncClient.fetch`, max 5 attempts.

## Criteria

- [c1] `SyncClient.fetch` retries on 5xx and network errors, not on 4xx.
  - proof: test `SyncClientTests.retries*` pass
- [c2] Delay grows exponentially with jitter and is capped at 30s.
  - proof: unit test with injected clock
- [c3] The settings screen shows no change.
  - proof: screenshot of Settings

## Out of scope

- Changing the request timeout.
- Retrying uploads.
```

## Rules

- **Criteria are checkable.** Each has an id (`c1`…) and a `proof` line saying how it will be shown.
  `proof` is free text for now; typed proofs (`check:`, `screenshot:`, `diff:`) are described in
  [`later/proof.md`](../later/proof.md).
- **Approval binds a hash.** `approved_hash` covers the body (request, criteria, out of scope) and the front
  matter fields that change what runs (`base`, `budget_usd`, `turn_timeout_min`). Edit any of them
  and the status is `draft` again.
- **Out of scope is part of the contract.** The runner puts it in the prompt and the review shows it.
- **The inputs are the goal and the project's instructions file.** The runner builds the first prompt from
  the goal, and puts the repository's `AGENTS.md` (else `CLAUDE.md`) after "Out of scope" under
  `## Project instructions`. Nothing else installed on the machine reaches a run. See "Project
  instructions" below.

## Parsing details

Implemented in `Sources/WorkbenchCore/Goal/`.

- **Front matter is a small subset, not YAML.** `key: value`, one per line, known keys only (unknown and
  duplicate keys are errors, so a typo like `budjet_usd` is caught). A comment starts at `#` after two or
  more spaces, so `title: Fix #12` stays intact. Quote a value to be safe: `title: "Fix  # twelve"`.
- **Required:** `id`, `title`, `base`, `budget_usd`, `turn_timeout_min`. `status` defaults to `draft`.
  **Optional:** `model`, a model name or alias (`opus`, `claude-opus-5-5`; no leading `-`, no spaces). It
  wins over the config's `model`, which wins over the CLI default, and applies to every turn of the thread,
  send-backs included. The turn's `argv` in `turn.started` shows what ran.
- **Unsafe values are rejected, not escaped.** `id` becomes a directory name and `base` goes into git
  arguments, so `id` is letters, digits, `.`, `_`, `-` (max 100, must start alphanumeric) and `base` may not
  start with `-` or contain `..` or whitespace. `budget_usd` is a positive number, `turn_timeout_min` a whole
  number from 1 to 1440.
- **Criteria** are `- [c<N>] text` with an indented `- proof: ...` line. Ids are unique. Text and proof may
  wrap onto indented continuation lines. A criterion without proof is an error.
- **Out-of-scope bullets wrap like criteria.** An indented line directly under a `- ` bullet continues it;
  any other line in the section is an error.
- **Approve warns about proofs that cannot run.** `workbench goal approve` reads the backticked commands in
  each `proof:` and prints `warning: [c2] proof names ... ` for one the tool set would not let a run
  execute: denied by a `[tools] denied` pattern, absent from `allowed` (the entry that would permit it is
  named), or `Bash` not available. A span counts as a command when its first word is an executable the
  tool set already names or a path under `./`, `scripts/` or `bin/`, so code identifiers in backticks are
  left alone. A span joined with `&&`, `||`, `;` or `|` is judged part by part. It is a warning: the goal is
  approved either way, `check_command` counts as allowed, and approving an already approved goal repeats the
  warnings, since the config is not in the hash.
- **Errors are collected**, in file order, with line numbers, so one pass fixes the file.
- **Approval state** is derived on every read, never trusted from the file:
  `draft` (not approved), `approved` (status is approved and `approved_hash` matches the content), `stale`
  (status says approved but the hash is missing or differs). Only `approved` runs.
- **What the hash covers:** a version tag, `base`, `budget_usd` (as a number, so `5` equals `5.00`),
  `turn_timeout_min`, `model` (only when set, so a goal without one keeps its hash), and the body after the
  front matter. Line endings, trailing whitespace and blank
  lines at the edges are normalized first. `title` and `id` are not covered, so renaming a goal does not
  revoke approval.
- **Approving rewrites only** `status`, `approved_at` and `approved_hash`; the body and the author's
  comments are kept as written. Approving an already approved goal changes nothing.

## Tool permissions

One fixed set per project, in `.workbench/config.toml` (no named profiles until there is a real need).
`Config.exampleTOML` is the starting point.

```toml
check_command = "scripts/check.sh"      # optional; written exactly as it will be invoked
# setup_command = "mix deps.get"        # optional; run once in a new worktree before its first turn
default_budget_usd = 5.00               # used when drafting a goal
# claude_path = "claude"                # name on PATH, or an absolute path
# model = "haiku"                       # --model for every turn; a goal's `model` wins; unset = the CLI default
# safe_mode = true                      # default: no CLAUDE.md, skills, plugins, hooks or MCP in runs
# project_instructions = true           # default: Workbench puts AGENTS.md (else CLAUDE.md) in the first prompt
# env_pass = ["ANTHROPIC_API_KEY"]      # extra variables claude may see

[tools]
available = ["Read", "Grep", "Glob", "Edit", "Write", "Bash"]
allowed = ["Read", "Grep", "Glob", "Edit", "Write",
           "Bash(git status:*)", "Bash(git diff:*)", "Bash(git add:*)", "Bash(git commit:*)",
           "Bash(swift build:*)", "Bash(swift test:*)"]
denied  = ["Bash(git push:*)", "Bash(gh pr merge:*)", "Bash(rm -rf:*)"]
```

Notes:

- The runner passes `--permission-prompts none --restricted --tools <available> --allowedTools <allowed>
  --disallowedTools <denied>`; the prompt follows `--`. Anything not allowed is denied automatically, and
  the model is told so. That is the whole permission system.
- **`--safe-mode --disable-slash-commands` are passed unless `safe_mode = false`.** They remove everything
  installed on the machine from the run (CLAUDE.md, skills, plugins, hooks, MCP servers, custom agents).
  Measured in task 9: a two-call job went from about 180k tokens of context to 2k, the same result at
  roughly 1/150th of the list price, and far less of the 5-hour window. It applies only to sessions created
  with it; a resumed session keeps the system prompt it was created with.
- **`--restricted` is always passed and cannot be turned off from the config.** It is what confines the
  file tools to the worktree. Bare `Edit`/`Write` in `allowed` are therefore safe, and without
  `--restricted` they would not be: spike S3 showed they can write anywhere on disk.
- **While working, a run is told to prefer the narrowest check it is allowed.** The "Checking your work"
  section of the first prompt says the full `check_command` is run by Workbench when the turn ends, and that
  the run itself should use it at most once, at the end. Allowing a narrow test command in `[tools]`
  (for Swift: `Bash(swift build:*)`, `Bash(swift test --filter:*)`) is what gives it a fast loop.
- **The check command is a literal prefix.** `check_command = "scripts/check.sh"` becomes
  `Bash(scripts/check.sh:*)`: `scripts/check.sh` and `scripts/check.sh --fast` run; `./scripts/check.sh`,
  `sh scripts/check.sh` and an absolute path are denied (task 4 smoke test). It must be one plain command,
  with no shell operators or quotes. The runner should tell the model the exact string to use.
- **`setup_command` is run by Workbench, not offered to the model.** One plain command, validated like
  `check_command`, run in the new worktree after it is cut and before the first turn: an install step
  (`mix deps.get`, `npm ci`). It uses the check's machinery (minimal environment, merged streams, process
  tree swept) with a 15 minute limit and 1 MiB of output kept in `setup.log`. It is not added to `allowed`,
  and not run again on a send-back. A failure ends `run` with the command's output and exit code 1 before
  any turn is spent; the worktree is kept and the next `run` tries it again. What it writes into the
  worktree is untracked there: keep installs in ignored paths (`deps/`, `node_modules/`), or they show up
  in the diff.
- **The child environment is an allowlist**: `PATH HOME USER LOGNAME SHELL LANG TMPDIR TERM
  CLAUDE_CONFIG_DIR` and `LC_*`, plus whatever `env_pass` names. `USER` and `LOGNAME` are required: without
  them `claude` reports "Not logged in" even though the config dir is set. `SSH_AUTH_SOCK` and every token
  variable are left out on purpose, so a model that gets past the allowlist still holds no credentials.
  A version manager's own variables are dropped too (mise on Elixir sets `MIX_HOME` and `MIX_ARCHIVES`), so a
  `setup_command` that passes in your shell can fail here. A failed setup (exit or signal, not a timeout)
  prints a hint at `env_pass`.
- **`workbench doctor [--base <branch>]` proves the declared config works** before any goal exists. It cuts
  a throwaway worktree (reserved id `doctor`, removed on every path, a crash leftover is replaced by the next
  run) at the base (default: the checked-out branch), runs `setup_command` then `check_command` through the
  same runners, environment and limits a thread uses, and prints each step's result, duration, output tail
  and, for a failed setup, the `env_pass` hint. It also says where `claude_path` resolves, the `model` (or
  the CLI default), and whether `Bash` is in `[tools].available` and the check is not denied. It runs nothing the config does not
  declare, writes no event into a thread and no file into the project, and refuses while a thread is active
  or another doctor holds the project (a lock on `.workbench/`, which also makes `goal new` wait for it). A worktree it cannot remove is an error
  (exit 1) that names the command to remove it by hand.
  A step the config leaves out is reported, not failed; the check is skipped when a declared setup did not
  pass. Exit 0 when everything declared passed, 1 when a step did not, 3 when stopped (`exit-codes.md`).
- Unknown keys, unknown tables and syntax outside the supported TOML subset (dotted keys, inline tables,
  multi-line strings) are errors, reported together with line numbers.
- Bash compound commands, substitutions, redirects and out-of-tree paths were all denied by the CLI in S3
  (18 of 18). We do not re-implement any of that; the worktree and the absence of credentials cover the rest.

## Project instructions

Safe mode keeps `claude` from reading `CLAUDE.md`, so Workbench reads the project's instructions file itself
and includes it in the first prompt. Implemented in `Sources/WorkbenchCore/Thread/ProjectInstructions.swift`.

- **Which file.** `AGENTS.md` at the top level of the repository, else `CLAUDE.md`. The first that is a
  regular file wins; a symlink, a submodule or a directory counts as absent. Neither: no section.
- **Read from the base commit, through git** (`git ls-tree`, `git cat-file`), never the filesystem. The main
  checkout and the worktree, which the run may already have edited, cannot change it. The commit is the one
  the worktree was cut from, recorded in the `worktree.created` event (older threads fall back to the
  merge-base of the thread branch and `base`). A file over 1 MiB is not read (git writes the whole object before we see it) and counts as absent; of a smaller one at most 64 KiB is used.
- **Imports.** A line that is exactly `@<relative path>` is replaced by that file's content. Relative paths
  resolve from the importing file's directory and must stay inside the repository. Absolute paths, `..`
  escapes, symlinks, missing files, directories, a file already included and a depth over 3 are left as
  written and listed in `skipped`. At most 32 files are imported, and none once the text is past the size limit. A line is an import only when it is exactly `@path`: no indentation, no spaces, nothing after it. Lines inside fenced code blocks are not expanded (a fence closes only on a line of the same character that is at least as long) and are listed in `skipped` as "inside a code block".
- **Normalised.** A leading BOM is dropped, CRLF becomes LF, invalid UTF-8 is replaced.
- **Size.** At most 16384 bytes including the marker: cut at a line boundary, with a final line
  `[project instructions truncated at 16384 bytes]`. The import cutoff counts expanded text; a replaced
  import directive does not consume the size limit.
- **Where.** After "Out of scope" and before "Checking your work", under `## Project instructions`, introduced
  by a fixed sentence that says Workbench does the pushing and opening of pull requests after review, so the
  run commits in its worktree and stops.
- **When.** In every prompt built from the goal: the first turn, and a first turn that did not succeed and is
  run again. A feedback turn resumes the session and does not repeat it.
- **Recorded.** Such a turn's `turn.started` has `instructions` (see the event log spec). The text itself is
  in `prompts/turn-N.md`.
- **Opt out.** `project_instructions = false` in `config.toml`.
