# AGENTS.md

Guidance for coding agents (Claude Code, Codex, Cursor, …) working in this repository. `CLAUDE.md` only
imports this file, so edit this one.

Workbench hands a coding task to Claude in an isolated git worktree and gives back a diff, check results
and a decision. Swift 6, macOS 14+, a `WorkbenchCore` library and a `workbench` CLI. Start at
`docs/plan/README.md` (phases and the scope rule), `docs/spec/` (goal file, event log) and the current
phase's plan.

## Commands

```bash
scripts/check.sh                         # what CI runs, minus the soak: banned APIs, build, tests
WORKBENCH_SOAK=1 swift test --filter SoakTests   # the soak, CI runs it as its own step
swift build                              # builds `workbench` and the `fake-claude` test double
scripts/soak-real.py                     # real `claude` runs; costs money, run by hand
```

## Skills

Project skills live in `.agents/skills/<name>/SKILL.md` (`deliver`, `pr-review`). Agents that don't read that directory
natively can open the `SKILL.md` and follow it. Claude Code reads them through the symlinks in
`.claude/skills/`; when adding a skill, add its symlink there too:
`ln -s ../../.agents/skills/<name> .claude/skills/<name>`.

## Shipping a change

Every code change ends in a PR, via the `deliver` skill or by hand. One PR per task; the phase plans
list the tasks.

1. Branch from `origin/main`. Work in a git worktree, not in a checkout someone else is using.
2. `scripts/check.sh` must pass before pushing. Add tests for what you add, including the failure cases
   the phase plan lists.
3. After opening a PR, or after pushing a fix to an open one, run `pr-review` on it when that skill exists,
   and fix its findings.
4. Don't merge. Leave the PR open with CI green; the user reviews and merges.
5. Docs travel with the code: if behaviour in `docs/spec/` or a phase plan changes, change the doc in the
   same PR.

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

A Workbench run starts Claude in safe mode: it does not read `CLAUDE.md` or `AGENTS.md`. The goal is the
only input, so put any rule a run must follow in the goal's request or out-of-scope section.
