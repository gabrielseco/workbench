# `--json`

`workbench status`, `review` and `log` take `--json`. Version 1. Within a version keys are added, never
renamed or removed. Errors are described in [exit-codes.md](exit-codes.md).

Nothing else is printed on stdout, and the command never asks a question.

## status

One object. `workbench status [id] --json`.

status keys: v, thread, ended, goal, turns, open_turn, running, last_result, check, cost_usd, notes, base_gap, worktree, progress

- `ended`: `accepted`, `discarded`, `abandoned`, or null while the thread is active.
- `goal`: null when there is no goal file; else `title`, `approval` (`approved`, `draft`, `stale`,
  `invalid`), `base`, `budget_usd`, `turn_timeout_min`, `problems` (lines, for `invalid`).
- `check`: `open_turn` and `last` (the latest result).
- `notes`: `{turn, seq, text}` for each send-back.
- `base_gap`: null, or `{base, behind, fetch_note}`.
- `worktree`: `{state: present | removed | none, path}`.
- `progress`: null when no turn is open; else `{turn, elapsed_s, timeout_s, last_event, last_event_age_s, quiet,
  tool_calls, denied_calls}`, derived from the log on each call. `quiet` is true when the newest event is
  60 s old or more. `cost_usd` does not include the open turn: `claude` reports cost only in the result line.

`workbench status --all --json`: `{v, threads}` where each thread is `{thread, status, ended, last_result, turns,
cost_usd}` (status values as in review), newest first. A read-only view over `.workbench/threads/`; it starts,
runs and queues nothing.

## review

One object. `workbench review [id] --json`; `review --patch <path> --json` prints
`{v, path, patch, binary, too_large_bytes}` for one file.

review keys: v, thread, status, ended, title, approval, goal_problem, turns, last_result, cost_usd, base, worktree, criteria, diff, check, denied_tools, notes, next, base_gap

- `base`: the goal's base branch, null when the goal is not valid. `worktree`: as in status.
- `status`: `empty`, `running`, `awaiting_review`, `sent_back`, `decided`.
- `criteria`: `{id, text, proof, status, commands, note}`. `status` is `passed` or `failed` only when the
  proof is exactly the configured `check_command` and the latest check ran after the latest turn;
  otherwise `manual`. `commands` are the proof's backticked commands; `note` says why a check-shaped proof
  is still `manual`, or which check backs a verdict (null otherwise).
- `diff`: `{state: summary | unavailable, base, total_files, truncated, additions, deletions, files, reason}`;
  each file `{path, old_path, status, binary, untracked, staged, additions, deletions}`.
- `check`: null, or `{turn, result, exit_code, duration_ms}`.
- `denied_tools`: `{turn, tool, seq, input}`.
- `next`: what can be done, as the text mode says it.

## log

JSON lines: the stored events, one per line, exactly as in `events.jsonl` (`claude` lines verbatim).
`log -f --json` follows and ends the way `log -f` does. `log --seq <n> --json` prints that one stored line.
