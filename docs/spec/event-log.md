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
| `check.started` | the project's check command is about to run | `command` |
| `check.ran` | the check ended | `command`, `result`, `exit_code`, `duration_ms`, `output_ref` |
| `thread.note` | user feedback sent back (P2) | `text` |
| `review.decision` | accept / discard (P2) | `decision`, `by` |
| `proof.added` | evidence recorded (later) | `criterion`, `type`, `path` |

## Invariants (tested)

1. Every `turn.started` is followed by exactly one `turn.ended`, even on crash recovery (the runner writes a
   synthetic `turn.ended` with `result: "interrupted"` for orphans on startup).
2. `seq` is strictly increasing with no gaps, so truncation is detectable.
3. `claude` lines are stored verbatim. We never drop information we may want later; derived state is computed.
4. The log is the only writer-owned state. Session id, status and cost are computed from it, not stored twice.

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
| `review.decision` | `decision` (`accepted`, `discarded`, `abandoned`), `by` |

`result` is derived from the `result` line and the exit, in this order: stopped or timed out by us, then a
signal is `failed`, no `result` line is `failed`, a budget error is `budget_exceeded`, a non-zero exit is
`failed`, a success line is `succeeded`, anything else `failed`. Denied tool calls do **not** make a turn
fail; they are counted in `permission_denials`.

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

## Checks

Implemented in `Sources/WorkbenchCore/Thread/CheckRunner.swift`.

After a turn ends, and when `check_command` is set, Workbench runs that command itself in the worktree: the
check is evidence from Workbench, not Claude's claim. A turn that ended `stopped` or `interrupted` is not
checked. The command comes from `config.toml` only and runs with the same minimal environment as a turn.

- **`check.started`** `{command}` is appended before the command starts, `check.ran` after it ends, both with
  the turn number of the turn that was checked. At most one check is open: a second `check.started`, or a
  `check.ran` with none open, is rejected on append and reported on replay.
- **`check.ran`** `{command, result, exit_code, signal?, duration_ms, output_ref, output_truncated, error?}`.
  `result` is `passed` (exit 0), `failed`, `timed_out` (the turn's `turn_timeout_min`, then SIGTERM, SIGKILL
  and a sweep of the process tree), `stopped` (`workbench stop`) or `interrupted` (recovery).
- **Output** goes to `checks/turn-<N>.log` under the thread directory, stdout and stderr in the order
  written, `output_ref` relative to it. At most 1 MiB is kept, then a line
  `[output truncated at 1048576 bytes]`; the command is still drained so it never blocks.
- **Recovery.** A check left open by a runner that died is closed on the next run, before anything else
  is appended, with `check.ran {result: "interrupted", synthetic: true, exit_code: null}`. Any process it
  left in the worktree is swept like a turn's.

