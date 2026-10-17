# P6: Review stages

Status: plan, nothing built. Written 2026-10-17. Builds on [P5](P5-review-loop.md) (`pr-review`, `ship --review-loop`)
and [P4](P4-verify.md) (`verify_command`, screenshot proof).

`pr-review` is one reviewer with one job: is this PR correct? Projects also have other questions, such as "does the
UI follow the design guide?" or "is the migration safe?", and today each one is a skill run by hand after the loop
(Triage's `/design-review`). P6 makes `pr-review` the first **review stage** and lets a project add more, so the
loop reviews, fixes and re-reviews through all of them in order.

## The rule

- **`pr-review` is in every project.** It is the built-in stage, needs no config and cannot be turned off, so the
  loop never ships without a correctness review.
- **Every other stage is the same thing with a different rubric.** A stage is a name, a rubric (a skill file or a
  prompt file), a reviewer, the inputs it may read and the paths it applies to. Design review is one such stage.
  A project with no extra stages behaves exactly as it does after P5.

## Config

```toml
[[review.stage]]
name = "design"
skill = ".agents/skills/design-review/SKILL.md"   # or: prompt = "docs/REVIEW-DESIGN.md"
reviewer = "claude"                               # "claude" | "codex"; default codex, as pr-review
inputs = ["diff", "goal", "proof", "docs/DESIGN.md"]
applies_to = ["Sources/Triage/**", "Resources/**"]
max_rounds = 2
```

- `inputs`: `diff` (against the base, from the checkout, never `gh pr diff`), `goal` (the approved goal file),
  `proof` (the files the verify step left, so screenshots), or a path in the repo. Anything else is refused at config
  load.
- `applies_to`: globs over the files the PR changes. A stage that matches none is **skipped and says so**
  ("design: skipped, the diff touches no matching path"). A skip is recorded as `skipped`, never as `CLEAN`.
- Order is the order in the file, after `pr-review`.

## What a stage is, and is not

A stage is a **read-only reviewer over declared inputs that ends in a verdict line**. It is not "run this skill":

- Skills such as `/design-review` build the app, swap it into `~/Applications`, drive it and post on the PR. A stage
  does none of that. Building and screenshotting belong to `verify_command`, which exists, is bounded and sweeps its
  processes. The stage reads the proof it left.
- The skill file supplies the **rubric**. If it has a `## Rubric` section, that section is the prompt; otherwise the
  whole file is, with a header telling the reviewer to ignore any step that builds, runs or posts.
- Nothing is posted by the stage. Whether Workbench posts findings on the PR is its own decision (open question).

Everything else is inherited from `pr-review`: the throwaway checkout that waits for the branch tip, the brief written
to a file, `VERDICT: CLEAN` or `VERDICT: FIX` with a missing line counting as a failure, "at capacity" retries,
transcript and findings stored in the thread folder, read-only.

## Loop behaviour

`ship --review-loop` runs stages in order. A stage starts only when the previous one is CLEAN or skipped. On `FIX`
it starts a follow-up thread exactly as P5 does (findings quoted as the request, the project's check as criteria,
ask before pushing). After a follow-up is pushed, the loop **goes back to the first stage** that has run, because a
design fix can break correctness. Rounds are counted per stage over the whole thread tree (by `root`), and one
overall ceiling, `review.max_total_rounds` (default 5), caps the loop however the stages interleave. The ceiling is
printed up front, as in P5.

## CLI

- `workbench review-stage <name> [id] [--again]`: run one stage by hand against the thread's open PR.
  `workbench pr-review` stays, as the alias for `review-stage pr-review`.
- `workbench review` and `--json` get `review_stages: [{name, round, verdict, stale, skipped, findings_path}]`.
  The existing `pr_review` key stays, unchanged.
- `workbench doctor` checks each stage: the rubric file exists, `inputs` are valid, a stage that needs `proof` has a
  `verify_command`, and a `claude` or `codex` reviewer is installed.

Events: `review_stage.started {stage, round, pr, head_sha}` and
`review_stage.finished {stage, round, pr, head_sha, ok, verdict, reason, findings_path}`. `pr_review.*` events keep
being written for the built-in stage so existing logs and `review --json` readers do not break.

## Tasks

1. **Generalise the runner.** Move `PRReview/` behind a `ReviewStage` type that `pr-review` is the first instance
   of, with no change in behaviour or events. Config parsing and validation for `[[review.stage]]`, `doctor`
   checks. Specs: `docs/spec/{event-log,cli-json,exit-codes}.md`, `docs/plan` index row.
2. **`review-stage <name>` and the inputs.** `proof` input (images are passed to the reviewer, so a reviewer that
   cannot read images is refused for a stage that asks for `proof`), `applies_to` skipping, the rubric extraction
   rule.
3. **Loop over stages.** Stage order, go back to the first stage after a follow-up, per-stage and total caps,
   skips recorded and printed.
4. **Tests.** `fake-codex` and `fake-claude` scripted per stage: two stages both CLEAN; the second FIX then CLEAN
   with the first re-run after the fix; a skipped stage; per-stage cap; the total cap; a stage that needs `proof`
   when the verify step left none (a failure, not a pass); a reviewer without image support asked for `proof`;
   rubric text with shell metacharacters reaches the reviewer only through a file; a malformed `[[review.stage]]`
   rejected at config load.
5. **Pilot on Triage.** After Triage's `.workbench/config.toml` and verify script exist (P4 task 6), a `design`
   stage over `docs/DESIGN.md` with a verify script that captures dark mode and the minimum window size. Run it on
   one real Triage PR and record the friction in `FRICTION.md`.

## Order

1 then 2 (S each, usable by hand), then 3 once 2 has run on real PRs, then 5. Task 4 travels with each.

## Open questions

- **Can the Codex CLI read images?** Not checked. If not, `proof` stages default to `claude`, and `reviewer = "codex"`
  with `proof` is refused at config load.
- **Does Workbench post findings on the PR?** Triage's `CLAUDE.md` asks for review findings as inline PR comments.
  Default: no, the stage stays read-only; a later `--post` flag could do it with the user's `gh` login.
- **Rubric shape.** A `## Rubric` convention in each skill file, or a separate prompt file per stage? Default: use
  `## Rubric` when present, else the whole skill file with the ignore-steps header.
- **Dark mode only.** Triage reviews dark mode only; the matrix of states is the verify script's job, so the stage
  has no light/dark switch of its own.
- **Stage-level budgets.** One budget per stage, or per loop? Default: the same default budget per round as P5.
