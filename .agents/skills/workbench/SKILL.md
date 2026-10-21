---
name: workbench
description: Drive a task through the Workbench CLI, from goal to merged pull request, the same way in every repo (goal, isolated worktree run, review, accept, ship, PR review, clean). Use ONLY when the user asks to use Workbench ("use workbench", "run it with workbench", "workbench goal"). Ordinary changes follow the repo's own AGENTS.md.
allowed-tools: Bash(workbench:*), Bash(wb:*), Bash(gh pr checks:*), Bash(gh pr view:*), Read, Edit, Write
---

# Workbench lifecycle

Workbench hands a task to Claude in an isolated git worktree and gives back a diff, check results, proof and a decision. This is the
one lifecycle for every project that uses it; a project's own `.agents/skills/workbench/SKILL.md` adds only what is specific to it
(its check, its allowlist quirks, its contract steps) and points here. Only follow this when the user asked for Workbench.

State lives in `<project>/.workbench/` (config, threads, worktrees), ignored by git. One project has one active thread; a thread ends
with `accept`, `discard` or `abandon`.

## Before the first command

- **Which binary.** `wb` is the debug build in `~/rogal/workbench/.build/debug/workbench`. After a Workbench PR merges, rebuild it:
  `git -C ~/rogal/workbench switch main && git -C ~/rogal/workbench pull --ff-only && swift build` there. An old build rejects config keys it
  does not know (`[run]`) with "unknown table".
- **Run it from the project directory**, in a shell that has the project's toolchain. A run uses the `PATH` it was started from, so
  an unpinned shell runs the wrong Elixir or Node (this produced a 24k-line contract diff and reformatted files). Until Workbench resolves
  the toolchain itself, start it as `mise exec -- wb ...` in a repo that pins versions.
- **Never touch the user's checkout.** It may be on a feature branch with uncommitted work. Runs and clones go through worktrees;
  Workbench leaves local edits out of a thread.

## Steps (each ends in a gate; do not skip one because the CLI allows it)

1. **Doctor.** `wb doctor` runs setup and the check in a throwaway worktree and shows the allowlist and the verifier. Fix a failing
   doctor before writing a goal.
2. **Goal.** `wb goal new <name> [--from <file>]`. **The base is the default branch (`main` or `master`), never a branch you made
   locally** (`ship` opens the PR against it and fails if it is not on origin; `goal new` prints "could not fetch origin ... couldn't find
   remote ref" when it is not). Pass `--base` only when the user names another one. Write the request, checkable criteria each with a
   `proof:`, and out of scope. A `proof: screenshot: <name>` line holds only the names. A proof may not name a command the run cannot
   execute (not in `[tools] allowed`). Check `budget_usd`, `turn_timeout_min` and `model` in the created `goal.md`: older builds drop them
   from a `--from` file and use the config defaults. Show the goal to the user. **`wb goal approve` only when the user says to go.**
3. **Prerequisites land first.** If the run needs something it cannot create itself (a synced API contract from another repo, a
   migration), land that on the default branch as its own PR before creating the thread. A run's file tools stop at its worktree, so it
   cannot read sibling repos or write under `.claude/`.
4. **Run.** `wb run` takes minutes; start it in the background and follow with `wb status` and `wb log` (`-f` follows). Denied tool calls are
   normal (compound `a && b`, `node -e`, an env prefix); the model works around them. `wb grant` lists them and decides each.
   `wb stop` ends a turn cleanly.
5. **Review.** `wb review`: the criteria, the diff, the check and the denied calls. Read the diff for what you did not ask for: unrelated
   files, a generated file with thousands of changed lines. A person can see what a run changed with `wb open` (the worktree in their
   editor, with the branch's diff in Source Control; `--print` gives the path). Run yourself what the run could not (the full check, lint, typecheck). Look
   at the verifier's screenshots with `Read`; its report is a note, not a pass. Wrong or incomplete: `wb send-back "<note>"`
   (same thread, next turn). Fix tool denials with `grant` or the allowlist, never with `Bash` or `mix:*` unrestricted.
6. **Accept.** `wb accept -m "<conventional commit>"` commits the work on `workbench/<id>` and ends the thread. Nothing is pushed.
7. **Ship.** `wb ship --yes` pushes the branch and opens the PR (a read-only turn writes the description). If it fails after the push,
   fix the cause; if you open the PR by hand, say so, because `ship` then recorded nothing and `clean` will not know the PR.
8. **PR review.** `wb pr-review --pr <n>` (read-only, rounds counted in the log; or `ship --review-loop`). Exit `0` clean, `15` findings,
   `1` no verdict (never a pass). Treat each finding as a claim: verify it against the code, fix what holds with a test that fails
   without the fix, say which you rejected and why. Two rounds at most; the rest goes in the PR description. A review reads code and
   cannot run tests, so CI must be green as well. In the Workbench repo itself, `scripts/codex-review.sh` does the same.
9. **Stop.** Never merge on your own: runs cannot (`gh pr merge` is denied) and neither do you unless the user says to. "Merge when
   green" means: `gh pr checks <n> --repo <owner/repo>` passes, in dependency order (a backend that adds an endpoint before the
   frontend that calls it), with the repo's merge style (look at its recent history). After a merge: pull the default branch where the
   user's tooling expects it, rebuild `wb` if Workbench changed, `wb clean --yes` for shipped threads, and list the open PRs that now
   need a rebase.

## Rules that apply throughout

- One PR per task; branch names, commit messages and PR titles follow the repo's conventions (Workbench: Conventional Commits).
- A change to what a `workbench` command does ships its verify-cli scenario, run by hand normally and sabotaged (`AGENTS.md` in the
  Workbench repo). Costs money when a turn runs; say so before running one.
- Do not put secrets, real work data or customer content in goals, PRs, comments or screenshots; mock data only.
- Report each turn's cost from `wb status`; stop and ask when a thread nears its budget instead of raising it silently.
- Gaps found while driving the CLI go in `docs/plan/FRICTION.md` of the Workbench repo, with what happened and what would have
  prevented it.
