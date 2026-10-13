# P2: Review

**Outcome:** when a turn ends, `workbench review` shows exactly what changed and whether it passes the
project's checks, lists the criteria, and lets you **accept**, **send back** with feedback, or **discard**.
Still CLI: the logic is built and proven before any UI.

**Depends on:** P1 accepted (soak green).

## Scope

In:
- Diff of the worktree against `base` (file list + per-file diff).
- The project's **check command** run by Workbench itself, output captured and stored.
- Criteria listed with the proof the goal asked for; your own tick per criterion.
- Decisions: accept, send back (follow-up turn with your note), discard (remove worktree and branch).
- A "denied tools" summary so a stall is explainable.

Out: screenshots and verifier (`later/proof.md`), opening a PR (that is [P2.5](P2.5-ship.md)), merging, CI. Accept here means "this branch is
good": it commits pending work and leaves a branch ready for you. No push.

## Design

### Checks are run by Workbench, not trusted from Claude

After a turn ends, Workbench runs the configured `check_command` in the worktree (same bounded runner as
turns: timeout, output cap, process group). The result is an event:

```json
{"kind":"check.ran","turn":2,"data":{"command":"scripts/check.sh","result":"passed","exit_code":0,"signal":null,"duration_ms":93000,"output_ref":"checks/turn-2.log","output_truncated":false}}
```

A `check.started` is written first, so a runner that dies mid-check leaves something to recover
(`docs/spec/event-log.md`, "Checks").

Claude's claim "tests pass" is a hint; this is the evidence. The command comes from `config.toml`, not from
the worktree, so Claude cannot edit its way to a pass.

### Review output

```
Goal: Add retry with backoff to the sync client            turn 2 · succeeded · $1.84
Criteria                         Diff                          Checks
[c1] ☐ test SyncClientTests…     Sources/Sync.swift   +34 −3   ✓ scripts/check.sh  93s
[c2] ☐ unit test, injected clock Tests/SyncTests.swift +61     Denied: Bash(git push) ×1
[c3] ☐ screenshot of Settings
accept | send-back "<note>" | discard
```

### Send back

Your note becomes the next turn's prompt, with the failing check output appended. Same session (`--resume`),
same worktree, same tool set, a fresh budget you can adjust.

### Discard

Removes the worktree and branch after confirmation. The thread and its log stay as history.

## Tasks

1. **Diff provider** (done: `Git/DiffProvider.swift`). Working tree against the base commit, so committed,
   staged and untracked work all show; file list with counts, patch per file on demand; rename and binary
   handling; size cap with a "too large" fallback.
2. **Check runner** (done: `Thread/CheckRunner.swift`). Once per `workbench run`, after the turn that did
   the work and not after one that ended `stopped` or `interrupted` (a `--resume` attempt that failed at once
   is not checked, its retry is), `ThreadRunner` runs `check_command` in the worktree through `ProcessRunner`,
   with the turn's timeout and environment, and records `check.started` and `check.ran`. Output, both
   streams in order and capped at 1 MiB, is kept in `checks/turn-N.log` under the thread. A stop during the
   check is recorded as `stopped`, a check left open by a dead runner as `interrupted` on the next run.
   `workbench log`, `run` and `status` show the result.
3. **Review state** (done: `Thread/ThreadState.swift`). `ThreadState.derive(from: events, id:)` as one pure
   function, with `Review` (status, latest turn result and check, notes, denied tools) built from the
   decision and note events (`review.decision`, `thread.note`). See "Review state" in
   `docs/spec/event-log.md`.
4. **`workbench review`** (done: `Thread/ReviewReport.swift`, read-only: criteria, diff file list, check,
   denied tools by name and `seq`, what can be done next; `--patch <path>` prints one file). `accept`,
   `send-back` and `discard` are tasks 5 to 7.
5. **Send back flow.** Compose note, adjust budget, start turn with note and check output attached.
6. **Accept.** Commit pending work with a template message (editable), mark thread done, clear `current`.
7. **Discard** (done: `ThreadService.discard`, `workbench discard [id] [--yes]`). Shows the worktree, branch,
   changed files and commits that exist nowhere else, and asks (`--yes` for scripts and agents; with no
   terminal and no `--yes` it refuses). Closes an open turn or check, removes the worktree and the
   `workbench/<id>` branch, then records `review.decision: discarded`. The decision is written last, so a
   failure partway leaves the thread active and a second `discard` finishes. Refused while a runner is
   live. Ignored files and the staged index are included because removal deletes them too. A changed list after confirmation
   refuses deletion and asks the user to retry. Failed inspection or more than ten commits requires
   `--yes`; commit inspection is bounded to eleven entries. Untracked and ignored line counting reads
   at most 1 MiB per regular file and never follows symlinks; other files have unknown counts.
   `abandon` stays: it keeps the branch.
8. **Denied-tool summary.** Aggregate from the log, link to the raw event.

## Acceptance criteria

- [ ] After any turn that changed files, the review shows the same files `git status` shows in the worktree.
- [x] The check result is from Workbench's own run, with exit code and captured output.
- [ ] Send back produces a turn whose first prompt contains the note and the check failure, and the session
      context carries over (verified by a real run).
- [ ] Accept leaves a clean worktree and a branch with the commit; no push, no PR.
- [x] Discard removes worktree and branch and leaves the log readable.
- [ ] A turn that was `stopped` or `timed_out` still reviews, with its partial diff.
- [ ] Big diffs and binary files fall back without hanging.
- [x] Killing the process during a check leaves an `interrupted` check, never a thread stuck running.
- [ ] After accept or discard the next thread can start; before, it is refused.

## Risks

| Risk | Mitigation |
|---|---|
| Checks are slow | Show the diff immediately, stream the check result in |
| Claude edited check-related files to pass | Check command comes from config; flag when check-related files changed |
| Big diffs overwhelm output | Cap, paginate by file, collapse generated files by pattern |

## Demo

Give it a goal whose first attempt fails the check; see the failure in review, send back one sentence, watch
the second turn fix it, accept.

## Open questions

- Commit message: template, or a short read-only Claude turn? Leaning: template.
