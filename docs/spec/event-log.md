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
| `goal.approved` | approve | `hash`, `budget_usd` |
| `turn.started` | process spawned | `session_id`, `resume`, `pid`, `argv` (redacted), `prompt_ref` |
| `claude` | each stream-json line | the raw line, unmodified |
| `turn.ended` | always, exactly once per turn | `result`, `exit_code`, `signal`, `duration_ms`, `cost_usd?` |
| `worktree.created` | the worktree was cut from `base` | `path`, `branch`, `base_commit` |
| `check.started` | before the project's check command starts | `command` |
| `check.ran` | always, exactly once per `check.started` | `command`, `result`, `exit_code`, `signal`, `duration_ms`, `output_ref`, `output_truncated` |
| `setup.ran` | the project's `setup_command` ended, once, before the first turn | `command`, `result`, `exit_code`, `signal`, `duration_ms`, `output_ref` |
| `thread.note` | user feedback sent back (P2) | `text` |
| `review.decision` | accept / discard (P2) | `decision`, `by` |
| `pr.opened` | `workbench ship` opened the pull request (P2.5) | `url`, `number`, `branch`, `base`, `head_sha` |
| `pr.described` | `workbench ship` ran the read-only describing turn for the PR title and body | `ok`, `argv` (without the prompt), `title` when `ok`, `reason` when not (the goal-based body was used) |
| `pr.refreshed` | `workbench ship` proposed (`stage: proposed`) or applied (`stage: applied`) an update to the text of the pull request a thread continues | `stage`, `ok`, `number`, `title_changed`, `sections` (headings), `argv` and `reason` when a proposal failed |
| `worktree.removed` | `workbench ship` removed the worktree of a shipped thread (P2.5) | `reason` (`shipped`), `head_sha` |
| `branch.removed` | `workbench clean` deleted the local branch of a shipped thread whose pull request ended | `reason` (`merged`, `closed`), `head_sha` |
| `abandon.saved` | `workbench abandon` saved the worktree's uncommitted work before removing it; written just before the `review.decision` | `path`, `bytes`, `sha256`, `tree`, `head` |
| `verify.started` | the project's `verify_command` is about to run, after the turn's check | `command`, `proof_ref`, `port`, `commit`, `tree` |
| `proof.added` | a file the verify step left in its proof directory, one per file, before `verify.ended` | `name`, `path`, `sha256`, `bytes`, `commit`, `tree` |
| `proof.published` | `workbench ship` put the latest verify step's screenshots in the pull request through `pr-shots` | `number`, `files`, `tool` |
| `judge.started` | `workbench judge` is about to start the advisory judge on the latest turn; the attempt is on record before anything is spent | `argv` |
| `judge.ran` | `workbench judge` asked the advisory judge about the latest turn; one per run, whatever came of it | `ok`, `criteria`, `concerns`, `cost_usd`, `reason`, `argv` |
| `pr_review.started` | `workbench pr-review` is about to review the thread's pull request; the round is on record before anything is spent | `round`, `pr` (0 when the thread has no pull request yet: the stage reviews the thread's own branch against the commit it was cut from), `head_sha`, `argv` |
| `pr_review.finished` | the round ended, whatever came of it; one per `pr_review.started`. Also written alone for a skip, as `review_stage.finished` describes (without `stage`) | `round`, `pr`, `head_sha`, `ok`, `verdict`, `reason`, `findings_path`, `transcript_path` |
| `review_stage.started` | `workbench review-stage <name>` is about to review the pull request as a stage other than `pr-review` | `stage`, `round`, `pr`, `head_sha`, `argv` |
| `review_stage.finished` | that round ended, whatever came of it, or the stage was skipped | `stage`, `round`, `pr`, `head_sha`, `ok`, `verdict`, `reason`, `findings_path`, `transcript_path` |
| `verify.ended` | the verify step ended; exactly once per `verify.started` | `command`, `result`, `exit_code`, `signal`, `duration_ms`, `output_ref`, `output_truncated`, `proof_files` |

## Invariants (tested)

1. Every `turn.started` is followed by exactly one `turn.ended`, even on crash recovery (the runner writes a
   synthetic `turn.ended` with `result: "interrupted"` for orphans on startup).
2. `seq` is strictly increasing with no gaps, so truncation is detectable.
3. `claude` lines are stored verbatim. We never drop information we may want later; derived state is computed.
4. The log is the only writer-owned state. Session id, status and cost are computed from it, not stored twice.
5. Every `check.started` is followed by exactly one `check.ran`, on stop, timeout and crash recovery too (a
   synthetic `check.ran` with `result: "interrupted"` for a check its runner left open).
6. Every `verify.started` is followed by exactly one `verify.ended`, recovered the same way. Unlike the others
   this is not enforced when appending: a stray `verify.ended` is ignored, not an error.

## Fields the runner writes

| kind | data |
|---|---|
| `thread.created` | `repo`, `base`, `worktree`, `branch`. A follow-up that `ship --review-loop` made also has `parent` (the thread it follows; itself a follow-up from the second round on), `root` (the thread that opened the pull request) and `round` (1 for the root's first follow-up, 2 for the next). Creating a follow-up writes nothing to the parent's log (reviews of the pull request are recorded in whichever thread ran them): the tree of follow-ups is derived from these three fields, and `status`/`review` show it. The follow-up's `pr_review.*` rounds continue the numbering of the whole tree, and `max_rounds` counts the `pr_review.started` events of every thread with the same `root` for the same pull request |
| `goal.saved` | `status`, `hash` (null for a new draft) |
| `goal.approved` | `hash`, `budget_usd` |
| `turn.started` | `session_id`, `resume`, `pid` (null when the process could not start), `argv` (without the prompt, the system prompt shown as `<rules>`), `prompt_ref` (`prompts/turn-N.md`), and for a turn built from the goal `instructions`: `{file, sha256, bytes, truncated, skipped}` of the project's instructions as sent, or `null` when there was none or `project_instructions` is off |
| `worktree.created` | `path`, `branch`, `base_commit`: the commit the worktree was cut from, also where the project's instructions are read |
| `thread.note` | `text`: the feedback that started a follow-up turn; when the latest check did not pass also `check_turn` and `check_omitted_bytes` (its output, last 16 KiB, is in `prompts/turn-N.md`, not here); `budget_usd` when `workbench send-back --budget` set one for that turn only |
| `orphans.swept` | `pids`: leftover processes from an earlier run, found by working directory inside the worktree and a parent that is gone |
| `turn.ended` | `result`, `exit_code`, `signal`, `duration_ms`, `session_id`, `permission_denials`, and when present `cost_usd`, `cause` (`natural`, `stopped`, `timedOut`), `escalated_to_kill`, `swept_processes`, `output_truncated`, `drain_timed_out`, `lost`, `stderr_tail` (at most 2000 characters), `error`, `synthetic` |
| `check.started` | `command`: `check_command` from the config, as written there. `turn` is the turn it follows |
| `check.ran` | `command`, `result` (`passed`, `failed`, `timed_out`, `stopped`, `interrupted`), `exit_code`, `signal` (null when not applicable), `duration_ms`, `output_ref` (`checks/turn-N.log`, relative to the thread directory), `output_truncated`, and when present `escalated_to_kill`, `swept_processes`, `lost`, `error`, `synthetic`. A synthetic one has only `result`, `synthetic` and a null `exit_code` |
| `verify.started` | `command`: `verify_command` as written. `proof_ref` (`proof/turn-N`, relative to the thread directory), `port`: the free TCP port handed to the command as `WORKBENCH_PORT` (null if none could be found). `commit` and `tree`: `HEAD` of the worktree and the tree of everything in it as the step started, committed or not (untracked files included, ignored ones not), made in a throwaway index so the worktree is untouched; null when git could not say, absent in a log written before this field. Written for a turn that `succeeded`, after its `check.ran`; absent when `verify_command` is unset |
| `proof.added` | `commit` and `tree`: the same two values as `verify.started`, repeated so a file's line says what it is a proof of; the tree is what freshness compares, since a commit that keeps the content does not make a screenshot stale. `name` (path under the proof directory), `path` (relative to the thread directory), `sha256`, `bytes`. Only regular files: a symlink is left out so the record cannot point elsewhere on disk. At most 200 files per run, 64 MiB each and 512 MiB in all, from at most 5000 directory entries and 30 s of collecting; what is left out is counted in `verify.ended.proof_omitted` (a lower bound once a limit stopped the walk). Written whatever the verify result, since a failed run's partial evidence is still shown |
| `judge.started` | `argv`, the command without the prompt. Followed by exactly one `judge.ran` unless the judge was killed; then `review` shows a judge that "started and never recorded a result", and it does not count as having judged the turn. While it runs, the `workbench judge` process is recorded in `runner.json` like a run, so `stop` reaches it and a run or another judge is refused; a `claude` it left behind is found by its working directory and ended before the next judge starts |
| `judge.ran` | `ok`; `turn` is the turn judged (the envelope's `turn`). When `ok`: `criteria` (`{id, met, evidence}` once per criterion of the goal, `evidence` at most 3 sentences of at most 300 characters), `concerns` (at most 8), `cost_usd`. When not: `reason` (no `claude`, a stop, a timeout, a budget stop, or an answer that did not read as a verdict for every criterion exactly once, with real booleans and both lists). `argv` is the command without the prompt. Written by `workbench judge`, which holds the log's lock from the once-per-turn check to this record (so a second judge or a run is refused), never inside a numbered turn, so `turns` and the work session are unchanged. A failed run does not count as having judged the turn. Advisory: nothing in Workbench gates on it |
| `pr_review.started` | `round` (1 for the first review of this pull request, counted as the `pr_review.started` events with the same `pr` before it, plus one), `pr` (the number `pr.opened` recorded), `head_sha` (the branch tip on `origin` when the round began), `argv` (the Codex command line: `exec -s read-only -C <throwaway checkout> ... -o <findings file> <one-line pointer to the brief>`; the review text is in a file, never here). Written after the checks that refuse (no pull request, cap reached, busy, branch unchanged) and before anything is fetched or started. Followed by exactly one `pr_review.finished` unless `workbench` was killed; then `review` shows a round that "started and never recorded a result", and it still counts toward `max_rounds`, so the count is the log's and nothing but the log can reset it. While it runs, the `workbench pr-review` process is recorded in `runner.json` like a run, so `stop` reaches it and a run, a judge or another review is refused; a `codex` or checkout a killed round left behind is found in the thread's `pr-review/` folder and ended at the start of the next `workbench pr-review`, before any refusal |
| `pr_review.finished` | `round`, `pr`, `ok`, `head_sha` (the commit that was reviewed: the branch tip on `origin` when the round began), `verdict` (`clean`, `fix`, or null), and when they exist `transcript_path` (absent when the round failed before Codex ran), `findings_path` (Codex's final answer) and `reason`. Paths are relative to the thread directory (`pr-review/round-<n>.findings.md`, `.transcript.txt`) and outlive the throwaway checkout, which is removed on every ending. `ok` is true only when the answer's last non-empty line is exactly `VERDICT: CLEAN` or `VERDICT: FIX` and neither appears elsewhere; anything else is `ok: false` with `reason` (no `codex`, the branch moved while the round was starting, "at capacity" three times, a non-zero exit, a stop, a 20 minute timeout, no answer, no verdict line). A failed round is never a pass. Written by `workbench pr-review`, which holds the log's lock from the checks to this record, never inside a numbered turn, so `turns` and the work session are unchanged. Advisory: nothing in Workbench acts on it (`ship --review-loop` is a later task) |
| `review_stage.started` | As `pr_review.started`, for a stage of `review.stages` other than `pr-review` (which keeps writing `pr_review.*`), plus `stage` (its name). `round` counts only the `review_stage.started` events with the same `stage` and `pr` across the thread tree, so each stage has its own `max_rounds` and `pr-review`'s rounds do not count. `argv` also has `-i <file>` for each screenshot attached when the stage reads `proof`. Leftovers of a killed round are in the thread's `<stage>/` folder |
| `review_stage.finished` | As `pr_review.finished`, plus `stage`; paths are `<stage>/round-<n>.findings.md` and `.transcript.txt`. A stage that reads `proof` with no verify step, one from before the latest turn, or no top-level PNG left is `ok: false` with `reason`. A stage whose `applies_to` matches none of the files the pull request changes is recorded with this event alone (no `started`, so it spends no round): `verdict: "skipped"`, `ok: false`, `reason` naming the globs, `round` the number the next round would have, no paths. A skip is never a pass. When the list of changed files cannot be read whole (git failed, or its output was cut) no skip is decided: the round runs and its result says so |
| `verify.ended` | `command`, `result` (`passed`, `failed`, `timed_out`, `stopped`, `interrupted`), `exit_code`, `signal`, `duration_ms`, `output_ref` (`verify/turn-N.log`), `output_truncated`, `proof_files`, and when present `proof_omitted`, `escalated_to_kill`, `swept_processes`, `swept_orphans` (processes re-parented to launchd whose working directory is the worktree, killed after the step: a server a tool started in a new session), `lost`, `error`, `synthetic`. A synthetic one has only `result`, `synthetic` and a null `exit_code`. `passed` means only that the command exited 0; no criterion is met because of it |
| `setup.ran` | `command`: `setup_command` as written, turn 0. `result` (`passed`, `failed`, `timed_out`, `stopped`), `exit_code`, `signal`, `duration_ms`, `output_ref` (`setup.log`, relative to the thread directory), `output_truncated`, and when present `escalated_to_kill`, `swept_processes`, `lost`, `error`. Written once after `worktree.created` and before the first `turn.started`; absent when `setup_command` is unset. A thread whose latest `setup.ran` is not `passed` has not started: the next `run` runs it again, and no turn is written until it passes |
| `worktree.removed` | `reason` (`shipped`), `head_sha`, and when the worktree held ignored files `ignored` (up to 20 top-level paths as `git status --ignored` lists them) and `ignored_more` (how many more) and `ignored_incomplete` (true when the listing failed or was cut at the output limit, so the names and count are a lower bound), the commit the worktree was at, which is the one `pr.opened` recorded and `origin` has. Written by `workbench ship` after it checked the worktree was on `workbench/<id>`, clean (nothing uncommitted; ignored files do not count; a status too long to read in full blocks) and at that commit, with no live runner; `git worktree remove` is never forced and the branch is kept. `workbench clean` writes the same event for a worktree `--keep-worktree` left, once the pull request is merged (or closed, with `--closed`), and also when the worktree is already gone but the event was never written; it then skips the `origin` check because origin has usually dropped the branch |
| `branch.removed` | `reason` (`merged`, `closed`) and `head_sha`. Written by `workbench clean --yes` after `git branch -D workbench/<id>`, only when GitHub's head for the recorded PR number, the `pr.opened` `head_sha` and the local branch tip are the same commit, and the delete is one compare-and-delete (`git update-ref -d <ref> <sha>`) so a commit landing in between is not lost. Absent when the branch was kept |
| `abandon.saved` | `path` (`abandon.patch`, relative to the thread directory), `bytes`, `sha256`, `head` (the commit the patch applies to: `HEAD` of the worktree, the tip of the kept branch) and `tree` (the tree of everything in the worktree when the patch was taken, ignored files left out). Written by `workbench abandon` when the worktree had changes (tracked, staged or untracked, not ignored), as the patch is made in a throwaway index (the worktree's own index and history are untouched) with attributes read from the commit the thread was cut from, as for `proof.added`. It is a binary patch for `git apply` in a checkout of `workbench/<id>`. The patch is written beside its final name and moved into place, so a failure leaves neither a partial file nor an older one replaced. Absent for a clean worktree. At most 64 MiB of changed files: more, a failed write, a tree that changed between the patch and the removal, or a live run refuses the abandon, removes nothing and leaves the thread active. Written after the worktree is removed and before `review.decision` |
| `pr.described` | `ok`; `argv` (the flags, never the prompt, which is the diff); `title` when `ok`; `reason` (credentials and machine paths removed) when not. Written by `workbench ship` before it asks, from a turn with no tools, its own session and its own budget. It is not a work turn: it carries `turn` 0, opens no `turn.started` and does not change `turns` or the work session. A thread can have several (each `ship` attempt before the PR is recorded) |
| `pr.refreshed` | `stage` (`proposed` or `applied`), `ok`, and for a proposal that worked `number`, `title_changed`, `sections` (the headings that would change or did) and `argv` (never the prompt). A proposal that failed has `ok: false`, `reason` (credentials and machine paths removed) and `argv`. Written by `workbench ship` for a thread with `push_to`, from a turn with no tools, its own session and budget, like `pr.described`; it is not a work turn. `applied` is written only after `gh pr edit` succeeded |
| `pr.opened` | `url`, `number`, `branch`, `base`, `head_sha`. Written by `workbench ship` (P2.5 task 4) after the push and the PR exist; preflight reads it to refuse a second ship and never records it. The URL carries no credentials |
| `review.decision` | `decision` (`accepted`, `discarded`, `abandoned`), `by`, and for `accepted` the `commit` (the branch's tip). `accepted` is written by `workbench accept` after the pending work is committed on `workbench/<id>`; the worktree and branch are kept, nothing is pushed. `discarded` is written by `workbench discard` after the worktree and the `workbench/<id>` branch are removed; `abandoned` keeps the branch and, for a worktree with uncommitted work, is preceded by `abandon.saved` |

A turn's `result` is derived from the `result` line and the exit, in this order: stopped or timed out by us, then a
signal is `failed`, no `result` line is `failed`, a budget error is `budget_exceeded`, a non-zero exit is
`failed`, a success line is `succeeded`, anything else `failed`. Denied tool calls do **not** make a turn
fail; they are counted in `permission_denials`.

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
- **The verify step** runs through the same machinery as the check (one bounded child, merged streams, the
  process tree swept on every exit, the minimal environment) and adds a contract: the command is run in the
  worktree with `WORKBENCH_PROOF_DIR` (an empty directory, `proof/turn-N` in the thread folder),
  `WORKBENCH_PORT` (a free port), `WORKBENCH_THREAD` and `WORKBENCH_GOAL` (the path of `goal.md`) set. It is
  killed after `verify_timeout_min` (default 10). It is not run when the turn did not `succeed`, or after a stop.
  A failing verify does not change the turn's result and does not block `accept` or `ship`.
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
  `tool_input` made safe to print (one line, no control characters, at most 100 characters). Only a turn's last `result` line counts (an earlier one of the same turn is a replay), so a turn's entries match its
  `turn.ended.permission_denials`. A denial is `tool_name`, `tool_use_id` and `tool_input`. Entries are grouped by tool and the full, unshortened input.
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
