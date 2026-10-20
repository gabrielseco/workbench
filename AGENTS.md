# AGENTS.md

Guidance for coding agents (Claude Code, Codex, Cursor, …) working in this repository. `CLAUDE.md` only
imports this file, so edit this one.

Workbench hands a coding task to Claude in an isolated git worktree and gives back a diff, check results
and a decision. Swift 6, macOS 14+, a `WorkbenchCore` library and a `workbench` CLI. Start at
`docs/plan/README.md` (phases and the scope rule), `docs/spec/` (goal file, event log) and the current
phase's plan.

## Commands

```bash
scripts/codex-review.sh <pr> [spec]      # Codex reviews a PR with the pr-review skill (read-only)
scripts/check.sh                         # what CI runs, minus the soak: banned APIs, SwiftLint, build, tests
scripts/check-changed.sh [--plan] [base]  the same on what the branch changed: lint those Swift files, test the suites that cover them (default base origin/main)
swiftlint lint --quiet                   # just the lint (brew install swiftlint); config in .swiftlint.yml
WORKBENCH_SOAK=1 swift test --filter SoakTests   # the soak, CI runs it as its own step
swift build                              # builds `workbench` and the `fake-claude` test double
scripts/soak-real.py                     # real `claude` runs; costs money, run by hand
bash scripts/verify-cli/<feature>.sh     # a merged feature used for real on this repo (verify-cli skill); costs money, by hand
scripts/verify-cli/from-branch.sh <feature>  # the same on a branch from a temp clone, normal then sabotaged, with the PR snippet
```

## Skills

Project skills live in `.agents/skills/<name>/SKILL.md` (`deliver`, `pr-review`, `verify-cli`, `workbench`). Agents that don't read that directory
natively can open the `SKILL.md` and follow it. Claude Code reads them through the symlinks in
`.claude/skills/`; when adding a skill, add its symlink there too:
`ln -s ../../.agents/skills/<name> .claude/skills/<name>`.

## Using Workbench on a project

The lifecycle for driving any project through Workbench (goal, run, review, accept, ship, PR review, clean) is the `workbench` skill:
`.agents/skills/workbench/SKILL.md`. It is the one definition; a project's own `workbench` skill adds only what is specific to it and points
here. Follow it only when asked to use Workbench.

## Shipping a change

Every code change ends in a PR, via the `deliver` skill or by hand. One PR per task; the phase plans
list the tasks.

1. Branch from `origin/main`. Work in a git worktree, not in a checkout someone else is using.
2. Before pushing, check the diff and nothing else, the same way every time:
   ```bash
   files=$(git diff --name-only origin/main...HEAD)          # what this branch changes
   swiftlint lint --quiet $(echo "$files" | grep '\.swift$')  # lint the changed Swift files
   swift test --filter "<suite>|<suite>"                     # the suites for those files
   ```
   The suites are the test files that cover the changed files: a changed `Sources/…/Foo.swift` maps to the
   `Tests/…/Foo*Tests.swift` that names it (`grep -l Foo Tests/WorkbenchCoreTests/*.swift` when the name does
   not match), and a changed test file is its own suite. Docs-only changes need neither. Do not run
   `scripts/check.sh` or the soak locally: CI runs them. Add tests for what you add, including the failure
   cases the phase plan lists.
3. A change to what a `workbench` command does (its output, flags, exit codes, or what it writes) ships a
   verify-cli scenario in the same PR: add `scripts/verify-cli/<feature>.sh`, or update the one that covers the
   command (the `verify-cli` skill says how). Run it by hand from the branch (`VERIFY_CLI_FROM_BRANCH=1`), once
   normally (it must PASS) and once with `VERIFY_CLI_SABOTAGE=1` (the steps its header names must FAIL), and put
   both results in the PR description. A scenario that starts a real turn costs money (the script caps it);
   one that does not, such as `help.sh`, costs nothing. A change no command shows (an internal refactor, docs,
   tests, scripts) needs none; say that in the PR. Do not put it in a later PR: a scenario that was not run on
   the change has not checked it.
4. Commit messages and the PR title follow Conventional Commits (below).
5. After opening a PR, or after pushing a fix to an open one, have Codex review it with
   `scripts/codex-review.sh <pr> [spec-file]` (below), and fix what it finds that holds up.
6. Don't merge. Leave the PR open with CI green; the user reviews and merges.
7. Docs travel with the code: if behaviour in `docs/spec/` or a phase plan changes, change the doc in the
   same PR.

### Commits and PR titles

Conventional Commits, for every commit and for the PR title (a squash merge makes the title the commit on
`main`, so it is the one that stays):

```
type(scope): subject
```

- **type:** `feat` (new behaviour), `fix` (a bug), `docs`, `test`, `refactor`, `perf`, `build`, `ci`, `chore`.
  A change that does a bit of each takes the type of its main purpose; split it when it does two things.
- **scope** (optional, one word): the area, for example `runner`, `check`, `instructions`, `config`, `lint`,
  `plan`, `spec`, `skills`, `scripts`, `ci`.
- **subject:** imperative, lower case, no full stop, 72 characters or fewer, and what changes for the
  reader, not how: `fix(check): record a pass only when the output was kept`.
- **body** (optional): why, and anything a reviewer would otherwise have to ask. Wrap at 100.
- **breaking change:** `!` after the scope and a `BREAKING CHANGE:` line, for a changed event format or
  config key.
- Keep the agent attribution trailer (`Co-Authored-By: …`) at the end of the body.
- A PR that is one task from a phase plan may say so after the type: `feat(check): run the project's check
  after each turn (P2 task 2)`.

### Review by Codex

The author of a change should not be its only reviewer. After the PR is open:

1. Run `scripts/codex-review.sh <pr-number> [spec-file]`. It checks the PR head out in a throwaway
   worktree and has Codex run the `pr-review` skill read-only. Pass the goal or plan task the change was
   written against as `spec-file` so it can judge criterion by criterion. The transcript is kept in
   `.workbench/reviews/`.
2. Treat each finding as a claim to verify, not an order. Check it against the code; some will not apply
   (a finding about a different version, a case the code already handles). Say which ones you rejected
   and why.
3. Fix the ones that hold, with a test that fails without the fix, push, and run the script again. Two
   rounds is the limit; what is still open after that goes in the PR description.
4. If Codex is unavailable (not installed, or "at capacity" three times), say so in the PR; do not
   report a review that did not happen.
5. Codex only reports. Posting comments to the PR is the user's call (the `pr-review` skill asks first).

## Conventions

These came from what went wrong when this was first built inside Triage. The full list with reasons is
in `docs/plan/P1-runner.md` ("Process layer rules") and `docs/plan/README.md`.

- **Children start through `Spawner`.** One function: `posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT`,
  stdin `/dev/null`, its own process group. Foundation's `Process`, `waitUntilExit` and
  `readDataToEndOfFile` are banned in `Sources/` (`scripts/check-banned-apis.sh` enforces it). A
  deliberate exception needs a design discussion, not an edit to the script.
- **No blocking waits.** Exit comes through `ChildExitWatcher`; never trust a single kqueue event.
- **A turn always ends, and says how.** Exactly one `turn.ended` per `turn.started`, also on stop, timeout,
  crash and restart (`recoverOrphanedTurn`). A run that cannot say how it ended is a bug.
- **One writer per event log**, `seq` without gaps, `claude` lines stored verbatim. The log is the state;
  derive, don't store a second copy.
- **Everything is bounded:** line size, log size, output, timeout, budget.
- **Validate before it reaches git or a path.** Thread ids, bases and the check command go through
  `SafeNames` and `Config` validation; never build a git argument or a path from unchecked text.
- **One project, one active thread.** No queue, no concurrent turns or checks. If a feature needs the
  word "concurrent", it belongs in `docs/later/`.
- **Reliability is an acceptance criterion.** Hangs, leaks and leftover processes are tested with the
  fake claude (`Sources/fake-claude`), which can hang, crash, ignore SIGTERM and leave children.
- **Comments say why**, in one line, and are not added to restate code.

## Using Workbench on this repo

A Workbench run starts Claude in safe mode, which keeps `claude` from reading `CLAUDE.md`, so Workbench
reads this file itself: the version at the thread's base commit goes into the first prompt under
`## Project instructions` (turn it off with `project_instructions = false`). Only this file and its `@`
imports are included, not skills. Rules that apply to one task still belong in the goal.
