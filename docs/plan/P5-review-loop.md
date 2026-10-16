# P5: Review loop

After `ship` opens a pull request, a second agent reviews it, Workbench feeds the findings back to the
thread as another turn, and the loop repeats until the reviewer says clean or a cap is hit. Today that is
done by hand: `ship`, then run the reviewer, then `goal new --update`, then `ship` again (friction row 46).

Proven by hand on expenses-backend (#324, #325, 2026-10-16), where the reviewer was a per-project script,
`.claude/scripts/codex-review.sh <pr>` (#325). **Workbench owns the reviewer.** A project must not need its own
script: the fiddly parts (fetch the PR head into a throwaway worktree, wait for the branch tip, run Codex
read-only, retry on "at capacity", demand a verdict line, keep the transcript) are the same everywhere and
live in `WorkbenchCore`.

## What the by-hand runs taught (design constraints)

1. **The verdict must be a line, not prose.** The reviewer ends with exactly `VERDICT: CLEAN` or
   `VERDICT: FIX`; a missing line is a failure, never a pass.
2. **A reviewer can fail, and a failure is not "clean".** Exit codes: `0` clean, `10` findings, `20`
   reviewer failed / no verdict / could not fetch, `30` round cap reached. Anything else is a failure.
3. **Reviewing the wrong commit wastes a round.** Right after a push, GitHub's `pull/<n>/head` ref *and*
   the API's `headRefOid` both lag. Three of the first four rounds in #325 reviewed the commit before the
   latest push. The fix that held was to review the branch itself as `git ls-remote origin <head branch>` gives it, not GitHub's mirror of it,
   and make the reviewer diff the checkout (`git diff origin/main...HEAD`), never `gh pr diff`.
4. **Findings must survive a restart.** Each round's findings are stored (`<key>.round-<n>.txt`) and the
   cap prints the last ones, so "report the open findings" is possible after the session is gone.
5. **Round counts must not be resettable by the thing being limited.** I reset the count three times by
   hand-editing the log while fixing the script. Workbench owns the count in its own event log.
6. **Most findings were real, but not all worth a round** (a fork-PR edge case in a one-person repo).
   Keep the cap at 3 and let the user lower it; do not try to auto-triage severity.

## What to build

### 1. `workbench pr-review [id] [--again]` (the manual step first)

Sibling of `judge`: a separate, read-only run against the thread's open PR, recorded in the event log, shown
by `review`. Config:

```toml
[pr_review]
checklist = "docs/REVIEW.md" # optional: this project's invariants, appended to the built-in prompt
max_rounds = 3
```

The reviewer is Codex, built in, all of it in Swift through `Spawner` (no shell script to copy per project):

- Fetches the PR's branch from origin (`git ls-remote origin refs/heads/<branch>`, correct the moment a push
  lands) into a throwaway detached worktree, and gives Codex the checkout plus the diff against the base, never
  `gh pr diff`. GitHub's `pull/<n>/head` and API are not read: they lag a push (constraint 3), the branch does not,
  and Workbench runs on the machine that pushed it.
- Prompt: the thread's approved goal file as the spec (criteria judged one by one), the project instructions
  Workbench already reads (`AGENTS.md`), the optional `checklist`, and the output contract: findings most
  severe first, each with a failure scenario, ending in exactly `VERDICT: CLEAN` or `VERDICT: FIX`.
  Workbench parses the verdict itself; a missing line is exit `20`.
- Codex runs read-only (`-s read-only`), no builds, nothing posted. "At capacity" retries three times with
  backoff, then exits `20` and says so.
- The transcript and the extracted findings are stored under the thread's folder (constraint 4).

- Refuses (exit 6, nothing spawned or recorded) when the thread has no PR yet (`pr.opened` missing), a run,
  judge or another review holds the thread, `max_rounds` reviews already ran for this PR (`--again` does not
  lift the cap), or the branch was already reviewed as it is (`--again` asks once more). A round that fails
  counts: the count is the number of `pr_review.started` events for this PR, so only the log can reset it.
- Events: `pr_review.started {round, pr, head_sha, argv}` before anything is fetched or run,
  `pr_review.finished {round, pr, head_sha, ok, verdict, reason, findings_path, transcript_path}` after.
  Findings are stored under the thread's folder (`pr-review/round-<n>.findings.md`).
- Exit codes: the old script's 0/10/20/30 were its own contract. In the CLI `0` is clean, `15` (new, `findings`)
  is `VERDICT: FIX`, `1` is a round with no verdict (the reviewer failed, the branch moved as the round began, no verdict
  line), `6` is a refusal including the cap. 10-14 belong to `ship`.
- `review --json` gets a `pr_review` key: `{round, pr, ok, verdict, stale, head_sha, findings_path, failure}`
  (`stale` when the branch has moved since the round). Specs: `docs/spec/{exit-codes,event-log,cli-json,goal-file}.md`.
- Codex gets its review text through a file: `Spawner` fixes stdin to `/dev/null`, so the argument is a one-line
  pointer to `pr-review/round-<n>.brief.md` and the answer comes back through `codex exec -o`.

**Status: task 1 is built** (`Sources/WorkbenchCore/Thread/PRReview/`, `Sources/workbench/CommandsPRReview.swift`).
Use it on a few real PRs before starting step 2; `scripts/codex-review.sh` stays until then.

### 2. `workbench ship --review-loop` (or `[pr_review] auto = true`)

After the PR is open (or after a push to an existing one): run `pr-review`. On `FIX`:

1. write the findings to `prompts/` as the next turn's feedback (the `send-back` path, same budget rules);
2. run the turn and its `check_command`; a failing check stops the loop and says so;
3. push to the same branch (`push_to`), wait for the branch tip as in constraint 3, review again.

Stops on clean, on `max_rounds`, on a failed check, on an exhausted budget, or on a reviewer failure; it
prints which, and never merges. The goal stays approved: findings are turns on the same goal, not edits
(its hash is untouched). Workbench appends a `## Review rounds` note outside the hashed sections, which the
PR description generator can read.

### 3. Tests

Extend `fake-claude` with a `fake-codex` (scripted verdicts, capacity errors, hangs; stands in for the `codex` binary): FIX then CLEAN; FIX to the
cap; reviewer crash (20); no verdict line; check failing after a fix turn; budget exhausted mid-loop;
branch moved during review (`stale`); `pr-review` refused with no PR / live run / cap reached; findings
text containing shell metacharacters reaches the next turn only through a file, never an argv string.

## Order

1. `pr-review` as a manual command, specs and tests (S). Use it on a few PRs.
2. `--review-loop` (S), once step 1 has run on real PRs without surprises.

## Open questions

- Does this repo's own `.agents/skills/pr-review` become the default `checklist` shape, or does the built-in
  prompt stay generic and every project write its own? Default: generic prompt, checklist optional.
- Is `scripts/codex-review.sh` deleted once `pr-review` ships? Default: yes, AGENTS.md points at the command.
- Ask for confirmation between rounds for the first N loops (`--confirm-each`)? Default: no.
- Should a `20` (reviewer failed) retry once automatically, or always stop? Default: stop.
