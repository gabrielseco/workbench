---
name: pr-review
description: Review a GitHub pull request on the Workbench repo against its actual invariants — the process layer (Spawner, no blocking waits, tree sweep), "a turn always ends", the event log's single writer and spec, untrusted input reaching git or paths, the permission boundary, bounded output, and tests for the failure cases the plan lists. Use when the user asks to "review this PR", "review PR #N", or pastes a PR URL for this repo.
---

# PR Review (workbench)

Diff-scoped review as a senior engineer on this codebase would do it. Scale depth to the diff: a docs fix
gets a quick pass, anything touching `Process/`, `EventLog/`, `Git/`, `Worktree/` or `Thread/` gets the
full list. Don't re-flag what `scripts/check.sh` (CI) already enforces; flag only a suppression of it.

## Step 1 — Load context
- `gh pr view <n> --json number,title,body,headRefName,baseRefName,statusCheckRollup`, `gh pr diff <n>`,
  `gh pr checks <n>`. If CI failed, report why first. If it has not run and the branch is checked out,
  run `swiftlint lint --quiet` on the changed files and `swift test --filter` on their suites (`AGENTS.md`,
  "Shipping a change" step 2); the full `scripts/check.sh` is CI's.
- Read each changed file in full, not just hunks: whether an error path still writes its end record is
  invisible in a diff. Read `AGENTS.md`, and for the phase in question its plan under `docs/plan/` and
  the spec under `docs/spec/`.

## Step 2 — Check against this repo's invariants

**Process layer** (`docs/plan/P1-runner.md`, "Process layer rules")
- Children start only through `Spawner`; no `Process`, `waitUntilExit` or `readDataToEndOfFile` anywhere under `Sources/`. New spawn paths get stdin `/dev/null`, their own group, an explicit
  environment, a timeout with SIGTERM then SIGKILL, and a swept process tree.
- Exit comes from `ChildExitWatcher`; a new place that waits on a child by any other means is a finding.
- A continuation or stream is resumed or finished exactly once on every path (exit, timeout, cancel).
- Anything reading a pipe is bounded and keeps draining after its cap, so the child never blocks.

**A run always ends, and says how**
- Every `turn.started` has one `turn.ended`, and every new "started" record (a check, a decision) has an
  end record and recovery for the case the process died in between. Look for early `return`, `throw`
  and cancellation between the two.
- Result mapping stays total: no path where the outcome is unknown and recorded as a success.

**Event log** (`docs/spec/event-log.md`)
- One writer, no gaps in `seq`, `claude` lines stored verbatim; new kinds and fields are in the spec
  and follow the writer's rules in `LogState`; readers ignore kinds they don't know.
- State is derived from the log, not stored a second time (`session.json` holds the session id only, nothing else).

**Untrusted input**
- Anything that becomes a path, a git argument or a command line comes through `SafeNames` or `Config`
  validation: thread ids, bases, the check command, file names from a diff. Git arguments that are
  paths follow `--`.
- The worktree is Claude's. Anything read from it (scripts, config, hooks) is untrusted; the check
  command and tool set come from `.workbench/config.toml`, never from the worktree.

**Permission boundary**
- The tool set stays one fixed list; `git push`, `gh pr merge` and `rm -rf` stay denied; no new
  environment variable reaches `claude` except through `env_pass`. Flag any new engine that decides
  permissions itself (parsers, canonicalizers): Claude Code decides, Workbench chooses the set.

**Scope**
- One project, one active thread, sequential. Queues, concurrent turns or checks, multi-project lists
  belong in `docs/later/`.

**Swift 6**
- `@unchecked Sendable`, `nonisolated(unsafe)` and `assumeIsolated` need a comment proving why.
  State confined to a queue is touched only on it. Blocking work is not on an actor's executor.

**Tests**
- Each failure case the phase plan lists has a test: hang, crash, SIGTERM ignored, leftover children,
  truncation, kill mid-run, stop before start. Prefer the fake claude (`Sources/fake-claude`) over
  sleeps; a timing assertion needs margin under parallel load (this suite runs in parallel).
- A test for a bug fix fails without the fix. Stream-handling changes are checked against the real
  fixtures in `docs/plan/P1-spikes/fixtures/`.

**Docs**
- Spec and plan change in the same PR as the behaviour. Acceptance boxes are ticked only for what is
  demonstrated.

**Comments** are one line saying why; flag ones restating code, never a missing comment.

Focus on changed code; raise a pre-existing issue only if the diff makes it worse. When unsure of
intent, ask as a question.

## Step 3 — Report
List the findings (or say it's clean), each with a concrete failure scenario: input or state, then the
hang, leak, lost record or wrong result. Don't manufacture issues. If your agent has a structured
findings tool (e.g. Claude Code's `ReportFindings`), report through it (empty array if clean).

## Step 4 — Post only with approval
Ask before posting. Use conventional comments (`issue (blocking):` for correctness, process, security
or data-loss risks; `suggestion:`; `nitpick:`; `praise:`), suffixed with the agent's name
(`[by Claude]`, `[by Codex]`). One review with an inline comment per finding via
`gh api repos/<owner>/<repo>/pulls/<n>/reviews` with `"event": "COMMENT"` and the head `commit_id`;
or, when clean, `gh pr review <n> --comment --body "..."`. Never `APPROVE` or `REQUEST_CHANGES`.
