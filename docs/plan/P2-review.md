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
5. **Send back flow** (done: `workbench send-back "<note>" [--budget <usd>] [id]`, which runs the turn itself;
   `run --feedback` shares the path). The note is recorded as `thread.note` before the turn starts, then the
   turn resumes the same session in the same worktree. When the latest check did not pass, the last 16 KiB of
   its output goes into the prompt in a fence longer than any backtick run inside it and labelled as data,
   with how many bytes were left out. `--budget` is for that turn only (more than 0, at most $100); the goal
   file and its approval hash are untouched. Refused with nothing recorded: no prior turn, an ended thread,
   a live runner, an empty note. No `$EDITOR`, for the reason given under accept.
6. **Accept** (done: `ThreadService.accept`, `workbench accept [id] [-m <msg>] [--yes]`). Commits everything
   `review` lists (tracked, staged and untracked; ignored files stay out) on `workbench/<id>`, then records
   `review.decision: accepted` with the commit. The default message is `chore: <goal title>`, the request and
   a `Workbench-Thread:` line; `-m` replaces it, and on a terminal a one-line replacement can be typed at the
   prompt (no `$EDITOR`: children start through `Spawner`, which has no terminal to give an editor). An empty
   message changes nothing. The commit goes through `git commit -m`, so hooks run and the message is never
   parsed by a shell. A failed check is allowed but said out loud: it asks, and with no terminal needs
   `--yes`. Refused while a runner is live, when the thread has a decision, when the worktree is not on
   `workbench/<id>`, and when there is nothing to commit and no commit beyond base. A turn or check left
   open by a dead runner is recorded as interrupted first. The decision is written last, so a rejected
   commit leaves the thread active with the changes staged and a second `accept` finishes. The worktree is
   kept for `ship`. Removing it after the work is shipped is not built yet (`git worktree remove` by
   hand); `discard` refuses an accepted thread like any ended one.
7. **Discard** (done: `ThreadService.discard`, `workbench discard [id] [--yes]`). Shows the worktree, branch,
   changed files and commits that exist nowhere else, and asks (`--yes` for scripts and agents; with no
   terminal and no `--yes` it refuses). Closes an open turn or check, removes the worktree and the
   `workbench/<id>` branch, then records `review.decision: discarded`. The decision is written last, so a
   failure partway leaves the thread active and a second `discard` finishes. Refused while a runner is
   live. Ignored files and the staged index are included because removal deletes them too. A changed list after confirmation
   refuses deletion and asks the user to retry. Failed inspection or more than ten commits requires
   `--yes`; commit inspection is bounded to eleven entries. Untracked and ignored line counting reads
   at most 1 MiB per regular file and never follows symlinks; other files have unknown counts.
   Preview comparison includes index blob identities and working-file identity, size, modification and
   change times, so same-size text and binary edits also invalidate an old confirmation. Large text
   retains the size fallback for patches rather than being classified as binary.
   `abandon` stays: it keeps the branch.
8. **Denied-tool summary** (done: `ThreadState.derive`, `ReviewReport`, `workbench log --seq <n>`). `review`
   groups denials by tool and what it was denied for (`Bash(git push origin main) ×2  turn 1, seq 5, 9`),
   counts a `tool_use_id` once, and says "denied tools may explain this" when the last turn was stopped,
   timed out or failed with denials. `workbench log --seq <n>` prints that event in full. The denied input is
   untrusted: control characters and escapes are stripped, one line, 100 characters.

## Acceptance criteria

- [ ] After any turn that changed files, the review shows the same files `git status` shows in the worktree.
- [x] The check result is from Workbench's own run, with exit code and captured output.
- [ ] Send back produces a turn whose first prompt contains the note and the check failure, and the session
      context carries over (verified by a real run).
- [x] Accept leaves a clean worktree and a branch with the commit; no push, no PR.
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
