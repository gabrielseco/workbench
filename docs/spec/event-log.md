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
| `thread.created` | once | `repo`, `base`, `worktree`, `branch`, and for a review follow-up `parent`, `root`, `round` |
| `goal.saved` | goal changed | `status`, `hash` |
| `goal.approved` | approve | `hash`, `budget_usd`, `provider`, `model`, `reasoning_effort` |
| `turn.started` | process spawned | `session_id` (Claude only), `resume`, `pid`, `argv` (redacted), `prompt_ref`, `provider`, `continuation` (Codex follow-up only) |
| `claude` | the turn's `result` line only (cost, session and `permission_denials` are derived from it). Every other stream line of a Claude turn is in the turn's [transcript file](#transcript-files). A log written before transcript files holds every line here | the raw line, unmodified |
| `agent.activity` | one normalized item of a turn run by a provider other than `claude` (P9). Claude turns keep `claude` lines and write none | `provider`, `type` (`text`, `tool`, `permission_denied`, `usage`, `session`, `diagnostic`, `unknown`, `dropped`) and that type's fields |
| `turn.ended` | always, exactly once per turn | `result`, `exit_code`, `signal`, `duration_ms`, `cost_usd?`, `transcript?` (`{lines, bytes}` of the turn's transcript file; absent when the turn wrote none) |
| `worktree.created` | the worktree was cut from `base` | `path`, `branch`, `base_commit` |
| `check.started` | before the project's check command starts | `command` |
| `check.ran` | always, exactly once per `check.started` | `command`, `result`, `exit_code`, `signal`, `duration_ms`, `output_ref`, `output_truncated` |
| `setup.ran` | the project's `setup_command` ended, once, before the first turn | `command`, `result`, `exit_code`, `signal`, `duration_ms`, `output_ref` |
| `thread.note` | user feedback sent back (P2) | `text` |
| `review.decision` | accept / discard (P2) | `decision`, `by` |
| `grant.added` | the user decided what to do about a denied command (P13) | `scope` (`once`, `thread`, `never`), `pattern`, `level` (`safe`, `caution`, `unsafe`), `by`, and when it answers a denial `denial_seq`. Written by `workbench grant` only while no run is live and the thread has not ended |
| `branch.ahead` | `workbench ship`, before pushing, found commits added after `accept` | `accepted`, `head`, `commits` |
| `pr.opened` | `workbench ship` opened the pull request (P2.5) | `url`, `number`, `branch`, `base`, `head_sha` |
| `pr.described` | `workbench ship` ran the read-only describing turn for the PR title and body | `ok`, `argv` (without the prompt), `title` when `ok`, `reason` when not (the goal-based body was used) |
| `pr.refreshed` | `workbench ship` proposed (`stage: proposed`) or applied (`stage: applied`) an update to the text of the pull request a thread continues | `stage`, `ok`, `number`, `title_changed`, `sections` (headings), `argv` and `reason` when a proposal failed |
| `worktree.removed` | `workbench ship` removed the worktree of a shipped thread (P2.5) | `reason` (`shipped`), `head_sha` |
| `branch.removed` | `workbench clean` deleted the local branch of a shipped thread whose pull request ended | `reason` (`merged`, `closed`), `head_sha` |
| `abandon.saved` | `workbench abandon` saved the worktree's uncommitted work; written before the worktree is removed | `path`, `bytes`, `sha256`, `tree`, `head`, and when present `staged_path`, `staged_bytes`, `staged_sha256` |
| `proof.added` | a PNG the verifier left in its proof directory, one per file, before its `verifier.ended` | `name`, `path`, `sha256`, `bytes`, `commit`, `tree`, `source` |
| `proof.published` | `workbench ship` put the latest proof's screenshots in the pull request through `pr-shots` | `number`, `files`, `tool` |
| `verifier.started` | the project's `[verifier]` skill is about to run as its own `claude` turn, by `workbench verifier` or after a passing check (the default; `[verifier] enabled = false` turns it off); the attempt is on record before anything is spent | `argv`, `skill`, `sha256`, `bytes`, `truncated` |
| `verifier.ended` | the verifier ended, whatever came of it; exactly one per `verifier.started` | `ok`, `reason`, `cost_usd`, `duration_ms`, `files`, `report` |
| `run.started` | the project's `[run]` app is about to be started for the verifier, after `verifier.started`; written before the command runs | `command`, `port`, `ready_url` or `ready_line` |
| `run.ended` | the app ended or never came up; exactly one per `run.started`, before the `verifier.ended` of the same verifier | `ready`, `reason` |
| `verifier.skipped` | the turn runner did not start the verifier after a passing check although the project has the skill (stopped, already verified, no change, an unusable skill), so nothing waits for a `verifier.ended`; a project with no skill file gets no event | `reason` |
| `plan.started` | `workbench plan` is about to start the read-only plan turn on the approved goal; the attempt is on record before anything is spent | `argv`, `base_commit`, `goal_hash` |
| `plan.edited` | `workbench plan edit` recorded a person's version of the plan (`--apply` or `--from <file>`); free, no process | `plan_ref`, `sha256`, `bytes`, `truncated`, `from_sha256`, `base_commit`, `goal_hash` |
| `plan.ended` | the plan turn ended, whatever came of it; one per `plan.started` (also written, without a start, when the plan could not begin) | `ok`, `reason`, `cost_usd`, `duration_ms`, `plan_ref`, `sha256`, `bytes`, `truncated`, `base_commit`, `goal_hash`, `argv`, `warning`, `synthetic` |
| `judge.started` | `workbench judge` is about to start the advisory judge on the latest turn; the attempt is on record before anything is spent | `argv` |
| `judge.ran` | `workbench judge` asked the advisory judge about the latest turn; one per run, whatever came of it | `ok`, `criteria`, `concerns`, `cost_usd`, `reason`, `argv` |
| `pr_review.started` | `workbench pr-review` is about to review the thread's pull request; the round is on record before anything is spent | `round`, `pr` (0 when the thread has no pull request yet: the stage reviews the thread's own branch against the commit it was cut from), `head_sha`, `argv` |
| `pr_review.finished` | the round ended, whatever came of it; one per `pr_review.started`. Also written alone for a skip, as `review_stage.finished` describes (without `stage`) | `round`, `pr`, `head_sha`, `ok`, `verdict`, `reason`, `findings_path`, `transcript_path` |
| `review_stage.started` | `workbench review-stage <name>` is about to review the pull request as a stage other than `pr-review` | `stage`, `round`, `pr`, `head_sha`, `argv`, `proof` |
| `review_stage.finished` | that round ended, whatever came of it, or the stage was skipped | `stage`, `round`, `pr`, `head_sha`, `ok`, `verdict`, `reason`, `findings_path`, `transcript_path` |
| `agent.attempt.started` | a provider process is about to be started (a coding turn, the judge, a review round; a capacity retry is another) | `attempt`, `role`, `stage`, `round`, `provider`, `model`, `spawned` |
| `agent.attempt.ended` | that attempt ended; exactly one per start | `attempt`, `outcome`, `reason`, `synthetic` |
| `goal.draft.started` | `workbench goal draft` asked the goal agent for a draft (P9 PR 14); thread-level (`turn` 0), no coding turn | `provider`, `model`, `attempt` |
| `goal.draft.finished` | the draft ended; one per start. `ok: true` carries the proposal's place, `ok: false` the failure | `ok`, `proposal_ref`, `provider`, `model`, `attempt`, `reason`, `cost_usd`, `synthetic` |

## Transcript files

What `claude` printed in a turn is not in `events.jsonl`: a log that holds every stream line is megabytes long, and
every command that shows a thread replays it. A Claude turn writes `threads/<id>/transcript/turn-<n>.jsonl`
instead, one line per stream line, in order:

```json
{"ts":"2026-10-24T10:00:00.120Z","data":{ ...the line as claude wrote it... }}
```

- `data` is what a `claude` event's `data` was: the line itself, `{"invalid_json": "<raw line>"}`, or the
  truncation marker for a line over the size limit. Nothing is dropped.
- A line is appended whole; a last line without its newline (a runner that died mid-write) is not a line. Recovery
  cuts it off before writing the synthetic `turn.ended`, whose `transcript` counts the lines that are left.
- The file is plain while the turn runs, so `workbench log -f` shows lines as they arrive. `workbench log` and
  `log --json` show a turn's lines just before its `turn.ended`, as `claude` events with `seq` null in JSON; the
  turn's `result` line is shown once, from the file.
- `status` reads the open turn's file for its progress (tool calls, denials, the newest line). A turn that is not
  open needs no file to be understood: its result is in the log.
- A thread from before transcript files has its lines in the log and no file; both read the same way.

## Invariants (tested)

1. Every `turn.started` is followed by exactly one `turn.ended`, even on crash recovery (the runner writes a
   synthetic `turn.ended` with `result: "interrupted"` for orphans on startup).
2. `seq` is strictly increasing with no gaps, so truncation is detectable.
3. `claude` lines are stored verbatim, in the turn's transcript file, and the turn's `result` line also in the log. We never drop information we may want later; derived state is computed.
4. The log is the only writer-owned state. Session id, status and cost are computed from it, not stored twice.
5. Every `check.started` is followed by exactly one `check.ran`, on stop, timeout and crash recovery too (a
   synthetic `check.ran` with `result: "interrupted"` for a check its runner left open).
6. Every `agent.attempt.started` has exactly one `agent.attempt.ended` (P9 PR 8), and so does every
   `judge.started`, `pr_review.started` and `review_stage.started`: a killed judge or round is closed on the next
   start by a synthetic end (see "Agent attempts"). Unlike the others this is not enforced when appending.

## Fields the runner writes

| kind | data |
|---|---|
| `thread.created` | `repo`, `base`, `worktree`, `branch`. A follow-up that `ship --review-loop` made also has `parent` (the thread it follows; itself a follow-up from the second round on), `root` (the thread that opened the pull request) and `round` (1 for the root's first follow-up, 2 for the next). Creating a follow-up writes nothing to the parent's log (reviews of the pull request are recorded in whichever thread ran them): the tree of follow-ups is derived from these three fields, and `status`/`review` show it. The follow-up's `pr_review.*` rounds continue the numbering of the whole tree, and `max_rounds` counts the `pr_review.started` events of every thread with the same `root` for the same pull request |
| `goal.saved` | `status`, `hash` (null for a new draft) |
| `goal.approved` | `hash`, `budget_usd` (null for a `timeout_only` goal), `spend_policy` (`hard_cap` or `timeout_only`; an approval without it was a hard cap), and the coding settings the approval is for: `provider`, `model` and `reasoning_effort` (null: the provider's own default), resolved from the goal's `model`, `[agents.run]` and the root `model` at the time; an approval without `reasoning_effort` bound none. `run` refuses when the config now resolves to another pair ("approved for claude, opus … now claude, haiku") and `goal approve` binds the new pair with another `goal.approved` with the same `hash`, leaving the goal file alone; the latest one counts. `run` also refuses when the goal's spend policy is not the one recorded. Judge, review and drafting settings are not part of it. An approval without the two keys (written before P9) binds nothing and is accepted until the next `goal approve` |
| `turn.started` | `session_id` (absent for Codex: a Codex turn is one fresh process and has no session to resume), `resume` (false for Codex), `pid` (null when the process could not start), `argv` (without the prompt, the system prompt shown as `<rules>`), `prompt_ref` (`prompts/turn-N.md`), and for a turn built from the goal `instructions`: `{file, sha256, bytes, truncated, skipped}` of the project's instructions as sent, or `null` when there was none or `project_instructions` is off, and `plan`: `{sha256, bytes, source}` (`generated` or `edited`) of the plan the prompt carried, or `null` when it carried none (there is none, it was made for another version of the goal, its file is missing or no longer what the log recorded, or `run --no-plan`). A follow-up turn has neither key |
| `agent.activity` | Inside an open turn only (rejected on append, a problem on replay, like `claude`); one event per item, in order. `provider` and `type` always. `text`: `text`. `tool`: `name`, `summary`. `permission_denied`: `tool`. `usage`: any of `input_tokens`, `output_tokens`, `cached_input_tokens`, `cost_usd`; **a count the provider did not report is absent, never 0**. `session`: `value`, `purpose`. `diagnostic`: `text`. `unknown`: an event the adapter did not understand; `provider` names it, `raw` is the original line, `raw_truncated` when cut. `dropped`: `count` (items since the last record), `reason` (`cap`): items past the cap. From the first one, a reader no longer knows the turn's tool and denial counts (`status` shows them as unknown). Every string is cut at 4096 characters and `truncated` is set when one was. At most 1000 items per turn; the rest are counted in `dropped` records, one every 30 s while the turn goes on (so a busy turn does not read as stuck) and one when the child has ended, so a slow or absent reader of the in-memory stream neither holds the child open nor grows the log. A `started` item is not stored (`turn.started` has the pid). Activity of judge, review and draft attempts is not logged; their transcripts are files |
| `worktree.created` | `path`, `branch`, `base_commit`: the commit the worktree was cut from, also where the project's instructions are read; `copied` (repo-relative paths) when the config's `copy` put files in, absent otherwise |
| `thread.note` | `text`: the feedback that started a follow-up turn; when the latest check did not pass also `check_turn` and `check_omitted_bytes` (its output, last 16 KiB, is in `prompts/turn-N.md`, not here); `budget_usd` when `workbench send-back --budget` set one for that turn only |
| `orphans.swept` | `pids`: leftover processes from an earlier run, found by working directory inside the worktree and a parent that is gone |
| `turn.ended` | `result`, `exit_code`, `signal`, `duration_ms`, `session_id` (absent for Codex), `permission_denials` (`null` for Codex, which reports no refusals: unknown, not 0), `summary` (Codex only: what the turn said last, at most 4000 characters, for the next turn's context), and when present `denials`, `cost_usd` (absent, never 0, when nothing reported a cost), `cause` (`natural`, `stopped`, `timedOut`), `escalated_to_kill`, `swept_processes`, `output_truncated`, `drain_timed_out`, `lost`, `stderr_tail` (at most 2000 characters), `error`, `synthetic`. `denials` is one `{tool, input, input_truncated}` per denied call (at most 100), read from the parsed `result` line, so the full `command`, `file_path`, `path`, `notebook_path`, `url`, `pattern` or `query` is kept (at most 4096 characters, `input_truncated` when cut), not shortened for display. Raw text: whoever prints it makes it safe. Absent when nothing was denied. A `result` line over the 1 MiB line limit is cut before it is parsed, so such a turn records neither the line's denials nor `denials` |
| `check.started` | `command`: `check_command` from the config, as written there. `turn` is the turn it follows |
| `check.ran` | `command`, `result` (`passed`, `failed`, `timed_out`, `stopped`, `interrupted`), `exit_code`, `signal` (null when not applicable), `duration_ms`, `output_ref` (`checks/turn-N.log`, relative to the thread directory), `output_truncated`, and when present `tests_passed` and `tests_failed` (the names of the tests the output showed finishing, at most 2000 in all and 200 characters each; absent when the output had none the parser knows, as in a log written before this field), `tests_truncated` (when the lists were cut), `escalated_to_kill`, `swept_processes`, `lost`, `error`, `synthetic`. A synthetic one has only `result`, `synthetic` and a null `exit_code` |
| `proof.added` | `commit` and `tree`: `HEAD` of the worktree and the tree of everything in it as the verifier started, committed or not (untracked files included, ignored ones not), made in a throwaway index so the worktree is untouched; null when git could not say, absent in a log written before this field. Repeated on every file so its line says what it is a proof of; the tree is what freshness compares, since a commit that keeps the content does not make a screenshot stale. `name` (path under the proof directory), `path` (relative to the thread directory), `sha256`, `bytes`. Only regular files: a symlink is left out so the record cannot point elsewhere on disk. At most 200 files per run, 64 MiB each and 512 MiB in all, from at most 5000 directory entries and 30 s of collecting. Written whatever the verifier's result, since a failed run's partial evidence is still shown | `source` is `"verifier"`; the lines of a verifier gather until its `verifier.ended`. A verifier run again for the same turn keeps the proof of the earlier runs of that turn (a file it left unchanged is not recorded twice).
| `plan.started` | `argv` (the command without the prompt), `base_commit` (the commit the plan is read at: the worktree's recorded base when there is one, else the goal's `base` resolved), `goal_hash` (the approved goal's content hash). `turn` is the latest turn, 0 before any. Followed by exactly one `plan.ended`: the next command that opens the log writes the missing one (`ok` false, `reason` `interrupted`, `synthetic` true) before it does anything else, and until then `ThreadState` shows a plan that "started and never recorded a result". While it runs, the `workbench plan` process is recorded in `runner.json` like a run, so `stop` reaches it and a run, a judge or another plan is refused; a `claude` or checkout it left behind is found in the thread's `plan/` folder and ended before the next plan starts |
| `plan.edited` | `plan_ref` (`plans/plan-N.md`, numbered with the generated plans), `sha256` and `bytes` of the stored text, `truncated` (cut at 16 KB with a marker), `from_sha256` (the plan it was made from, null when there was none), `base_commit` (the plan it replaced, else the worktree's recorded base, else the goal's `base` resolved), `goal_hash` (the approved goal's hash now). Bounded and scrubbed like a generated plan. Written by `workbench plan edit` while it holds the log, so a run, a judge or a plan makes it `busy`; refused, with nothing recorded, for a draft or changed goal, an empty text, or text equal to the latest plan. Not a numbered turn. The newest of `plan.edited` and an `ok` `plan.ended` is the thread's plan; a later failed plan does not replace it |
| `plan.ended` | `ok`, `goal_hash` and `base_commit` (repeated from the start, so this record stands alone). When `ok`: `plan_ref` (`plans/plan-N.md`, relative to the thread's folder), `sha256` and `bytes` of the stored text, `truncated` (cut at 16 KB with a marker), `cost_usd`, `duration_ms`. When not: `reason` (no `claude`, the base commit unknown or not checked out, a stop, a timeout, a budget stop, an empty answer, or `interrupted`), scrubbed of paths and credentials. `argv` is the command without the prompt. `warning` is set when the plan was recorded but its checkout could not be removed (the next plan clears it). Every command that opens the log (`plan`, `run`, `send-back`, `discard`, `accept`, `abandon`) first closes a plan left open, and ends a `claude` and checkout it left in the thread's `plan/` folder. Neither plan event is a numbered turn, so `turns` and the work session are unchanged. A failed plan does not count as the goal's plan, so the next `workbench plan` runs without `--again`. `run` reads the thread's plan (see `turn.started`) |
| `verifier.started` | `argv`, the command without the prompt (`--model`, `--safe-mode`, `--restricted`, `--disable-slash-commands`, the tools). `skill`, the repository path; `sha256`, `bytes` and `truncated` of the skill text as the model is given it, read from the thread's base commit. `turn` is the turn verified (the envelope's `turn`). Followed by exactly one `verifier.ended`: also on a hang, a crash, a stop (also one that arrives before the process started), a timeout, a budget stop, and after a restart, where the next command that opens the log writes it with `ok: false`, `reason: "interrupted"` and `synthetic: true`, and ends what the verifier left running in the worktree. While it runs, the process is recorded in `runner.json` like a run, so `stop` reaches it and a run, a judge or another verifier is refused |
| `verifier.ended` | `ok`, true only when `claude` ended on its own with status 0 and a non-empty answer. `reason` when not (`the verifier was stopped`, `claude did not finish within <n>s`, `stopped at the budget ($<n>)`, `claude exited with status <n>`, `claude was ended by signal <n>`, `claude reported an error`, …), scrubbed of paths and credentials. `cost_usd` when `claude` reported one. `duration_ms`. `files`: `{name, bytes, sha256}` for each file the run added to or changed in the turn's proof directory (`proof.added` records the PNGs among them). `report`: what it said last, cut at 4096 bytes with a marker; a note for a person, never a pass. `swept_orphans` (processes with no live parent and the worktree as their working directory, killed after the run), `swept_processes`, `escalated_to_kill` when present. `synthetic` and `reason: "interrupted"` when written by recovery |
| `run.started` | `command` as written, `port` (the free port Workbench picked, also given to the command as `WORKBENCH_PORT` and `PORT`; null when none could be found), and the ready check: `ready_url` (with `{port}` as written) or `ready_line` (the regular expression). The command runs in the thread's worktree on the allowlisted environment (`env_pass` applies) plus `WORKBENCH_PORT`, `PORT`, `WORKBENCH_THREAD` and `WORKBENCH_GOAL`; it is read from the project's config, not from the worktree. Followed by exactly one `run.ended`, also on a stop, a timeout, a crash, and after a restart, where the next command that opens the log writes it with `ready: false`, `reason: "interrupted"` and `synthetic: true` before the verifier's own end |
| `run.ended` | `ready`: whether the ready check passed. When not: `reason` (`the app ended before it was ready (exit <n>)`, `the app was not ready within <n>s`, `the [run] command '<name>' was not found`, `the verifier was stopped`, `no free port could be found for the app`, `the [run] command could not be started`) and `tail`, the last lines of its output (at most 20, scrubbed); the verifier is not started and spends nothing, and its `verifier.ended` carries the same `reason`. When ready: `ready_ms`, `exited_early` (it ended on its own before the turn did), `duration_ms`, `exit_code` or `signal`, `escalated_to_kill` and `swept_processes` when present. The app and everything under it are ended on every ending of the turn |
| `verifier.skipped` | `reason`: `the turn left no change to look at`, a skill that cannot be read at the base (the refusal's text), `a verifier has ended for this turn already`, `the base commit is unknown, so its skill cannot be read` or `the run was stopped`. Written only for a turn that succeeded and whose check passed (or that has none); after a failed turn or check nothing is written. It spends nothing, and `log -f` stops following at it |
| `judge.started` | `argv`, the command without the prompt. Followed by exactly one `judge.ran` unless the judge was killed; the next run, judge, review or `abandon` then closes it with a synthetic `judge.ran` (`reason: "interrupted"`, see "Agent attempts"), which does not count as having judged the turn. `provider` and `model` as in "Agent attempts". While it runs, the `workbench judge` process is recorded in `runner.json` like a run, so `stop` reaches it and a run or another judge is refused; a `claude` it left behind is found by its working directory and ended before the next judge starts |
| `judge.ran` | `ok`; `turn` is the turn judged (the envelope's `turn`). When `ok`: `criteria` (`{id, met, evidence}` once per criterion of the goal, `evidence` at most 3 sentences of at most 300 characters), `concerns` (at most 8), `cost_usd` (absent when the provider reports none, as on Codex: unknown, never 0). When not: `reason` (no `claude` or `codex`, a Codex judge without `allow_unpriced`, a stop, a timeout, a budget stop, or an answer that did not read as a verdict for every criterion exactly once, with real booleans and both lists). `argv` is the command without the prompt. Written by `workbench judge`, which holds the log's lock from the once-per-turn check to this record (so a second judge or a run is refused), never inside a numbered turn, so `turns` and the work session are unchanged. A failed run does not count as having judged the turn. Advisory: nothing in Workbench gates on it |
| `pr_review.started` | `round` (1 for the first review of this pull request, counted as the `pr_review.started` events with the same `pr` before it, plus one), `pr` (the number `pr.opened` recorded), `head_sha` (the branch tip on `origin` when the round began), `argv` (the Codex command line: `exec -s read-only -C <throwaway checkout> ... -o <findings file> <one-line pointer to the brief>`; the review text is in a file, never here). Written after the checks that refuse (no pull request, cap reached, busy, branch unchanged) and before anything is fetched or started. Followed by exactly one `pr_review.finished` unless `workbench` was killed; the next run, judge, review or `abandon` then closes it with a synthetic `pr_review.finished` (`reason: "interrupted"`, see "Agent attempts"), and the round still counts toward `max_rounds`, so the count is the log's and nothing but the log can reset it. While it runs, the `workbench pr-review` process is recorded in `runner.json` like a run, so `stop` reaches it and a run, a judge or another review is refused; a `codex` or checkout a killed round left behind is found in the thread's `pr-review/` folder and ended at the start of the next `workbench pr-review`, before any refusal |
| `pr_review.finished` | `round`, `pr`, `ok`, `head_sha` (the commit that was reviewed: the branch tip on `origin` when the round began), `verdict` (`clean`, `fix`, or null), and when they exist `transcript_path` (absent when the round failed before Codex ran), `findings_path` (the reviewer's final answer), `cost_usd` (what the provider reported, Claude; absent for Codex: unknown, never 0) and `reason`. Paths are relative to the thread directory (`pr-review/round-<n>.findings.md`, `.transcript.txt`) and outlive the throwaway checkout, which is removed on every ending. `ok` is true only when the answer's last non-empty line is exactly `VERDICT: CLEAN` or `VERDICT: FIX` and neither appears elsewhere; anything else is `ok: false` with `reason` (no `codex` or `claude`, a Codex review chosen with `provider` and no `allow_unpriced`, a stage that reads `proof` on Claude, the branch moved while the round was starting, "at capacity" three times, a non-zero exit, a stop, a 20 minute timeout, no answer, no verdict line). A failed round is never a pass. Written by `workbench pr-review`, which holds the log's lock from the checks to this record, never inside a numbered turn, so `turns` and the work session are unchanged. Advisory: nothing in Workbench acts on it (`ship --review-loop` is a later task) |
| `review_stage.started` | As `pr_review.started`, for a stage of `review.stages` other than `pr-review` (which keeps writing `pr_review.*`), plus `stage` (its name). `round` counts only the `review_stage.started` events with the same `stage` and `pr` across the thread tree, so each stage has its own `max_rounds` and `pr-review`'s rounds do not count. `argv` also has `-i <file>` for each screenshot attached when the stage reads `proof`. Leftovers of a killed round are in the thread's `<stage>/` folder | `proof` (stages that read it): the names of the screenshots attached to the round, from the turn's proof.
| `review_stage.finished` | As `pr_review.finished`, plus `stage`; paths are `<stage>/round-<n>.findings.md` and `.transcript.txt`. A stage that reads `proof` with no verifier run, one from before the latest turn, or no top-level PNG left is `ok: false` with `reason`. A stage whose `applies_to` matches none of the files the pull request changes is recorded with this event alone (no `started`, so it spends no round): `verdict: "skipped"`, `ok: false`, `reason` naming the globs, `round` the number the next round would have, no paths. A skip is never a pass. When the list of changed files cannot be read whole (git failed, or its output was cut) no skip is decided: the round runs and its result says so |
| `setup.ran` | `command`: `setup_command` as written, turn 0. `result` (`passed`, `failed`, `timed_out`, `stopped`), `exit_code`, `signal`, `duration_ms`, `output_ref` (`setup.log`, relative to the thread directory), `output_truncated`, and when present `escalated_to_kill`, `swept_processes`, `lost`, `error`. Written once after `worktree.created` and before the first `turn.started`; absent when `setup_command` is unset. A thread whose latest `setup.ran` is not `passed` has not started: the next `run` runs it again, and no turn is written until it passes |
| `worktree.removed` | `reason` (`shipped`), `head_sha`, and when the worktree held ignored files `ignored` (up to 20 top-level paths as `git status --ignored` lists them) and `ignored_more` (how many more) and `ignored_incomplete` (true when the listing failed or was cut at the output limit, so the names and count are a lower bound), the commit the worktree was at, which is the one `pr.opened` recorded and `origin` has. Written by `workbench ship` after it checked the worktree was on `workbench/<id>`, clean (nothing uncommitted; ignored files do not count; a status too long to read in full blocks) and at that commit, with no live runner; `git worktree remove` is never forced and the branch is kept. `workbench clean` writes the same event for a worktree `--keep-worktree` left, once the pull request is merged (or closed, with `--closed`), and also when the worktree is already gone but the event was never written; it then skips the `origin` check because origin has usually dropped the branch |
| `branch.removed` | `reason` (`merged`, `closed`) and `head_sha`. Written by `workbench clean --yes` after `git branch -D workbench/<id>`, only when GitHub's head for the recorded PR number, the `pr.opened` `head_sha` and the local branch tip are the same commit, and the delete is one compare-and-delete (`git update-ref -d <ref> <sha>`) so a commit landing in between is not lost. Absent when the branch was kept |
| `branch.ahead` | `accepted` (the commit the `accepted` decision recorded), `head` (the branch tip about to be pushed, a full sha) and `commits` (the commits in `accepted..head`, oldest first, at most 10, each an object with `sha` (full) and `subject`, the subject cut at 100 characters). Written by `workbench ship` before it pushes, when the tip of `workbench/<id>` is not the accepted commit (a commit was added after `accept`), once per `head`: a ship run again after a failure does not write it twice. Nothing changes what is pushed; `ship` prints `note: <n> commit(s) were added after accept: <short shas>`. Absent when the tip is the accepted commit |
| `abandon.saved` | `path` (`abandon.patch`, relative to the thread directory), `bytes`, `sha256`, `head` (the commit the patch applies to: `HEAD` of the worktree, the tip of the kept branch) and `tree` (the tree of everything in the worktree when the patch was taken, ignored files left out). Written by `workbench abandon` when the worktree had changes (tracked, staged or untracked, not ignored), as the patch is made in a throwaway index (the worktree's own index and history are untouched) with attributes read from the commit the thread was cut from, as for `proof.added`. It is a binary patch for `git apply` in a checkout of `workbench/<id>`. The patch is written beside its final name and moved into place, so a failure leaves neither a partial file nor an older one replaced. `staged_path` (`abandon-staged.patch`), `staged_bytes` and `staged_sha256` are present when the index held something the working tree does not (a version staged and edited again, a staged file whose working copy is gone, a staged rename deleted from disk): the working patch carries the working version, so the index's own changes against `head` are kept in a second patch. Absent for a clean worktree. The patch uses `a/` and `b/` prefixes whatever the git config says and is checked with `git apply --check` against `HEAD` in a throwaway index before anything is removed. The log's lock is held from the checks to the decision, and processes a dead runner left with the worktree as their working directory are swept first (`orphans.swept`), as `discard` and `accept` do. At most 64 MiB of new content, counted before anything is staged (a deleted or shortened file adds at most what the repository already holds): more, a failed write, a patch that does not apply, a tree that changed between the patch and the removal, or a live run refuses the abandon, removes nothing and leaves the thread active. Written before the worktree is removed, after the patch is checked and the tree compared, so a crash between the removal and the decision cannot lose where the work went; a retry after a failed removal writes another. |
| `pr.described` | `ok`; `argv` (the flags, never the prompt, which is the diff); `title` when `ok`; `reason` (credentials and machine paths removed) when not. Written by `workbench ship` before it asks, from a turn with no tools, its own session and its own budget. It is not a work turn: it carries `turn` 0, opens no `turn.started` and does not change `turns` or the work session. A thread can have several (each `ship` attempt before the PR is recorded) |
| `pr.refreshed` | `stage` (`proposed` or `applied`), `ok`, and for a proposal that worked `number`, `title_changed`, `sections` (the headings that would change or did) and `argv` (never the prompt). A proposal that failed has `ok: false`, `reason` (credentials and machine paths removed) and `argv`. Written by `workbench ship` for a thread with `push_to`, from a turn with no tools, its own session and budget, like `pr.described`; it is not a work turn. `applied` is written only after `gh pr edit` succeeded |
| `pr.opened` | `url`, `number`, `branch`, `base`, `head_sha`. Written by `workbench ship` (P2.5 task 4) after the push and the PR exist; preflight reads it to refuse a second ship and never records it. The URL carries no credentials |
| `review.decision` | `decision` (`accepted`, `discarded`, `abandoned`), `by`, and for `accepted` the `commit` (the branch's tip). `accepted` is written by `workbench accept` after the pending work is committed on `workbench/<id>`; the worktree and branch are kept, nothing is pushed. `discarded` is written by `workbench discard` after the worktree and the `workbench/<id>` branch are removed; `abandoned` keeps the branch and, for a worktree with uncommitted work, is preceded by `abandon.saved` |

A turn's `result` is derived from the `result` line and the exit, in this order: stopped or timed out by us, then a
signal is `failed`, no `result` line is `failed`, a budget error is `budget_exceeded`, a non-zero exit is
`failed`, a success line is `succeeded`, anything else `failed`. Denied tool calls do **not** make a turn
fail; they are counted in `permission_denials`.

### Two shapes, counted once

A turn is recorded in one of two shapes. Claude: `claude` lines, verbatim (invariant 3). Any other provider:
`agent.activity` events. The runner writes only the one that matches the turn's provider. A reader that meets both in
one turn (a log written by something else) reads the `claude` lines and ignores that turn's `agent.activity`, so no
tool call or denial is counted twice. `ThreadState` does this per turn. `progress.tool_calls` and `denied_calls` of a
non-Claude turn are `null` in `status --json` until the provider has reported one: a provider that streams no tool or
denial events has not said there were none, and neither is one that dropped items. Usage from `agent.activity` is summed per field in
`ThreadState.reportedUsage`; a field never reported stays nil.

Event version stays 1: a reader that does not know `agent.activity` ignores it (envelope rule), and every earlier
log replays unchanged, since only the new kind carries the new data. Tested by replaying a log with and without the
events (`AgentActivityEventsTests`).

### Which agent a thread used (P9)

`ThreadState.agentUse` reads, per responsibility (`run`, `judge`, `review`), the provider and model of the latest record that
names one: `turn.started`, `judge.started`, `pr_review.started` and `review_stage.started` carry them, and `agent.attempt.started`
(with its `agent.attempt.ended` outcome) follows the start record of its own process, so the latest record counts: a rerun, a
later round or another review stage replaces what an earlier one showed. `ThreadState.approvedFor` is the
latest `goal.approved`. A log from before any of these records reads as what the responsibility was then, never as blank or an
error: Claude with the provider's default model for `run` and `judge`, Codex for `review`, and an approval without `provider` and
`model` as Claude's default; each is marked `recorded: false` in `status --json` and `review --json` (cli-json.md) and shown as
"not recorded". Nothing is written back and no historical log is changed. `session.json` without a `provider` is Claude's. Pinned
by `LegacyFixturesTests` over `Tests/Fixtures/legacy/`: old configs (no `[agents]`) and logs (claude lines only, no attempt
records, no provider in `turn.started`) that replay to the state, `status --json`, `review --json` and `doctor` output the
pre-P9 build gave, apart from the keys and lines this adds.

## Checks

Implemented in `Sources/WorkbenchCore/Thread/Check/CheckRunner.swift`, called by `ThreadRunner` after a turn.

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
- **The verify step** was a project command run after the check; it is gone ([P10](../plan/P10-skill-verifier.md)).
  `verify.started`, `verify.ended` and `proof.added` lines without `source` in an older log are skipped.
  The proof now comes from the verifier, which is a `claude` turn with its own events.
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
- **`deniedTools`**: one entry per `permission_denials` item of a `claude` result line: `tool`, `turn`, the
  `seq` of that line, and `input`, the `command`, `file_path`, `path`, `url`, `pattern` or `query` of its
  `tool_input` made safe to print (one line, no control characters, at most 100 characters), and `fullInput`, the same made safe to print from the turn's `turn.ended.denials` (at most 4096 characters; absent for a log from before that field, or when its count differs from the result line's). `review` prints it wrapped under the entry when it is longer than `input`. Only a turn's last `result` line counts (an earlier one of the same turn is a replay), so a turn's entries match its
  `turn.ended.permission_denials`. A denial is `tool_name`, `tool_use_id` and `tool_input`. Entries are grouped by tool and the full, unshortened input.
- **Grants** are not a field of `ThreadState`; `GrantLedger(events:)` reads them from the same events: every `grant.added`. For the turn that starts next, `once` grants written after the
  latest `turn.started` and every `thread` grant are added to the project's allowed tools; `never` revokes the earlier grants of that pattern and allows nothing (a later grant allows it again; the
  latest word on a pattern stands). A pattern is ignored (not an error) unless it is `Tool(content)` for a tool in `[tools]
  available`, one line, at most 2000 characters, with content that is more than a wildcard; one that `[tools] denied`
  lists or `[tools] allowed` already has is left out, and `--disallowedTools` is passed as ever, so a grant never
  overrides a denial. The grants of a turn are visible in its `turn.started.argv`.
- **`notes`**: every `thread.note` with its `seq` and the follow-up turn it started. The runner writes the
  note with `turn: 0` before that turn, so the turn is derived (last turn + 1), not read from the event.

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
  reported as problems on replay. (A transcript line is not an event and has no `seq`; it belongs to the turn
  whose file it is in.)
- **Checks** follow the same rule: `check.started` while a check is open, and `check.ran` when the open
  check is not that turn's (or none is open), are rejected on append and reported as problems on replay.
- **Rejected appends consume no `seq`.**
- **Invalid JSON from `claude`** is stored as `{"invalid_json": "<raw line>"}` (as a transcript line's `data`, or
  as a `claude` event in an older log), so a bad line is logged raw and the run continues.
- **Oversized lines** (default 1 MiB) are stored as
  `{"truncated": true, "original_bytes": N, "prefix": "<first 4096 characters>"}`.
- **Opening a damaged log.** A half-written final line (no trailing newline) is cut off and kept in
  `events.jsonl.truncated`; appending then continues. Any other damage (seq gap, invalid line in the middle,
  turn rule broken) makes `open` fail with `corrupt` and leaves the file untouched.
- **Orphaned turns** are state, not damage. `recoverOrphanedTurn()` appends
  `turn.ended {result: "interrupted", synthetic: true}` for the open turn.

## Agent attempts (P9 PR 8)

Event version stays 1: every change is additive (new kinds, new fields), and readers ignore both. A log from before
this change replays as it did; nothing is rewritten.

- **`provider` and `model`** are on `turn.started`, `judge.started`, `judge.ran`, `pr_review.started`,
  `pr_review.finished`, `review_stage.started` and `review_stage.finished`: the provider's id (`claude`, `codex`) and the
  model asked for, `null` for the provider's own default. They are what the process was started with, from the resolved
  agent of the config (`[agents.*]`), never a guess. A log without them is a log from before provider selection.
- **`agent.attempt.started`**: `attempt` (`a<seq>`, unique in the log), `role` (`run`, `judge`, `review`), `stage` (a
  named review stage, absent for `pr-review`), `round` (a review's), `provider`, `model`, and `spawned: false` when the
  attempt is a refusal (no executable, a request the provider cannot take) and nothing was started. `turn` is the turn it
  belongs to (the coding turn, or the turn judged or reviewed). Written after the enclosing record (`turn.started`,
  `judge.started`, `pr_review.started`) and before the process exists.
- **`agent.attempt.ended`**: `attempt`, `outcome` (`succeeded`, `failed`, `stopped`, `timed_out`, `budget_exceeded`,
  `interrupted`, `refused`: what the process did, not what its answer said), `reason` (scrubbed, at most 300 characters),
  `synthetic: true` when recovery wrote it, and `role`, `stage`, `round`, `provider` and `model` copied from the start, so an
  end stands alone. Written before the enclosing end (`turn.ended`, `judge.ran`,
  `pr_review.finished`).
- A review round that retries after "at capacity" has one attempt per physical start, all inside one round: the retry adds
  no `pr_review.started`, so `max_rounds` is unchanged.
- **Recovery.** `recoverOrphanedEvaluations()` (every unmatched start, newest first, not only the last), run holding the log before a run, a judge, a review or `abandon`, closes
  each open attempt as `interrupted` (`synthetic`), then a `judge.started` with no `judge.ran` by `judge.ran {ok: false,
  reason: "interrupted", synthetic: true}`, and a `pr_review.started` or `review_stage.started` with no finish by the
  matching finish (`ok: false`, `verdict: null`, `reason: "interrupted"`, `synthetic: true`, with the start's `round`,
  `pr`, `head_sha` and `stage`). `recoverOrphanedTurn()` closes the turn's run attempt first. The round's start is still in
  the log, so it still counts toward `max_rounds`; an interrupted end is never a pass, and an interrupted judge does not
  count as having judged the turn. A second call writes nothing. A skip (`review_stage.finished` with no start) closes
  nothing. If the log cannot take an attempt's start, no process is started; if it cannot take an end, the error says so
  and the next open recovers from the last durable start.
- **`goal.draft.started` / `goal.draft.finished`** (P9 PR 14, event version stays 1: new kinds and fields only) record
  `workbench goal draft`. Each start has an `agent.attempt` with `role: "goal"`, `turn: 0` and no `round`, and exactly
  one end. The reducer ignores them for turns, approval and review: a draft opens no `turn.started` and writes no
  `goal.approved`. `proposal_ref` is the path of the agent's proposal relative to the thread's folder
  (`goal-draft/proposal.json`); `cost_usd` is absent when the provider did not report one. The drafter works in a folder
    outside the checkout (the system temporary directory), removed when the draft ends; only a valid proposal is kept. For
    `--replace` that folder is stable per thread, and a drafter a killed holder left behind is found there by its working
    directory and ended before the next draft starts.
  - *Replacing a goal (`--replace`)* has the log already, so it is write-ahead: the attempt and `goal.draft.started` are
    written before the agent is started, the thread's holder marker is set while it runs (so `stop` reaches it and a run
    or judge is refused as busy), and the end follows whatever came of it. On success the goal file is rewritten first,
    then `goal.saved {status: "draft", hash: null}`, then `goal.draft.finished {ok: true}`. On any failure
    `goal.draft.finished {ok: false, reason}` and the goal file is untouched. `recoverOrphanedEvaluations()` closes a
    draft whose process was killed (a start with no finish) as `{ok: false, reason: "interrupted", synthetic: true}`
    with the start's `attempt`, `provider` and `model`, and its `role: "goal"` attempt as `interrupted`; a second call
    writes nothing. A kill while the agent runs never touches the goal file. The one narrow window is a kill after the
    goal file was rewritten and before `goal.draft.finished` is written: the file is then already the (draft) replacement,
    `goal-draft/proposal.json` holds the same proposal, and recovery records the draft as interrupted, since the log cannot
    be made atomic with the file.
  - *A new thread* has no log until the proposal is valid, so nothing is written before: the agent runs with no thread on
    disk, and only a valid proposal creates the thread (`thread.created`, `goal.saved`) and then its draft pair
    (`agent.attempt.started`, `goal.draft.started`, `agent.attempt.ended`, `goal.draft.finished {ok: true}`), told after
    the fact. A failed, invalid, timed-out or stopped draft creates no thread, directory, file or branch and is reported
    on stderr only; a process killed mid-draft leaves no thread and nothing to recover (an agent it had started is not found by a later
    command, since a new draft has no stable folder: it ends at its own 300 s deadline only while Workbench lives). A refusal before the agent starts (no
    `[agents.goal]`, no `allow_unpriced`, no executable, an active thread) is recorded nowhere.

## Sessions and approval (P9 PR 9)

A coding session belongs to the provider that made it. `turn.started` names the session (`session_id`) and the `provider`
(absent in a log from before: Claude); the latest one is the log's session, and `session.json` (`session_id`, `confirmed`,
and now `provider`, absent meaning Claude) only says whether that id was confirmed. If the two ids differ the log's wins and
the session counts as unconfirmed, which keeps the safe fresh-session fallback. A session whose provider is not the one the
config now picks for coding is not resumed: the turn starts a new session (`resume: false`, a new id). A model change inside
Claude keeps the session.

### A Codex coding turn (P9 PR 16)

`[agents.run] provider = "codex"` runs each turn as one fresh `codex exec` process in the thread's worktree (the adapter has no
native resume: `codex exec resume` takes no `-s` or `-C`, so a resumed turn could not state its sandbox). The record differs from a
Claude turn's only where the provider differs:

- `turn.started` has `provider: "codex"`, no `session_id`, `resume: false`, and the `argv` of the adapter (no prompt). The output
  is recorded as normalized `agent.activity` events (never `claude` events), and the turn has one `agent.attempt` pair.
- A follow-up (`send-back`, or a run after a review) is self-contained, since the process remembers nothing: the prompt is the
  goal's prompt, what the previous turn said (`turn.ended.summary`), the work in the tree as a diff against the recorded base
  commit (at most 60 000 bytes, cut with a note), the names of untracked files (at most 20), the failed check's output and the
  feedback, under the standing rules. `turn.started.continuation` is `{mode: "fresh_with_context", diff_bytes, truncated,
  summary, untracked, changes_read}`; the first turn has none. The diff is read with `--no-ext-diff --no-textconv`, outside the sandbox, so no converter a
  `.gitattributes` line selects is started. If git cannot be asked, `changes_read` is false and the prompt says the changes could not
  be read (never "no changes"). Workbench never says Codex remembers more than this.
- `turn.ended` has no `session_id` and no `cost_usd` (Codex reports tokens only), so the thread's cost is `unknown`, and
  `permission_denials` is `null`. Nothing is written to `session.json`.
- Crash recovery, stop and the orphan sweep are the Claude turn's: one `turn.ended` per `turn.started`, the attempt closed once.

## Run results

`succeeded`, `failed` (non-zero exit or error result), `stopped` (user), `timed_out`, `budget_exceeded`,
`interrupted` (runner died mid-turn), `denied_only` (turn ended after tool denials made no progress; P2 uses
this to flag "needs a broader tool set").
