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
8. **Children inherit nothing they were not given.** Every child starts through one function
   (`Spawner`): `posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT`, explicit file actions for stdin
   (`/dev/null`), stdout and stderr, its own process group. Foundation's `Process` is banned in `Sources/`.
   This guarantees a child never *keeps* one of our descriptors: without it, a long-lived `claude` could
   hold the event log's lock for the whole run, long after we closed it. It is tested with a deliberately
   leaked descriptor, and the test was checked to fail when the flag is removed.
   It does **not** remove a smaller effect: a child briefly holds a copy of every descriptor between being
   created and exec, in any multithreaded process, so a lock released at that moment stays held for a
   few milliseconds. Measured with the lock wait at zero: 0 of 30 test runs fail without concurrent spawns,
   10 of 30 with them. That is why `EventLogWriter.open` waits up to 0.5s for the lock, and why that wait
   stays.
9. **Never trust one kqueue exit event.** It can arrive while the child is still exiting and not yet
   waitable, and a child can be reaped by something else. `ChildExitWatcher` polls behind the event (1 ms
   after one, 50 ms otherwise), peeks with `waitid(WNOWAIT)` before reaping, and reports a vanished child
   as `.lost` rather than waiting forever. A first version relied on the event alone and hung in about 3
   full test runs in 8.

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
  not in it, so a checkout with local edits does not block a run: the run says how many files are left out.
  (Creation used to refuse a dirty checkout because accept merged into it; accept now commits on the thread's
  branch and merges nothing, and `--allow-dirty` is accepted and ignored.)
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
5. **Worktree manager.** Create from `base`, deterministic branch name, remove, refuse a missing repo (a dirty
   checkout is fine: the worktree is the committed base).
   Tests against a temp git repo.
6. **Fake claude.** A small script or executable that replays a fixture, with switches: hang, crash after N
   lines, ignore SIGTERM, spawn a grandchild (in its own process group, as real tool children are),
   emit a huge line, exit non-zero, and `--list-fds` to report its own open descriptors.
7. **ProcessRunner.** Spawn via `posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT` (rule 8), line stream,
   stop, timeout, kill tree, bounded output. Driven entirely by the fake claude first. Test: the child's
   descriptor list contains stdin/stdout/stderr and nothing else, in particular not `events.jsonl`.
   The 0.5s lock wait in `EventLogWriter` was revisited with the fix in place and kept: the contention
   it absorbs is the unavoidable create-to-exec window, not an inheritance bug.
8. **Runner + CLI.** `workbench goal new|approve`, `run`, `stop`, `log`, `status`. The single-thread guard.
   Crash recovery on startup (orphan `turn.started` gets a synthetic `turn.ended: interrupted`).
9. **Real claude, end to end.** One real goal in a scratch repo; record fixtures for later UI work.
10. **Soak.** 100 fake runs and 10 real runs in a loop, plus the failure matrix below.

## Acceptance criteria

Status 2026-10-13. Evidence is in the tests named, `scripts/soak-real.py`, and the PRs.

- [x] `workbench run` on an approved goal produces an `events.jsonl` that satisfies every invariant in the
      [event log spec](../spec/event-log.md). Asserted after every run of the soak and in `RunnerTests`.
- [x] **Soak:** 100 consecutive fake-claude runs (`SoakTests`, five times over: 500 runs) and 10 real runs
      (`scripts/soak-real.py`): zero hangs, every run exactly one `turn.ended`, no leftover processes, no
      leftover worktrees or locks, descriptors flat (3 to 3), zero `lost`.
      Real: 10 of 10 succeeded, 12 to 23 s each, about $0.002 list price each, `main` untouched.
- [x] **Failure matrix** (each a test with the fake claude):
      hang → `timed_out`; non-zero exit → `failed`; SIGTERM ignored → killed at the 5 s grace (asserted
      between 4.9 and 6.0 s); grandchild in its own process group survives SIGKILL of the parent → swept;
      budget cap → `budget_exceeded` from the `result` line; **runner process SIGKILLed mid-turn** → next
      start records `interrupted`, sweeps the orphaned `claude` and its tool child, and the turn after
      succeeds (`CrashRecoveryTests`, with the real CLI binary); output flood → bounded log with a
      truncation marker; invalid JSON line → logged raw, run continues.
- [x] Editing an approved goal makes `run` refuse until re-approved (`RunnerTests`).
- [x] Starting a second thread while one is active is refused with a message naming the active one.
- [x] Denied tool calls appear in the log and the turn still ends cleanly (also seen with the real CLI).
- [x] Second turn with `--resume` keeps context, checked with a real run (task 9).
- [x] No use of `waitUntilExit`, `readDataToEndOfFile` or Foundation's `Process` in `Sources/`
      (grep-enforced in CI, with a check that it fails when one is added).
- [x] CI is green on a 3-core runner (the environment that bit us), not just locally. Confirmed from the
      CI log of PR #12: `cores: 3`, macOS 15.7, Swift 6.1.2 (older than the 6.2.1 used locally), the full
      suite and the 100-run soak both pass there.

## Risks

| Risk | Mitigation |
|---|---|
| The Swift process layer still hangs somewhere | D1 gate: soak decides; fall back to the Agent SDK in a sidecar |
| Bare file tools escape the worktree (S3, confirmed) | `--restricted` or `acceptEdits` + scoped `Read`; never bare names. Bash allowlist itself held in 18/18 cases |
| Tool children outlive a killed `claude` (S6, confirmed) | SIGTERM first, tree sweep before SIGKILL, startup orphan sweep |
| CLI output format changes | Parser ignores unknown fields; keep raw lines; fixtures pin the format we tested |
| Real runs cost window | `--max-budget-usd` on every run; safe mode on by default (measured about 150x less context); soak with real claude kept to 10 small goals, on `haiku` |

## Using it

```
workbench init                         # writes .workbench/config.toml; review the tool set
workbench goal new add-greeting        # a draft to fill in; refused while another thread is active
$EDITOR .workbench/threads/<id>/goal.md
workbench goal approve                 # binds the hash; any later edit returns it to draft
workbench run                          # first turn
workbench log -f                       # from another terminal
workbench stop                         # ends the running turn cleanly, recorded as `stopped`
workbench run --feedback "..."         # next turn, same session (--resume)
workbench status
workbench abandon                      # ends the thread; keeps its branch
```

Exit codes of `run`: 0 succeeded, 1 failed, 3 stopped, 4 timed out, 5 budget exceeded, 2 usage or invalid
config or goal.

Per thread, on disk: `goal.md`, `events.jsonl`, `session.json` (`{session_id, confirmed}`),
`prompts/turn-N.md`, and `runner.json` while a run holds the log.

- **Sessions.** `session.json` is written before the first spawn and marked `confirmed` once a stream line
  carries its id. A confirmed session is resumed. An unconfirmed one (a first turn killed before the CLI
  saved anything) tries `--resume`, and if that fails at once with no output, creates it with
  `--session-id`; both attempts are logged as turns. The failure text is not relied on.
- **Feedback.** Required once any turn has succeeded, refused before the first turn. A run that failed or
  was stopped can be re-run without it.
- **Crash recovery.** The next `run` closes an open turn as a synthetic `interrupted`, then sweeps
  processes whose parent is gone and whose working directory is inside the worktree. A shell or editor the
  user has open there has a live parent and is left alone.
- **`stop`** signals the runner (SIGTERM), identified by pid *and* start time. The runner stops the child
  and writes the end of the turn itself. A second Ctrl-C quits at once, and the next run recovers.

## Demo

In a scratch repo: write `goal.md`, `workbench goal approve`, `workbench run`, watch `workbench log -f`,
`workbench stop` mid-run, show the clean terminal state, then run the same goal 100 times with the fake.

## Open questions

- Does `--restricted` break anything in a real run (task 9)? Fallback is `acceptEdits` + `Read(./**)`.
- Symlinks out of the worktree and `.git` internals: untested in S3, check in task 9.
- Per-run network deny list: not needed while the fixed set has no network-capable commands (S3).
