---
name: deliver
description: Ship work to PR(s) — branch from origin/main, commit, push, PR, run the pr-review skill if available, fix findings. Never merges.
---

Take current changes to open, reviewed PR(s). **Never merge** — stop once PRs are open and reviewed; merging happens only when the user asks (and then only after `gh pr checks <n> --watch` passes).

## Steps

### 1. Find every repo with changes
- Check the working repo and any sibling repos the work touched. Run `git status --short` in each; skip repos with no changes.
- A Workbench run leaves its work in `.workbench/worktrees/<id>` on branch `workbench/<id>`, already committed. Deliver from that worktree and keep the branch; do not recreate it.

### 2. Per repo: branch from `origin/main`
- Resolve the base per repo, never assume `main`: `git remote show origin | sed -n 's/.*HEAD branch: //p'`. Then `git fetch origin <base>`.
- If on the base branch: `git checkout -b <kebab-name> origin/<base>` (name from `git diff HEAD`, e.g. `feat/payslip-projection`).
- If on a feature branch, check `git log origin/<base>..HEAD`. If it holds commits unrelated to the current changes, do NOT build on it — create a fresh branch from `origin/<base>` carrying the working-tree changes instead.
- If already on a matching feature branch with an open PR, skip to step 5.

### 3. Commit
- Stage everything (or only files the user named) — never `git add` unrelated leftovers; check `git status` first.
- Conventional commit (`type(scope): subject`, ≤50 chars, body if needed), HEREDOC, plus the Co-Authored-By / attribution footer your agent's guidance asks for, if any.
- Never force push or skip hooks.

### 4. Push and open the PR
- `git push -u origin <branch>`.
- Analyze `git log <base>..HEAD` and `git diff <base>...HEAD`; `gh pr create --base <base>` with title + body following `.github/pull_request_template.md` via HEREDOC and the PR attribution line, if your agent uses one. Print the URL.

### 5. Review, if available
- If the repo has a `pr-review` skill (`.agents/skills/pr-review` or `.claude/skills/pr-review`), run it on the new PR number. If it doesn't, skip this step silently.
- Fix the findings it confirms: apply the change, add a test that covers each one, run the relevant tests, commit, push to the same branch.
- Do NOT post review comments to GitHub without asking (the skill's own rule).

### 6. CI checks
- Watch CI to completion: `gh pr checks <n> --watch`. Do this after step 5's fixes are pushed, so it reflects the final state, not a run that's about to be superseded.
- Any red check tied to this change (lint, type-check, tests, build) → pull the failure log (`gh run view <run-id> --log-failed`, from the check's URL), fix it, verify locally with the relevant command (`scripts/check.sh`), commit, push, and re-watch.
- Repeat until green or until a failure isn't yours to fix (flaky infra job, unrelated pre-existing failure on `main`, something needing the user's input) — then stop looping and report it clearly instead of spinning.
- Don't treat a merely slow/pending deploy-preview job as a failure; only act on checks that actually finished red.

### 7. Report
- For each PR: URL, review outcome (findings fixed / none), and final CI status (pass / still failing + why / skipped because unfixable).
- If there are several PRs, say in which order they should merge.

## Rules
- If `gh` is not authenticated, tell the user to run `gh auth login`.
- No changes anywhere → say so and stop.
- Use HEREDOC for all multi-line git/gh arguments.
