# `--json`

`workbench status`, `review`, `log` and `grant` take `--json`. Version 1. Within a version keys are added, never
renamed or removed. Errors are described in [exit-codes.md](exit-codes.md).

Nothing else is printed on stdout, and the command never asks a question.

## status

One object. `workbench status [id] --json`.

status keys: v, thread, lineage, follow_ups, ended, goal, turns, open_turn, running, last_result, check, verify, cost_usd, plan, plan_cost_usd, notes, base_gap, worktree, progress

- `lineage`: null for a thread someone started, else `{parent, root, round}` for a follow-up that `ship --review-loop`
  made: the thread it follows, the thread that opened the pull request, and its number among the root's follow-ups.
- `follow_ups`: the follow-ups that name this thread as their parent, `{thread, round, status, ended, last_result,
  cost_usd}` each; empty when there are none. `review` has both keys too. Derived from `thread.created`, never stored.
- `ended`: `accepted`, `discarded`, `abandoned`, or null while the thread is active.
- `goal`: null when there is no goal file; else `title`, `approval` (`approved`, `draft`, `stale`,
  `invalid`), `base`, `budget_usd`, `turn_timeout_min`, `problems` (lines, for `invalid`).
- `check`: `open_turn` and `last` (the latest result).
- `verify`: `open_turn` and `last`, as for `check`; `last` is the verify step's result, not a verdict.
- `notes`: `{turn, seq, text}` for each send-back.
- `base_gap`: null, or `{base, behind, fetch_note}`.
- `worktree`: `{state: present | removed | none, path}`.
- `progress`: null when no turn is open; else `{turn, elapsed_s, timeout_s, last_event, last_event_age_s, quiet,
  tool_calls, denied_calls}`, derived from the log on each call. `quiet` is true when the newest event is
  60 s old or more. `cost_usd` does not include the open turn: `claude` reports cost only in the result line.

`workbench status --all --json`: `{v, threads}` where each thread is `{thread, status, ended, last_result, turns,
cost_usd, parent, root, round}` (the last three null unless it is a review follow-up) (status values as in review), newest first. A read-only view over `.workbench/threads/`; it starts,
runs and queues nothing.

## review

One object. `workbench review [id] --json`; `review --patch <path> --json` prints
`{v, path, patch, binary, too_large_bytes}` for one file.

review keys: v, thread, lineage, follow_ups, status, ended, title, approval, goal_problem, turns, last_result, cost_usd, plan, plan_cost_usd, base, worktree, criteria, diff, check, verify, judge, pr_review, review_stages, denied_tools, notes, next, base_gap

- `base`: the goal's base branch, null when the goal is not valid. `worktree`: as in status.
- `status`: `empty`, `running`, `awaiting_review`, `sent_back`, `decided`.
- `criteria`: `{id, text, proof, status, commands, note, file}`. `status` is `passed` or `failed` only when the
  proof is exactly the command the latest check recorded (`check.ran` `command`) and that check ran after the
  latest turn;
  otherwise `manual`. `commands` are the proof's backticked commands; `note` says why a check-shaped proof
  is still `manual`, or which check backs a verdict (null otherwise). A `screenshot: <name>` proof is
  `evidence` when the latest verify step, run after the latest turn, left `<name>.png` (`file` is its path
  relative to the thread directory; a person looks at it, it is never a pass) and `missing` otherwise,
  with `note` saying why.
- `diff`: `{state: summary | unavailable, base, total_files, truncated, additions, deletions, files, reason}`;
  each file `{path, old_path, status, binary, untracked, staged, additions, deletions}`.
- `check`: null, or `{turn, result, exit_code, duration_ms}`.
- `verify`: null when no verify step has run, else `{turn, result, exit_code, duration_ms, proof}` where `proof` is a list of `{name, path, sha256, bytes}`.
- `plan`: null when no plan was kept, else `{source, model, cost_usd, ref, sha256, bytes, truncated, stale, last_failure}`: `source` is `generated` or `edited`, `model` the plan turn's `--model` (null for an edit), `cost_usd` that turn's cost (null for an edit), `ref` the file under the thread's folder, `stale` true when it was made for another version of the goal than the one approved now (`run` leaves it out), `last_failure` why the newest plan turn made nothing (null when it did). `plan_cost_usd` is what all plan turns cost, apart from `cost_usd`, which stays the turns' cost.
- `judge`: null when the advisory judge has not run, else `{turn, ok, stale, cost_usd, failure, criteria, concerns}`; `criteria` is `{id, met, evidence}` per criterion, `stale` is true when `turn` is not the latest turn, `failure` says why there is no verdict when `ok` is false. Advisory: nothing acts on it.
- `pr_review`: null when `workbench pr-review` has not run, else the latest round `{round, pr, ok, verdict, stale, head_sha, findings_path, failure}`; `verdict` is `clean` or `fix` (null when `ok` is false and `failure` says why), `head_sha` is the commit that round reviewed, and `stale` is true when `workbench/<id>` has moved on from it (false when the branch is not known here). Advisory: nothing acts on it.
- `review_stages`: one entry per stage of `review.stages`, in its order (`["pr-review"]` with no `[review]` config, or when the config does not load), each the stage's latest round for the thread's pull request `{name, round, verdict, stale, skipped, findings_path}`; `[]` when the thread has no pull request. `round` and `verdict` are null when the stage has not run; `verdict` is `clean`, `fix`, `skipped` or null (a round without a verdict); `skipped` is true when the stage did not run because its `applies_to` matches no changed file (never clean); `stale` is as in `pr_review` (false when the stage has not run). The `pr-review` entry is read from the `pr_review.*` events, the others from `review_stage.*`. `pr_review` above stays as it is.
- `denied_tools`: `{turn, tool, seq, input, input_full}`. `input_full` is the whole input from `turn.ended.denials` made safe to print (one line, at most 4096 characters); null for a turn that did not record it.
- `next`: what can be done, as the text mode says it.

## log

JSON lines: the stored events, one per line, exactly as in `events.jsonl` (`claude` lines verbatim).
`log -f --json` follows and ends the way `log -f` does. `log --seq <n> --json` prints that one stored line.

## grant

`workbench grant [id] --json`: `{v, thread, denied, suggestions}`. `suggestions` is `{pattern, config_entry, threads}` for each
safe narrow prefix denied in two or more threads that the config neither allows nor denies and nobody turned down
(`config_entry` is the string to add to `[tools] allowed`; nothing is written). `denied` is one entry per distinct denied call, in the order they
first happened (the numbers `grant <n>` takes; they do not change when more is granted or denied):
`{number, tool, input, level, compound, status, turns, seqs, parts}`.

- `input`: the command, path or URL as the model sent it (JSON-escaped, not made safe to print).
- `level`: `safe`, `caution` or `unsafe`, by fixed rules (`DeniedCommandClassifier`); a compound is at least `caution`.
- `status`: `open`, `granted_once` (until the next turn starts), `granted_thread` or `never`.
- `turns`, `seqs`: the turns that were denied it and the `claude` lines that carry the denial.
- `parts`: `{number, command, level, pattern, reasons, status}`; one for a plain command (`number` `"3"`), one per
  simple command of a compound (`"3.1"`, ...). `pattern` is what granting it would allow, null when it cannot be
  written as a fixed pattern.

`workbench grant [id] <n> --once|--thread|--never --json`: `{v, thread, pattern, scope, level, recorded, seq, suggestion}` (`suggestion` as above for this pattern, else null);
`recorded` is false and `seq` null when the same decision was already on record. A refusal is the usual error object.
