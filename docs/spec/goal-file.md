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
- **The goal and the project's instructions file are the only inputs.** The runner builds the first prompt
  from the goal and, unless turned off, the repository's `AGENTS.md` or `CLAUDE.md` as committed at the
  thread's base (see "Project instructions"). Nothing else on the machine reaches a run.

## Project instructions

Safe mode keeps Claude from reading the repository's own instructions, so Workbench reads the file itself
and puts it in every prompt built from the goal. Implemented in `ProjectInstructionsLoader`.

- **Which file.** `AGENTS.md` at the repository top level, else `CLAUDE.md`. Only the first of the two that
  exists is used, whole; nothing in it is conditional. Skills, `.agents/skills`, user-level and
  parent-directory instructions files are not loaded.
- **Read from the committed base, through git.** The text is the blob at the thread's base commit
  (`git show <base-commit>:<path>` via `GitRunner`), never the filesystem: not the main checkout, which may
  have moved on or be dirty, and not the worktree, where Claude may already have edited the file. So a turn
  built from the goal gets the same text however often it is run.
- **The base commit is fixed when the thread is created.** `thread.created` records `base_commit`, the
  commit `base` pointed at then, and the worktree is cut from that same commit, so the instructions always
  describe the code the run starts from. If the goal's `base` is changed afterwards, or the log has no
  `base_commit` (an older thread), the worktree is cut from `base` as it is at the first run and the
  instructions come from that commit (`git merge-base` of the thread's branch and `base` on later turns).
- **Only regular files.** A symlink (git mode 120000), a submodule, a directory or a missing path counts as
  absent. At most 64 KiB is read from any one blob.
- **`@` imports.** A line that is exactly `@<relative path>`, with no other text or whitespace, is replaced
  by that file's content, as Claude Code does for `CLAUDE.md`. The path is relative to the directory of the
  file the line is in and is looked up in the same commit. Only paths that stay inside the repository are
  followed: no absolute or `~` paths, no `..` escape, no symlink at the path or on the way to it. Imports
  nest to a depth of 3, each file is included at most once (which also ends cycles), and at most 32 files
  are imported. Lines inside fenced code blocks (```` ``` ```` or `~~~`) are never expanded. An import that
  is not followed stays in the text as the literal line and its path is listed in `skipped`.
- **Where it goes.** A `## Project instructions` section after "Out of scope" and before "Checking your
  work", introduced by exactly this sentence: "These are the project's instructions for anyone working in
  this repository. Where they describe pushing, opening or merging pull requests, Workbench does that after
  your work is reviewed: commit in this worktree and stop there."
- **Which turns.** Every turn built from the goal: the first turn, and a retry of a first turn that did not
  succeed. A follow-up turn with feedback resumes a session that has already seen it and does not repeat it.
- **Size and encoding.** Invalid UTF-8 is replaced with U+FFFD, a leading BOM is dropped and CRLF becomes
  LF. The expanded text is capped at 16384 bytes: it is cut at the last line boundary within the cap (or,
  for a single longer line, at a character boundary) and ends with the line
  `[project instructions truncated at 16384 bytes]`.
- **Recorded.** `turn.started` of such a turn carries `instructions` with the file name, the SHA-256 and
  byte count of the text as sent (after expansion, normalization and truncation, marker included),
  `truncated` and `skipped`; `null` when no file was used. The text itself is in `prompts/turn-N.md`.
- **Opt out.** `project_instructions = false` in `.workbench/config.toml` (default `true`): no section, and
  `instructions` is `null`.

## Parsing details

Implemented in `Sources/WorkbenchCore/Goal/`.

- **Front matter is a small subset, not YAML.** `key: value`, one per line, known keys only (unknown and
  duplicate keys are errors, so a typo like `budjet_usd` is caught). A comment starts at `#` after two or
  more spaces, so `title: Fix #12` stays intact. Quote a value to be safe: `title: "Fix  # twelve"`.
- **Required:** `id`, `title`, `base`, `budget_usd`, `turn_timeout_min`. `status` defaults to `draft`.
- **Unsafe values are rejected, not escaped.** `id` becomes a directory name and `base` goes into git
  arguments, so `id` is letters, digits, `.`, `_`, `-` (max 100, must start alphanumeric) and `base` may not
  start with `-` or contain `..` or whitespace. `budget_usd` is a positive number, `turn_timeout_min` a whole
  number from 1 to 1440.
- **Criteria** are `- [c<N>] text` with an indented `- proof: ...` line. Ids are unique. Text and proof may
  wrap onto indented continuation lines. A criterion without proof is an error.
- **Errors are collected**, in file order, with line numbers, so one pass fixes the file.
- **Approval state** is derived on every read, never trusted from the file:
  `draft` (not approved), `approved` (status is approved and `approved_hash` matches the content), `stale`
  (status says approved but the hash is missing or differs). Only `approved` runs.
- **What the hash covers:** a version tag, `base`, `budget_usd` (as a number, so `5` equals `5.00`),
  `turn_timeout_min`, and the body after the front matter. Line endings, trailing whitespace and blank
  lines at the edges are normalized first. `title` and `id` are not covered, so renaming a goal does not
  revoke approval.
- **Approving rewrites only** `status`, `approved_at` and `approved_hash`; the body and the author's
  comments are kept as written. Approving an already approved goal changes nothing.

## Tool permissions

One fixed set per project, in `.workbench/config.toml` (no named profiles until there is a real need).
`Config.exampleTOML` is the starting point.

```toml
check_command = "scripts/check.sh"      # optional; written exactly as it will be invoked
default_budget_usd = 5.00               # used when drafting a goal
# claude_path = "claude"                # name on PATH, or an absolute path
# model = "haiku"                       # --model for every turn; unset = the CLI default
# safe_mode = true                      # default: no CLAUDE.md, skills, plugins, hooks or MCP in runs
# project_instructions = true           # default: AGENTS.md (else CLAUDE.md) from the base commit in the prompt
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
  with it; a resumed session keeps the system prompt it was created with. The project's own instructions
  file still reaches the run, through the prompt ("Project instructions"), unless
  `project_instructions = false`; a non-boolean value is a config error like the other keys.
- **`--restricted` is always passed and cannot be turned off from the config.** It is what confines the
  file tools to the worktree. Bare `Edit`/`Write` in `allowed` are therefore safe, and without
  `--restricted` they would not be: spike S3 showed they can write anywhere on disk.
- **The check command is a literal prefix.** `check_command = "scripts/check.sh"` becomes
  `Bash(scripts/check.sh:*)`: `scripts/check.sh` and `scripts/check.sh --fast` run; `./scripts/check.sh`,
  `sh scripts/check.sh` and an absolute path are denied (task 4 smoke test). It must be one plain command,
  with no shell operators or quotes. The runner should tell the model the exact string to use.
- **The child environment is an allowlist**: `PATH HOME USER LOGNAME SHELL LANG TMPDIR TERM
  CLAUDE_CONFIG_DIR` and `LC_*`, plus whatever `env_pass` names. `USER` and `LOGNAME` are required: without
  them `claude` reports "Not logged in" even though the config dir is set. `SSH_AUTH_SOCK` and every token
  variable are left out on purpose, so a model that gets past the allowlist still holds no credentials.
- Unknown keys, unknown tables and syntax outside the supported TOML subset (dotted keys, inline tables,
  multi-line strings) are errors, reported together with line numbers.
- Bash compound commands, substitutions, redirects and out-of-tree paths were all denied by the CLI in S3
  (18 of 18). We do not re-implement any of that; the worktree and the absence of credentials cover the rest.
