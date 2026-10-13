# Event log

One file per thread: `events.jsonl`, append-only, one JSON object per line. The UI and the review are
derived from it. If the app crashes, replaying the log gives back the thread's state.

## Envelope

```json
{"v":1,"seq":42,"ts":"2026-10-12T20:11:03.120Z","turn":2,"kind":"claude","data":{ ... }}
```

| Field | Meaning |
|---|---|
| `v` | Format version. Readers ignore unknown kinds and unknown fields. |
| `seq` | Monotonic per thread, starts at 1, no gaps. |
| `turn` | Turn number (1-based), 0 for thread-level events. |
| `kind` | See below. |
| `data` | Kind-specific payload. |

## Kinds

| kind | When | data (essential fields) |
|---|---|---|
| `thread.created` | once | `repo`, `base`, `worktree`, `branch` |
| `goal.saved` | goal changed | `status`, `hash` |
| `goal.approved` | approve | `hash`, `budget_usd` |
| `turn.started` | process spawned | `session_id`, `resume`, `pid`, `argv` (redacted), `prompt_ref` |
| `claude` | each stream-json line | the raw line, unmodified |
| `turn.ended` | always, exactly once per turn | `result`, `exit_code`, `signal`, `duration_ms`, `cost_usd?` |
| `worktree.created` | the worktree was cut from `base` | `path`, `branch`, `base_commit` |
| `check.started` | before the project's check command starts | `command` |
| `check.ran` | always, exactly once per `check.started` | `command`, `result`, `exit_code`, `signal`, `duration_ms`, `output_ref`, `output_truncated` |
| `thread.note` | user feedback sent back (P2) | `text` |
| `review.decision` | accept / discard (P2) | `decision`, `by` |
| `proof.added` | evidence recorded (later) | `criterion`, `type`, `path` |

## Invariants (tested)

1. Every `turn.started` is followed by exactly one `turn.ended`, even on crash recovery (the runner writes a
   synthetic `turn.ended` with `result: "interrupted"` for orphans on startup).
2. `seq` is strictly increasing with no gaps, so truncation is detectable.
3. `claude` lines are stored verbatim. We never drop information we may want later; derived state is computed.
4. The log is the only writer-owned state. Session id, status and cost are computed from it, not stored twice.
5. Every `check.started` is followed by exactly one `check.ran`, on stop, timeout and crash recovery too (a
   synthetic `check.ran` with `result: "interrupted"` for a check its runner left open).

## Fields the runner writes

| kind | data |
|---|---|
| `thread.created` | `repo`, `base`, `worktree`, `branch` |
| `goal.saved` | `status`, `hash` (null for a new draft) |
| `goal.approved` | `hash`, `budget_usd` |
| `turn.started` | `session_id`, `resume`, `pid` (null when the process could not start), `argv` (without the prompt, the system prompt shown as `<rules>`), `prompt_ref` (`prompts/turn-N.md`), and for a turn built from the goal `instructions`: `{file, sha256, bytes, truncated, skipped}` of the project's instructions as sent, or `null` when there was none or `project_instructions` is off |
| `worktree.created` | `path`, `branch`, `base_commit`: the commit the worktree was cut from, also where the project's instructions are read |
| `thread.note` | `text`: the feedback that started a follow-up turn |
| `orphans.swept` | `pids`: leftover processes from an earlier run, found by working directory inside the worktree and a parent that is gone |
| `turn.ended` | `result`, `exit_code`, `signal`, `duration_ms`, `session_id`, `permission_denials`, and when present `cost_usd`, `cause` (`natural`, `stopped`, `timedOut`), `escalated_to_kill`, `swept_processes`, `output_truncated`, `drain_timed_out`, `lost`, `stderr_tail` (at most 2000 characters), `error`, `synthetic` |
| `check.started` | `command`: `check_command` from the config, as written there. `turn` is the turn it follows |
| `check.ran` | `command`, `result` (`passed`, `failed`, `timed_out`, `stopped`, `interrupted`), `exit_code`, `signal` (null when not applicable), `duration_ms`, `output_ref` (`checks/turn-N.log`, relative to the thread directory), `output_truncated`, and when present `escalated_to_kill`, `swept_processes`, `lost`, `error`, `synthetic`. A synthetic one has only `result`, `synthetic` and a null `exit_code` |
| `review.decision` | `decision` (`accepted`, `discarded`, `abandoned`), `by`. `discarded` is written by `workbench discard` after the worktree and the `workbench/<id>` branch are removed; `abandoned` keeps the branch |

A turn's `result` is derived from the `result` line and the exit, in this order: stopped or timed out by us, then a
signal is `failed`, no `result` line is `failed`, a budget error is `budget_exceeded`, a non-zero exit is
`failed`, a success line is `succeeded`, anything else `failed`. Denied tool calls do **not** make a turn
fail; they are counted in `permission_denials`.

## Checks

Implemented in `Sources/WorkbenchCore/Thread/CheckRunner.swift`, called by `ThreadRunner` after a turn.

- **When.** Once per `workbench run`, after the last turn it ran, and not after one that ended `stopped` or
  `interrupted`, when `check_command` is set. With it unset no check events are written. A `--resume`
  attempt that failed at once with no output and is retried by creating the session did no work, so it has
  no check; the retry, which is the turn that did the work, has. (Decided: the check measures the work, and
  a 30 to 60 s check of an untouched worktree would only repeat the previous one.)
- **Which command.** `check_command` from `.workbench/config.toml`, never anything read from the worktree.
  Its words are split on spaces and passed as arguments; no shell reads the command text. A first word
  with a `/` is a path in the worktree (`scripts/check.sh`); a bare name is looked up in the absolute
  entries of `PATH` only, so a file in the worktree cannot stand in for it.
- **How.** Through `ProcessRunner`, like a turn: worktree as working directory, the same minimal
  environment, stdin `/dev/null`, `turn_timeout_min` as the timeout, SIGTERM then SIGKILL, the process
  tree swept. `ProcessRunner` reads stdout and stderr separately, so the command is started as
  `/bin/sh -c 'exec "$@" 2>&1' sh <executable> <arguments>`: a fixed script that joins the two streams
  and is replaced by the command.
- **Output.** Stdout and stderr in the order written, in `checks/turn-N.log`, read line by line (bytes
  that are not UTF-8 are replaced, and a last line without a newline gets one). At most 1 MiB is kept:
  past it the file ends with the line `[output truncated at 1048576 bytes]`, `output_truncated` is true
  and the command is still drained. One line longer than the limit is cut to its first 4096 bytes and
  followed by `… [line of N bytes, cut after its first M characters]`, so a reader knows how much is missing. Bytes are read
  as lines on purpose: the log is for people, and capturing raw bytes would need a second, uncapped copy.
- **`result`.** Stopped or timed out by us, then exit 0 is `passed`, anything else `failed`. Exit 0 with an
  output file that could not be written in full is `failed` with `error`: no evidence is not a pass. A command
  that cannot be found or started is `failed` with `error` and a null `exit_code`; the reason is also
  written to the output file.
- **Stop.** `workbench stop` during a check stops the command and records `stopped`. A stop that arrives
  after the turn ended and before the check started means no check runs.
- **Orphaned checks** are state, not damage. `recoverOrphanedCheck()` appends
  `check.ran {result: "interrupted", synthetic: true}` for the open check, in the same place an orphaned
  turn is recovered (the start of the next run, and `abandon`). The command it left running is found by
  the orphan sweep. The check is not run again for that turn.

## Review state

`ThreadState.derive(from: events, id:)` (`Sources/WorkbenchCore/Thread/ThreadState.swift`) is a pure function
of the event list; `ThreadStore.state(of:)` reads the log and calls it. Unknown kinds and unknown
`decision` values are ignored. `review` holds:

- **`status`**: `empty` (no turn started), `running` (a turn or its check is open), `awaitingReview` (a turn
  ended and nothing is open; a `stopped`, `timed_out` or `interrupted` turn is reviewable with its partial
  work), `sentBack` (a `thread.note` came after the last turn ended and the next turn has not started), or
  `decided(accepted|discarded|abandoned)`, which wins over the rest.
- **`turnResult`**: the latest `turn.ended` `result`.
- **`check`**: the latest `check.ran` (turn it followed, `result`, `exit_code`, `output_ref`).
- **`notes`**: every `thread.note` with its `seq` and the follow-up turn it started. The runner writes the
  note with `turn: 0` before that turn, so the turn is derived (last turn + 1), not read from the event.
- **`deniedTools`**: one entry per tool in a `claude` `result` line's `permission_denials`, with the turn and
  the `seq` of that line so the raw event can be opened. `turn.ended.permission_denials` stays the count.

## Writer behaviour

Implemented in `Sources/WorkbenchCore/EventLog/`.

- **One writer, enforced.** The writer takes an exclusive `flock` on `events.jsonl` for its lifetime. A
  second writer fails with `alreadyOpen`. Readers need no lock.
  `open` waits up to 0.5s for the lock before giving up. A child process being spawned elsewhere in the
  same process holds a copy of every descriptor between its creation and its exec (measured waits: 2 to
  7 ms). Closing descriptors at exec, which `Spawner` does, cannot shorten that window, and failing
  instantly turned it into a flaky `alreadyOpen` (10 of 30 test runs with concurrent spawns, 0 of 30
  without). Use `close()` to release the lock
  deterministically; do not rely on the writer being deallocated.
- **Turn numbers** are 1, 2, 3 with no gaps. `turn.started` while a turn is open, `turn.ended` for a turn
  that is not the open one, and `claude` lines outside an open turn are all rejected on append and
  reported as problems on replay.
- **Checks** follow the same rule: `check.started` while a check is open, and `check.ran` when the open
  check is not that turn's (or none is open), are rejected on append and reported as problems on replay.
- **Rejected appends consume no `seq`.**
- **Invalid JSON from `claude`** is stored as `{"invalid_json": "<raw line>"}` with `kind: "claude"`, so a bad
  line is logged raw and the run continues.
- **Oversized lines** (default 1 MiB) are stored as
  `{"truncated": true, "original_bytes": N, "prefix": "<first 4096 characters>"}`.
- **Opening a damaged log.** A half-written final line (no trailing newline) is cut off and kept in
  `events.jsonl.truncated`; appending then continues. Any other damage (seq gap, invalid line in the middle,
  turn rule broken) makes `open` fail with `corrupt` and leaves the file untouched.
- **Orphaned turns** are state, not damage. `recoverOrphanedTurn()` appends
  `turn.ended {result: "interrupted", synthetic: true}` for the open turn.

## Run results

`succeeded`, `failed` (non-zero exit or error result), `stopped` (user), `timed_out`, `budget_exceeded`,
`interrupted` (runner died mid-turn), `denied_only` (turn ended after tool denials made no progress; P2 uses
this to flag "needs a broader tool set").
