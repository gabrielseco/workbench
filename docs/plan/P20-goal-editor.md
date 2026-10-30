# P20: Edit the goal in the app

Status: slices 1 (#302), 1b (#303) and 2 built; 3 is later. Written 2026-10-29. Follows [P19](P19-swiftui-app.md) slice 1b (the New goal popover, built in #300).
This document describes future behaviour; `docs/spec/` still describes what ships.

**Outcome:** you write what needs to be done in the New goal popover, the agent drafts the goal, and you review, correct and
approve it in the app. You never open VS Code to change a criterion. The goal file stays the source of truth; the app is a
better way to read and change it.

```
popover: write the request ──▶ agent drafts goal.md ──▶ Goal screen: blocks you can edit ──▶ Approve / Approve and run
                                                         └─ per-goal switches: verifier, judge, design review
```

## Decisions already made

- **The popover stays what it is now** (#300): it only captures the request and starts the draft. No blocks inside it.
- **The Goal screen becomes the nice view and the editor** ("option A" of 2026-10-29). It already is where you review and approve.
  The block look comes from the prototype below. The popover then closes onto an editable goal.
- **The editor is small at first:** edit a criterion's text and proof, add or remove a criterion, edit out of scope and the
  request, switch steps off for this goal. Everything else stays in the file; "Open in editor" stays as the escape hatch.
- **Per-goal steps:** a `skip:` list in the goal's front matter turns the verifier, the judge or a review stage off for that
  goal only. The project's config still says what is on by default.
- **The app edits drafts only** (decided 2026-10-30): once a goal is approved the thread is in another step (Run, Review), so
  the Goal screen shows it read-only. Core stays permissive: `editGoal` on an approved goal still works and the hash makes it
  `stale` (an edit in the file by hand does the same), so the approval rules do not change.
- **Reference folders:** the project config's `read_also` shows read-only ("from project config"); a goal may add its own with a
  `read_also:` line, bound by the approval hash, at most 5 together (slice 1b).
- **The thread name stays derived** from the request's first line. No field for it anywhere.
- **No new CLI command** for editing in this phase: core gets an API, the app is its only caller.

## What exists today (checked 2026-10-29)

- `GoalFile.parse(_:)` and `Goal` (`Sources/WorkbenchCore/Goal/`), with `contentHash` and the approval states `approved`,
  `draft`, `stale`. **There is no writer**: nothing turns a `Goal` or an edit back into `goal.md`.
- `ThreadService.approve(id:config:)`; the Goal screen (`GoalView.swift`, `GoalModel.swift`) shows the draft **read-only**, with
  "Change these in the goal file." and `Open in editor`.
- The popover: `NewGoalPopover.swift` (`NewGoalLayer` in `RootView`), drafting through `ThreadService.draftGoal`.
- What runs after a turn: the verifier (`[verifier]`), the judge and review stages (`[review] auto`, #299), and `workbench next`
  and the Review screen's "Still due" (#297, #298). All project-level today; none can be switched off for one goal.
- Fixtures with real drafted goals: `Fixtures/app/*/threads/*/goal.md` (written by `Tests/WorkbenchAppTests/AppScenario.swift`).

## Slices (one PR each)

### 1. Core: edit a goal file, and `skip:`

- `GoalEditor` in `WorkbenchCore/Goal/`: operations `setTitle`, `setRequest`, `addCriterion`, `updateCriterion(id:text:proof:)`,
  `removeCriterion(id:)`, `moveCriterion`, `setOutOfScope`, `setSkip`, `setReadAlso` (slice 1b). Each reads the file, applies one change and
  writes it atomically (temp file and rename). Parts it does not model are kept as written.
- Refuses with a reason (never guesses) when the file does not parse cleanly, when a turn is running, or when the thread has ended.
- Criterion ids: new ones take the next free `cN`; removing one does not renumber the others (the proofs, the log and the
  judge refer to ids).
- `skip:` in the front matter: entries are `verifier`, `judge` or a stage name from `[review] stages`; an unknown name is a
  goal error naming the key. Honoured by `runVerifier`, `runAutoAdvice`, `NextSteps` (a skipped step is not listed) (the first prompt has no verifier line to change). Check that `contentHash` covers the front matter, so changing `skip:` after approval
  makes the approval stale (write the test that proves it).
- Docs in the same PR: `docs/spec/goal-file.md` (the `skip:` key and the editor's rules), `exit-codes.md` if `run` or `next` output changes.
- **Tests:** round-trip every fixture goal (parse, edit nothing, write: bytes unchanged); each operation on a goal with an unknown
  section, a comment and odd spacing (those survive); a refused edit while a turn runs; `skip` honoured by each of the four callers.
- **verify-cli:** extend `scripts/verify-cli/next.sh` and `auto-advice.sh` with a goal that skips the judge (the step must not be
  listed or run), run normally and with `VERIFY_CLI_SABOTAGE=1`. Costs nothing (they use the fake claude).

### 1b. Core: `read_also:` in the goal (built)

- Optional `read_also:` front matter line (comma-separated folders, the config's syntax rules, each once, at most 5 with the
  config's). In the approval hash when set, sorted. `GoalEdit.setReadAlso`. The run reads the config's list then the goal's;
  `goal approve` resolves them and refuses one that is no checkout or too many together.
- verify-cli: `read-also.sh` puts a second repository in the goal's line and the turn must read both words.

### 2. The Goal screen as blocks you can edit (built)

- Replace the read-only sections with blocks in the prototype's look: the request in the serif face, each criterion as a card
  with a proof chip (test, command, screenshot, by hand) and a status line from the existing `CriteriaStatus` / proof-command
  logic (the "Heads up" rows become the amber status on the card), out of scope, and reference folders (the config's read-only, the goal's editable).
- Edit in place through `GoalEditor`; saving on commit (Return or focus out), never on every keystroke. A write that is refused
  shows the reason on the card.
- The "After the turn" chips (verifier, judge, design review) write `skip:`.
- Editable only while the goal is a draft; an approved goal shows the same blocks read-only (`Open in editor` stays).
- Buttons as today: `Approve and run` / `Run` / `Approve`, `Open in editor`, `New goal…`.
- Keep a way to add a block (`+ criterion`, `+ out of scope`, `+ reference folder`); the `/` menu is a later nicety.
- **Tests:** `GoalModel` derivations (cards, statuses, banner); editing through a stub `GoalActions`; an approved goal offers no edit.
- **verify-app:** drive `goal-warning` (edit a criterion's proof so the warning clears) and `goal-approved` (the blocks are read-only). Add a fixture with a skipped step if none shows it. Screenshots only if the owner asks for them on that PR.

### 3. Later, not planned yet

- `/` menu and drag to reorder; blocks for screenshots in the goal.
- The drafter filling the editor live while it works, instead of a spinner.
- Project picker redesign (below).

## Prototypes to start from

Clickable, private to the owner, HTML and Tailwind; the SwiftUI versions should match their feel, not copy their code:

- Full-page canvas: <https://claude.ai/artifact/B8QTiSb8kF14Q9k5JQfQ6j> (the block look slice 2 is after)
- Popover with the per-goal "After the turn" chips: <https://claude.ai/artifact/Qb4BjSK3oA1XTJVXTRADGQ>

## Risks

- **Round-trip safety is the whole job of slice 1.** The agent writes `goal.md`; a writer that reformats or drops something it
  does not understand would silently change a goal the person approved. Hence "unchanged bytes" tests on every real fixture
  and "refuse, don't guess".
- **Ids:** renumbering would break the log's references; the rule above avoids it, and the tests should pin it.
- **A turn running while you edit:** the file is read by the run; refuse edits while one is live.
- **Window width:** the card layout must hold at the window's minimum (900 pt).

## Open questions

1. (Decided: drafts only; see above.)
2. Should `skip:` accept `design` as an alias for a stage named `design`, or only exact stage names? Leaning: exact names only.
3. Does a goal with the verifier skipped still accept `screenshot:` proofs? Today that is the "Heads up" case (a screenshot proof
   with no verifier); keep it, and word the warning for the skip case.

## Also queued (separate from this phase)

- **Project picker:** a searchable card under the project pill, with live state per project (running, needs you, done), the
  projects found under `projects_dir` in `~/.workbench/config.toml` as well as the recent ones, ↑↓ and ↵, "Choose folder…" at the
  bottom. Reading each project's state means reading its event log: do it when the card opens and while it stays open, not by
  polling every project. HTML mock first, then SwiftUI.
- **Owner's side:** grant Screen Recording to the rebuilt Workbench.app and run a Triage goal with a `screenshot:` criterion, to
  see the verifier, the `[run]` block, the stable signing and `[review] auto` work together for real (nothing has run that path
  end to end). Try "Open diff" once in the real editor. `docs/friction-p19-runs` (PR #263, closed unmerged) and the worktrees
  `workbench-profile`, `workbench-worktrees/measure`, `.workbench/worktrees/mac-app-design` hold work that is not on `main`.

## Where this started (merged on 2026-10-29)

#293 stable app signing, #294 `doctor` names the right app, #295 the verifier reports only what it can see, #296 the review
workspace (`open --diff`), #297 `workbench next`, #298 "Still due" on the Review screen, #299 `[review] auto`, #300 the New goal popover.
