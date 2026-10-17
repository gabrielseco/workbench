# P12: Rough edges the sequential run found

Status: task 1 built; the rest is plan. Written 2026-10-17 from a second manual pass of the P11 loop (the same goal as
Triage PR #71, run again as Triage PR #73). Follows [P11](P11-verified-pipeline.md); none of this blocks P11's tasks.

## What was run

Workbench at `main` 592d2a9 (P11 0.1, 0.2, 0.3, 0.5 merged), Triage at 876797e (#72 merged). Commands, in order:
`goal new --from`, `goal approve`, `run` (the check and verify run inside it), `review`, `judge`,
`review-stage design`, `accept`, `ship`. `pr-review` and the merge were not run.

| Step | Result |
|---|---|
| turn | 104 s, $0.31, 1 tool call denied |
| check / verify | 20 s / 39 s |
| judge | $0.09, all five `met`, the same two concerns as #71 |
| design | CLEAN, before any PR |
| total | about $0.40 and four minutes of commands |

What the phase 0 fixes changed: the design stage ran before a PR (0.2), `review` said the proof "still describes the
work" (0.1), the judge's concerns were in the PR description (0.3), `goal new --from` made `...-a111` (0.5), and the
window was whole with no Keychain dialog (Triage #72). The sequence worked end to end with independent commands.

## What is still wrong

Two groups. The first is in Workbench and is this phase's work. The second is Triage's and is listed so it is not lost.

### Workbench (tasks below)

1. **`abandon` cannot end a thread whose worktree has changes.** It fails with "contains modified or untracked
   files, use --force" and `--force` deletes them. A thread whose work shipped by hand (Triage #72) stayed active and
   blocked `goal new`, so the run could not start until `discard` was used.
2. **The refusals do not say what to do.** `abandon`'s says only `--force`, though `discard` shows what would be lost.
   `discard`'s "Pass --yes" does not say there is no terminal, which is every run driven by Claude or by `!`.
3. **A judge or stage result carries no commit.** Only the proof does (0.1), so a result taken at an older head is
   not flagged. This is the smaller alternative to `workbench next` that P11 names.
4. **The `ship` preview is wrong about screenshots.** It printed "Screenshots: None" and then put one in the PR.
5. **`review` leaves a test-named criterion at "you check".** The check passed, but nothing says the named tests
   (`everythingOrder…`) ran.
6. **The design stage says "the pull request of <id>"** when there is none.
7. **The model wrote a file with `cat > f <<EOF`**, which is denied, then used `Edit`. A wasted call each run.

### Triage (not Workbench; P11 task 7)

- **A fixed PR list for `verify.sh`**, with the viewer's and others' pull requests and creation dates in view. The
  screenshot showed six of the viewer's own pull requests, in descending number, so own-then-others was never on
  screen, and the judge and the design stage said `met` and CLEAN anyway (the partial proof of P11 row 5).
- **A second capture**, and a before or minimum-size one for the design stage (P11 row 7).
- **Private data in a published screenshot.** The live list shows real PR titles and avatars, and `pr-shots` puts
  the file on a public URL. A fixture state fixes this and the ordering gap together. The owner accepted it for #73.

## Tasks

Each its own PR.

| Task | Result | Gate |
|---|---|---|
| 1. `abandon` saves, then removes **(built)** | with changes in the worktree (modified, staged or untracked, not ignored files), `abandon` writes them as a patch (`abandon.patch`) in the thread's folder, records `abandon.saved` with the path, size, sha256, tree and head, then removes the worktree; `--force` is not needed. The branch is kept, as today. A patch over the size limit (64 MiB of new content, counted before anything is staged), a write that fails, a patch that does not apply, a tree that changed between the patch and the removal, or a live run refuses and removes nothing, and says why. Git refuses to remove a dirty worktree, so the removal after a save is forced; the tree recheck, the live-run refusal and the log lock held for the whole operation stand in for git's check. What the index holds that the working tree does not (a version staged and edited again, a staged file deleted from disk) is kept in a second patch, `abandon-staged.patch`. Orphans a dead runner left in the worktree are swept first, as `discard` does, and `abandon.saved` is written before the removal | tests: modified file, staged file, untracked file, a binary file, a clean worktree (no patch), ignored files only, the thread folder not writable (nothing removed), over the limit, a live run, abandoning twice, a file written after the save, staged content kept in a second patch (edited again, deleted from disk, renamed), no second patch when the index matches, orphans swept, `abandon.saved` on record when the removal fails, the log lock held elsewhere, a huge untracked file refused before git stores it, a `diff.noprefix` config, the patch applies with `git apply` to a checkout of the branch tip (the patch is against `HEAD` of the worktree, not the base, since the model's commits stay on the branch) |
| 2. Refusals that say what to do | `abandon`'s refusal for a worktree with changes becomes task 1; `discard`'s `--yes` message says there is no terminal; a refused `goal new` names the active thread and the three ways out | tests on each message |
| 3. A result knows its commit | `judge.ended` and `stage.ended` record the head commit; `review` says current, stale or unknown for each, as it does for a proof; an old log reads "unknown", not stale | tests: result at head, a commit after it, an old log, a stage on a thread with no PR |
| 4. A true `ship` preview | the preview lists the screenshots that will be added, or says there are none and why (`--no-screenshots`, stale proof) | tests: with a proof, without, with a stale one |
| 5. Named tests in `review` | for a criterion whose proof names tests, `review` looks for their names in the check log and says "seen in the check log" or "not seen"; it never marks the criterion passed | tests: seen, not seen, no log; wording is a hint, not a verdict |
| 6. Wording without a PR | the design stage and `pr-review` say "the thread's branch" when no PR is recorded | the existing stage tests with a thread with no `pr.opened` |
| 7. No heredoc writes | the first prompt's tool note says a denied `Bash` file write is redone with `Write` or `Edit`, or the allowlist is explained in `doctor` | a prompt fixture; `doctor` prints the note |

## Out of scope

- The lifecycle document, `workbench next`, the failed-verify and judge gates: P11 tasks 2, 4 and 6.
- Any change to how the judge decides, or a `proof_complete` field (P11, after the pilot).
- Triage's fixture state and captures: P11 task 7, in the Triage repo.

## Open questions

- **Does task 1 keep ignored files?** The proposal drops them, since they are build output. A project that keeps a
  needed file ignored would lose it; `doctor` could warn about untracked-and-ignored files in a worktree.
- **Where does the patch live?** Under `.workbench/threads/<id>/`, next to the log, so `discard` and `clean` leave it.
  Whether `clean` should remove it after the PR is merged is left until it grows.
