# P1: Runner

**Outcome:** `workbench run` reads the approved goal, runs Claude Code in an isolated worktree, streams
everything to an event log, and always ends in a recorded terminal state. CLI only, no UI.

**Why first:** everything else (review, app) is a view over this. Last time the process layer was the
unproven base under every other layer. This phase makes it boring before anything is built on it.

## Scope

In:
- Swift package with `WorkbenchCore` (library) and `workbench` (CLI).
- One project (the repo you run it in), one active thread: goal parsing and approval hash, worktree, event log.
- The runner: one `claude` process per turn, stop, timeout, budget, crash recovery.
- A fake `claude` for tests and a soak test.

Out: UI, diff and review (P2), thread or project lists, concurrency, profiles beyond one fixed set,
screenshots and verifier, Triage.

## On disk (one project)

```
<repo>/.workbench/                (gitignored)
  config.toml                     check_command, claude path, allowed/denied tools, default budget
  threads/<id>/
    goal.md
    events.jsonl
    session.json                  session id only; everything else is derived from the log
    checks/                       P2
  worktrees/<id>/                 the git worktree, branch `workbench/<id>`
```

The active thread is derived: the newest thread whose log has no terminal decision (accepted, discarded or
abandoned). The runner refuses to start a second thread while one is active. That guard is the entire
single-thread rule, and there is no `current` file to get out of sync.

## Spikes (done: results in [`P1-spikes.md`](P1-spikes.md))

| # | Question | How | Decides |
|---|---|---|---|
| S1 | What exactly does `claude -p --output-format stream-json --verbose` emit, and how does a turn end? Is the `result` line always last? | Run 10 trivial goals, save raw output as fixtures | Parser, `turn.ended` logic |
| S2 | Does `--permission-prompts none` + `--allowedTools` deny cleanly? What does a denial look like in the stream, and does the model recover or stall? | Goal that needs a forbidden tool | `denied_only` result, review UX |
| S3 | What does the allowlist do with `a && b`, `$(...)`, `cd ..`, `git -C /elsewhere`, redirects, absolute paths outside the worktree? | Table of 20 commands against the fixed set | Whether the worktree alone is enough or we need `--add-dir` limits / no credentials |
| S4 | `--session-id` on turn 1 then `--resume <id>` on turn 2: does context carry, and what happens if the first turn was killed? | Two-turn run, plus a killed first turn | Turn model (D3), crash recovery |
| S5 | Do `--max-budget-usd` and exit codes behave as documented when the cap is hit? | Tiny cap | `budget_exceeded` mapping |
| S6 | After SIGTERM to `claude`, are there child processes left (shells, test runners)? | Start a long `sleep` via Bash, then stop | Process groups / kill tree |

Exit criterion: each question has a written answer and a fixture or a script that proves it. Met. S3 found
that bare `Read`/`Edit`/`Write` escape the worktree; the fixed set below avoids them. S6 found that
tool children are outside `claude`'s process group, which changed rules 3 and 4.

## Design

```
CLI ── ThreadStore ── goal.md / events.jsonl / session.json
        │
        └─ Runner (one at a time, by construction)
             ├─ WorktreeManager   git worktree add / remove
             ├─ PromptBuilder     goal → first prompt; feedback → follow-up prompt
             ├─ ProcessRunner     spawn, line reader, stop, timeout, kill tree
             └─ EventLog          append-only writer, seq assignment
```

### Process layer rules (the lessons)

1. **One owner.** `ProcessRunner` owns the child from spawn to terminal event. Nothing else holds the `Process`.
2. **No `waitUntilExit`.** Use the termination handler (or a `DispatchSource` process source) and a single
   `AsyncStream` of lines; exit status arrives as the final event of that stream.
3. **Own process group, and a tree sweep.** Spawn into a new group so `claude` can be signalled alone, but
   tool children are *not* in that group (S6), so a group kill does not reach them. Before escalating,
   record the descendants by ppid and kill them explicitly.
4. **Escalation.** `stop()` sends SIGTERM to `claude` and waits the full 5s: that is the only path that
   cleans tool children (S6). Then SIGKILL to `claude` and the recorded descendants. Both paths end in
   `turn.ended`. On startup, sweep orphans whose cwd is inside `.workbench/worktrees/`.
5. **Single writer.** Only the runner appends to `events.jsonl`. The reader never needs a lock.
6. **Bounded everything.** Max line size, max log size per turn (truncate with a marker), timeout, budget.
7. **A turn cannot end silently.** Wrap the turn in one function whose `defer` writes `turn.ended`.
8. **Children inherit nothing they were not given.** Spawn with `posix_spawn` and
   `POSIX_SPAWN_CLOEXEC_DEFAULT` (macOS only, which is all we target), with explicit file actions for stdin
   (`/dev/null`), stdout and stderr. Foundation's `Process` leaves a window between fork and exec in which
   a child shares our descriptors, including the event log's lock. That showed up as an intermittent
   `alreadyOpen` in the P1 worktree PR (errno `EWOULDBLOCK`, 2 to 7 ms waits), mitigated there with a
   bounded lock wait. This rule is the actual fix, and it is tested: the fake claude reports its open
   descriptors and the test asserts the log is not among them.

### Turn lifecycle

```
approved goal ─▶ turn.started ─▶ claude… ─▶ turn.ended(result)
                       │                          ▲
                       └─ stop / timeout / crash ─┘
```

First turn: `claude -p --session-id <uuid> --output-format stream-json --verbose
--include-partial-messages --permission-prompts none --restricted --tools … --allowedTools …
--disallowedTools … --max-budget-usd N --append-system-prompt <rules> -- "<prompt>"` with the worktree as
cwd and **stdin redirected from `/dev/null`** (otherwise a 3s wait).
Every later spawn, including a retry after a kill, uses `--resume <uuid>` and the feedback as the prompt.
`--session-id` on an existing session exits 1 (S4).

File tools are never allowed by bare name: that lets the model read and write outside the worktree (S3).
`--restricted` confines them to the working directory. Fallback if it breaks a real run:
`--permission-mode acceptEdits` with `Read(./**)`.

Flags verified against `claude` 2.1.296 in S1–S5. Re-run `P1-spikes/scripts/` after a CLI upgrade.

### The fake claude

`Sources/fake-claude/` is a standalone executable (no dependency on `WorkbenchCore`, so a core bug cannot
also break its own test double). It accepts the real CLI's flags, so a test points `claude_path` at it.
`FAKE_CLAUDE` holds comma-separated directives; the full list is the header of its `main.swift`. In short:

| Need | Directive |
|---|---|
| A normal turn (init, assistant, result), echoing the session id and prompt | none |
| Replay a recorded real run, session id rewritten | `fixture=<file>` |
| Hang, crash (no result), SIGKILL itself, non-zero exit, no result line | `hang-after=N`, `crash-after=N`, `die-after=N`, `exit=N`, `no-result` |
| Bad input: non-JSON line, huge line, unterminated last line | `invalid-line`, `flood=BYTES`, `partial-tail` |
| Ignore SIGTERM (default: stop the grandchild, exit 143, like the real CLI) | `ignore-term` |
| A tool child in its own process group that outlives a SIGKILLed parent | `grandchild=<pidfile>` |
| What the child received: argv, env, cwd, open descriptors, whether stdin is EOF | `dump=<file>` |
| Session bookkeeping (S4): `--session-id` reuse and `--resume` of an unknown id exit 1 | `sessions=<dir>` |
| Signal it without racing its startup | `ready=<file>` |

Tests that send signals wait for `ready` instead of sleeping. A first version used a short timeout and
signalled a process that had not yet installed its handler (startup is slow under parallel tests), which is
the kind of flake this layer is meant to avoid.

### Worktree rules

Implemented in `Sources/WorkbenchCore/Worktree/` and `Git/`.

- Path `<repo>/.workbench/worktrees/<id>`, branch `workbench/<id>`, created with
  `git worktree add --no-track -b <branch> <path> <sha>`. The sha is `base` resolved at creation, recorded
  as `baseCommit`, so the cut point is fixed even if `base` moves.
- **The worktree is the committed `base`, not the working tree.** Uncommitted edits in the main checkout are
  not in it. Because accepting the work later merges into that checkout, creation refuses when tracked files
  are modified (`dirtyRepository`), unless `allowDirty`. Untracked files and `.workbench/` do not count.
- **`repoRoot` must be the repository top level.** A subdirectory is refused, so worktrees cannot end up in
  the wrong place.
- `.workbench/` is kept out of `git status` through `.git/info/exclude`, never by editing the project's
  tracked `.gitignore`.
- `remove` keeps the branch (and its commits) unless `deleteBranch`, and refuses a worktree with
  uncommitted work unless `force`. Stale registrations from a hand-deleted directory are pruned on create.
- Thread ids and bases are validated (`SafeNames`) before anything reaches git, with one definition shared
  by the goal parser.
- **Git is run through `GitRunner`**, a small bounded runner that follows the process-layer rules: output to
  temp files (no pipe reads), termination handler resumes exactly once, stdin `/dev/null`, timeout with
  SIGTERM then SIGKILL, output capped. It is the first, smaller exercise of the layer task 7 builds on.

## Tasks

Ordered slices, each ending with tests passing.

1. **Package skeleton.** `WorkbenchCore`, `workbench` CLI, Swift Testing, CI workflow (build + test).
2. **Event log.** Envelope, `seq`, append-only writer, replay reader, invariants from the spec. Tests: gaps,
   truncation, concurrent append is impossible by construction.
3. **Goal file.** Parse front matter + criteria, `approved_hash`, draft/approved transitions. Tests: edit after
   approval resets to draft, malformed goals produce specific errors.
4. **Config and the fixed tool set.** Load `config.toml`, resolve to argv. Tests: missing config, unknown keys.
5. **Worktree manager.** Create from `base`, deterministic branch name, remove, refuse dirty/missing repo.
   Tests against a temp git repo.
6. **Fake claude.** A small script or executable that replays a fixture, with switches: hang, crash after N
   lines, ignore SIGTERM, spawn a grandchild (in its own process group, as real tool children are),
   emit a huge line, exit non-zero, and `--list-fds` to report its own open descriptors.
7. **ProcessRunner.** Spawn via `posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT` (rule 8), line stream,
   stop, timeout, kill tree, bounded output. Driven entirely by the fake claude first. Test: the child's
   descriptor list contains stdin/stdout/stderr and nothing else, in particular not `events.jsonl`.
   Once that passes, revisit the 0.5s lock wait in `EventLogWriter`: keep it as a safety net only if the
   soak still shows contention, otherwise shorten it to what a real second writer needs.
8. **Runner + CLI.** `workbench goal new|approve`, `run`, `stop`, `log`, `status`. The single-thread guard.
   Crash recovery on startup (orphan `turn.started` gets a synthetic `turn.ended: interrupted`).
9. **Real claude, end to end.** One real goal in a scratch repo; record fixtures for later UI work.
10. **Soak.** 100 fake runs and 10 real runs in a loop, plus the failure matrix below.

## Acceptance criteria

- [ ] `workbench run` on an approved goal produces an `events.jsonl` that satisfies every invariant in the
      [event log spec](../spec/event-log.md).
- [ ] **Soak:** 100 consecutive fake-claude runs and 10 real runs: zero hangs, every run has exactly one
      `turn.ended`, no leftover processes, no leftover worktree locks.
      Also zero `alreadyOpen` from the event log's lock across the soak (rule 8). If it ever appears, the
      cause was not the one suspected, and the lock wait has been hiding it.
- [ ] **Failure matrix** (each is a test with the fake claude):
      hang → `timed_out`; non-zero exit → `failed`; SIGTERM ignored → killed within 5s + 1s;
      grandchild in its own process group survives SIGKILL of the parent → swept (S6);
      budget cap → `budget_exceeded` from the `result` line, not the exit code (S5); runner killed mid-turn → next start records `interrupted`;
      output flood → bounded log with a truncation marker; invalid JSON line → logged raw, run continues.
- [ ] Editing an approved goal makes `run` refuse until re-approved.
- [ ] Starting a second thread while one is active is refused with a message naming the active one.
- [ ] Denied tool calls appear in the log and the turn still ends cleanly.
- [ ] Second turn with `--resume` keeps context (checked with a real run).
- [ ] No use of `waitUntilExit`, `readDataToEndOfFile` or blocking reads on the main actor/cooperative pool
      (grep-enforced in CI).
- [ ] CI is green on a 3-core runner (the environment that bit us), not just locally.

## Risks

| Risk | Mitigation |
|---|---|
| The Swift process layer still hangs somewhere | D1 gate: soak decides; fall back to the Agent SDK in a sidecar |
| Bare file tools escape the worktree (S3, confirmed) | `--restricted` or `acceptEdits` + scoped `Read`; never bare names. Bash allowlist itself held in 18/18 cases |
| Tool children outlive a killed `claude` (S6, confirmed) | SIGTERM first, tree sweep before SIGKILL, startup orphan sweep |
| CLI output format changes | Parser ignores unknown fields; keep raw lines; fixtures pin the format we tested |
| Real runs cost money | `--max-budget-usd` on every run; soak with real claude kept to 10 small goals |

## Demo

In a scratch repo: write `goal.md`, `workbench goal approve`, `workbench run`, watch `workbench log -f`,
`workbench stop` mid-run, show the clean terminal state, then run the same goal 100 times with the fake.

## Open questions

- Does `--restricted` break anything in a real run (task 9)? Fallback is `acceptEdits` + `Read(./**)`.
- Symlinks out of the worktree and `.git` internals: untested in S3, check in task 9.
- Per-run network deny list: not needed while the fixed set has no network-capable commands (S3).
