# `--json`

`workbench status`, `review`, `log`, `grant` and `doctor` take `--json`. Version 1. Within a version keys are added, never
renamed or removed. Errors are described in [exit-codes.md](exit-codes.md).

Nothing else is printed on stdout, and the command never asks a question.

## status

One object. `workbench status [id] --json`.

status keys: v, thread, lineage, follow_ups, ended, goal, turns, open_turn, running, last_result, check, verify, cost_usd, plan, plan_cost_usd, agents, approved_for, notes, base_gap, worktree, progress

- `lineage`: null for a thread someone started, else `{parent, root, round}` for a follow-up that `ship --review-loop`
  made: the thread it follows, the thread that opened the pull request, and its number among the root's follow-ups.
- `follow_ups`: the follow-ups that name this thread as their parent, `{thread, round, status, ended, last_result,
  cost_usd}` each; empty when there are none. `review` has both keys too. Derived from `thread.created`, never stored.
- `ended`: `accepted`, `discarded`, `abandoned`, or null while the thread is active.
- `goal`: null when there is no goal file; else `title`, `approval` (`approved`, `draft`, `stale`,
  `invalid`), `base`, `budget_usd`, `turn_timeout_min`, `problems` (lines, for `invalid`).
- `check`: `open_turn` and `last` (the latest result).
- `verify`: `open_turn` and `last`, as for `check`; `last` is the verify step's result, not a verdict. Only an older log has a verify step (`verify_command` was removed).
- `agents`: `{run, judge, review}`, each null when that responsibility never ran in the thread, else `{provider, model, recorded,
  stage, spawned, outcome}` for its latest turn or attempt, read from `turn.started`, `judge.started`, `pr_review.started` and
  `review_stage.started`, and from `agent.attempt.started`/`ended`, which follow the start record of their own process; the latest record counts.
  `model` null is the provider's own default. `stage` is the named review stage, `spawned` false for an attempt that was refused
  before anything was started, `outcome` the attempt's `outcome` once it ended (null while open, or when only a start record says it).
  **A log from before these records reads as what the responsibility was then** (`claude` for `run` and `judge`, `codex` for
  `review`, model null) with `recorded: false`: never an error, never blank. `approved_for`: null when the goal was not approved,
  else `{provider, model, recorded}` from the latest `goal.approved`; an approval without the two keys reads as `claude`, model
  null, `recorded: false`.
- `notes`: `{turn, seq, text}` for each send-back.
- `base_gap`: null, or `{base, behind, fetch_note}`.
- `worktree`: `{state: present | removed | none, path}`.
- `progress`: null when no turn is open; else `{turn, elapsed_s, timeout_s, last_event, last_event_age_s, quiet,
  tool_calls, denied_calls}`, derived from the log on each call (`tool_calls` and `denied_calls` are `null` for a turn of a provider that has not reported any: unknown, not 0). `quiet` is true when the newest event is
  60 s old or more. `cost_usd` does not include the open turn: `claude` reports cost only in the result line.

`workbench status --all --json`: `{v, threads}` where each thread is `{thread, status, ended, last_result, turns,
cost_usd, parent, root, round}` (the last three null unless it is a review follow-up) (status values as in review), newest first. A read-only view over `.workbench/threads/`; it starts,
runs and queues nothing.

## review

One object. `workbench review [id] --json`; `review --patch <path> --json` prints
`{v, path, patch, binary, too_large_bytes}` for one file.

review keys: v, thread, lineage, follow_ups, status, ended, title, approval, goal_problem, turns, last_result, cost_usd, plan, plan_cost_usd, agents, approved_for, base, worktree, criteria, commits, diff, check, verify, verifier, judge, pr_review, review_stages, denied_tools, notes, next, base_gap

- `base`: the goal's base branch, null when the goal is not valid. `worktree`: as in status.
- `status`: `empty`, `running`, `awaiting_review`, `sent_back`, `decided`.
- `criteria`: `{id, text, proof, status, commands, note, file, files}`. `status` is `passed` or `failed` only when the
  proof is exactly the command the latest check recorded (`check.ran` `command`) and that check ran after the
  latest turn;
  otherwise `manual`; a `test:` proof is `passed` or `failed` from the tests that check saw (goal-file spec). `commands` are the proof's backticked commands; `note` says why a check-shaped proof
  is still `manual`, or which check backs a verdict (null otherwise). A `screenshot: <name>[, <name>…]`
  proof is `evidence` when the latest turn's proof (the verify step's and the verifier's files together; the
  verifier's wins a name both left) has `<name>.png` for every name (`files` are their paths relative to the thread
  directory, in the order named, `file` the first; a person looks at them, it is never a pass) and `missing`
  otherwise, with `note` saying which and why (`files` then holds the ones that are there).
- `commits`: the commits on `workbench/<id>` that are not on the commit its worktree was cut from (usually the
  run's own), oldest first, at most 10, each `{sha, subject}` (the full sha; the subject cut at 100 characters);
  `[]` when there are none or the branch is gone. The terminal shows them under `Commits`, with `… and <n> more`
  past ten.
- `diff`: `{state: summary | unavailable, base, total_files, truncated, additions, deletions, files, reason}`;
  each file `{path, old_path, status, binary, untracked, staged, additions, deletions}`.
- `check`: null, or `{turn, result, exit_code, duration_ms}`.
- `verify`: null when no verify step has run, else `{turn, result, exit_code, duration_ms, proof}` where `proof` is a list of `{name, path, sha256, bytes}`.
- `verifier`: null when no verifier has run or been skipped, else `{turn, ok, skipped, open, stale, reason, cost_usd, duration_ms, report, proof}`: `ok` is true only for a run that ended on its own with an answer, `skipped` for an automatic run that did not start (`reason` says why), `open` for one that started and has no end on record, `stale` when `turn` is not the latest turn, `report` what it said last (bounded; a note, never a pass), `proof` the PNGs it recorded as `{name, path, sha256, bytes}`.
- `plan`: null when no plan was kept, else `{source, model, cost_usd, ref, sha256, bytes, truncated, stale, last_failure}`: `source` is `generated` or `edited`, `model` the plan turn's `--model` (null for an edit), `cost_usd` that turn's cost (null for an edit), `ref` the file under the thread's folder, `stale` true when it was made for another version of the goal than the one approved now (`run` leaves it out), `last_failure` why the newest plan turn made nothing (null when it did). `plan_cost_usd` is what all plan turns cost, apart from `cost_usd`, which stays the turns' cost.
- `judge`: null when the advisory judge has not run, else `{turn, ok, stale, cost_usd, failure, criteria, concerns}`; `criteria` is `{id, met, evidence}` per criterion, `stale` is true when `turn` is not the latest turn, `failure` says why there is no verdict when `ok` is false. Advisory: nothing acts on it.
- `pr_review`: null when `workbench pr-review` has not run, else the latest round `{round, pr, ok, verdict, stale, head_sha, findings_path, failure}`; `verdict` is `clean` or `fix` (null when `ok` is false and `failure` says why), `head_sha` is the commit that round reviewed, and `stale` is true when `workbench/<id>` has moved on from it (false when the branch is not known here). Advisory: nothing acts on it.
- `review_stages`: one entry per stage of `review.stages`, in its order (`["pr-review"]` with no `[review]` config, or when the config does not load), each the stage's latest round for the thread's pull request `{name, round, verdict, stale, skipped, findings_path}`; `[]` when the thread has no pull request. `round` and `verdict` are null when the stage has not run; `verdict` is `clean`, `fix`, `skipped` or null (a round without a verdict); `skipped` is true when the stage did not run because its `applies_to` matches no changed file (never clean); `stale` is as in `pr_review` (false when the stage has not run). The `pr-review` entry is read from the `pr_review.*` events, the others from `review_stage.*`. `pr_review` above stays as it is.
- `denied_tools`: `{turn, tool, seq, input, input_full}`. `input_full` is the whole input from `turn.ended.denials` made safe to print (one line, at most 4096 characters); null for a turn that did not record it.
- `next`: what can be done, as the text mode says it.

## doctor

One object. `workbench doctor [--base <branch>] --json`. Nothing else is printed on stdout (the text mode's `base:` line is not). Exit
codes are the text mode's: 0 when `passed`, 1 when a declared step failed or something was left behind (the object is still the
one printed, with `passed` false), 3 stopped (the usual error object instead), 6 refused. The verifier, `[run]` and editor lines
of the text mode are not in it.

doctor keys: v, base, passed, claude, model, thread, approved_for, agents, problems, setup, check, review_warnings, cleanup_problem

- `agents`: one entry per responsibility, goal drafting first: `{role, provider, model, note, issues}`. `provider` and `model`
  are null for goal drafting with no `[agents.goal]` (it stays manual); a null `model` is the provider's default.
  `issues` is `{kind, severity, message}` each, found before anything is spawned from the adapter's own capabilities:
  `policy_without_controls` (the provider has no verified controls for what the responsibility needs: coding confinement for
  `run`, read-only evidence for the others), `missing_executable` (not on the environment's `PATH`, or the path in
  `[providers.<id>] executable` is not executable), `budget_without_cap` (the active thread's goal has `budget_usd` and the
  `run` provider cannot enforce a dollar limit), `unconfined_reads` (a read-only judge or review on a provider that can read
  outside the checkout, as Codex can: a stated limit) and `setting_unused` (a key that is accepted but changes nothing: an
  `allow_unpriced` nothing acts on yet, an executable no responsibility uses). `severity` is `problem` (the responsibility would
  be refused or fail) or `note`. A problem is a warning: it does not make `passed` false.
- `problems`: every `problem` issue, `{role, kind, message}`.
- `thread`, `approved_for`: the project's active thread and what its goal was approved for (as in `status`), both null when there
  is none or its goal does not parse.
- `setup`, `check`: `{command, result, duration_ms}`; `result` is `passed`, `failed`, `timed_out`, `stopped`, `skipped` or `not_declared`.

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
