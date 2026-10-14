# `--json`

`workbench status`, `review` and `log` take `--json`. Version 1. Within a version keys are added, never
renamed or removed. Errors are described in [exit-codes.md](exit-codes.md).

Nothing else is printed on stdout, and the command never asks a question.

## status

One object. `workbench status [id] --json`.

status keys: v, thread, ended, goal, turns, open_turn, running, last_result, check, cost_usd, notes, base_gap, worktree

- `ended`: `accepted`, `discarded`, `abandoned`, or null while the thread is active.
- `goal`: null when there is no goal file; else `title`, `approval` (`approved`, `draft`, `stale`,
  `invalid`), `base`, `budget_usd`, `turn_timeout_min`, `problems` (lines, for `invalid`).
- `check`: `open_turn` and `last` (the latest result).
- `notes`: `{turn, seq, text}` for each send-back.
- `base_gap`: null, or `{base, behind, fetch_note}`.
- `worktree`: `{state: present | removed | none, path}`.

## review

One object. `workbench review [id] --json`; `review --patch <path> --json` prints
`{v, path, patch, binary, too_large_bytes}` for one file.

review keys: v, thread, status, ended, title, approval, goal_problem, turns, last_result, cost_usd, criteria, diff, check, denied_tools, notes, next, base_gap

- `status`: `empty`, `running`, `awaiting_review`, `sent_back`, `decided`.
- `criteria`: `{id, text, proof}`.
- `diff`: `{state: summary | unavailable, base, total_files, truncated, additions, deletions, files, reason}`;
  each file `{path, old_path, status, binary, untracked, staged, additions, deletions}`.
- `check`: null, or `{turn, result, exit_code, duration_ms}`.
- `denied_tools`: `{turn, tool, seq, input}`.
- `next`: what can be done, as the text mode says it.

## log

JSON lines: the stored events, one per line, exactly as in `events.jsonl` (`claude` lines verbatim).
`log -f --json` follows and ends the way `log -f` does. `log --seq <n> --json` prints that one event.
