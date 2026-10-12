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
- **The goal is the only input.** The runner builds the first prompt from the goal and nothing else.

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

One fixed set per project, in `.workbench/config.toml` (no named profiles until there is a real need):

```toml
check_command = "scripts/check.sh"

[tools]
# Built-in tools made available at all (--tools). File tools are confined to the worktree by --restricted.
available = ["Read", "Grep", "Glob", "Edit", "Write", "Bash"]
# Bash patterns that may run (--allowedTools). Everything else is denied automatically.
allowed = ["Bash(git status:*)", "Bash(git diff:*)", "Bash(git add:*)", "Bash(git commit:*)",
           "Bash(swift build:*)", "Bash(swift test:*)"]
denied  = ["Bash(git push:*)", "Bash(gh pr merge:*)", "Bash(rm -rf:*)"]
```

Notes:

- The runner passes `--permission-prompts none --restricted --tools <available> --allowedTools <allowed>
  --disallowedTools <denied>`. Anything not allowed is denied automatically, and the model is told so.
  That is the whole permission system.
- **Never allow file tools by bare name outside `--restricted`.** Spike S3 showed `--allowedTools Read Edit
  Write` lets the model read and write anywhere on disk. `--restricted` confines them to the worktree;
  the fallback is `--permission-mode acceptEdits` with `Read(./**)`. See
  [P1 spikes](../plan/P1-spikes.md).
- `check_command` (P2) is added to `allowed` so Claude can run its own checks.
- Bash compound commands, substitutions, redirects and out-of-tree paths were all denied by the CLI in S3
  (18 of 18). We do not re-implement any of that; the worktree and the absence of credentials cover the rest.
