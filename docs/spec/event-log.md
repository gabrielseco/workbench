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
| `thread.note` | user feedback sent back (P2) | `text` |
| `review.decision` | accept / discard (P2) | `decision`, `by` |
| `proof.added` | evidence recorded (later) | `criterion`, `type`, `path` |

## Invariants (tested)

1. Every `turn.started` is followed by exactly one `turn.ended`, even on crash recovery (the runner writes a
   synthetic `turn.ended` with `result: "interrupted"` for orphans on startup).
2. `seq` is strictly increasing with no gaps, so truncation is detectable.
3. `claude` lines are stored verbatim. We never drop information we may want later; derived state is computed.
4. The log is the only writer-owned state. Session id, status and cost are computed from it, not stored twice.

## Run results

`succeeded`, `failed` (non-zero exit or error result), `stopped` (user), `timed_out`, `budget_exceeded`,
`interrupted` (runner died mid-turn), `denied_only` (turn ended after tool denials made no progress; P2 uses
this to flag "needs a broader tool set").
