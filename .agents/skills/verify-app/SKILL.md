---
name: verify-app
description: Run a PR's build of Workbench.app on a fixture project and check on screen that the change does what the PR says — build this checkout into a throwaway bundle, open it on a scenario (draft, running, needs-you, accepted, pr-open, cleaned, corrupt, no-thread), list what is on screen, press a safe button, screenshot the window, compare it with the PR's claims, then remove the build and its settings. Use for any PR that touches Sources/WorkbenchApp, or when asked to "verify the app", "check it in the app" or "get a screenshot of the window". Core and CLI changes are verified by their tests and the verify-cli skill instead.
allowed-tools: Bash(scripts/verify-app.sh:*), Bash(gh:*), Bash(git:*), Read
---

# Verify the app

The core and the CLI have tests and `verify-cli`; nothing else looks at the SwiftUI app. This skill runs the PR's code as a real bundle
on a **fixture project** (never a person's own), looks at it, and says whether it matches what the PR claims. Everything that keeps this
safe is in `scripts/verify-app.sh`; do not call `open`, `kill`, `pkill`, `screencapture` or `scripts/bundle-app.sh` yourself.

Workbench's verifier turn runs this skill on a thread's worktree: `[verifier] skill` in `.workbench/config.toml` names this file by its
real path (a symlink is refused), after a turn whose check passed. That costs a turn per run; `enabled = false` turns it off.

## Under Workbench

If `WORKBENCH_PROOF_DIR` is set, Workbench started you (`workbench verifier`) and only this section applies; sections 1, 5 and 6
are for a person's checkout. You have `Read` and `scripts/verify-app.sh`, nothing else: no `gh`, no `git`, no `open`, `kill` or
`scripts/bundle-app.sh`. There is no pull request: the change is in your worktree and the goal is the claim.

1. **What to show.** Read `$WORKBENCH_GOAL`: each criterion and its `proof:`. A `proof: screenshot: <name>` line names `<name>.png`,
   which you leave in `$WORKBENCH_PROOF_DIR`. `Read` the files the criteria name when you need to know what should be on screen.
2. **Pick the scenario** from the table in section 2 and `scripts/verify-app.sh start <scenario>` (the build takes minutes: it is a
   release bundle). Keep the pid; every other command needs it. If the state a criterion needs is in no scenario, say so in the report;
   do not use a real project.
3. **Drive it** as in section 3, except: never `start draft-goal` (it spends Codex usage), never press `Run` or `Run again` on `running`
   (it starts a real turn), and do not try `Ship…` beyond seeing the refusal it shows on the fixture. `press`, `type`, `focus`, `typekeys`,
   `key`, `click`, `hover` and `scroll` are all yours; `click`, `hover`, `key`, `typekeys` and `scroll` take over the machine while
   they run, which is expected here.
4. **Capture.** `scripts/verify-app.sh shot <pid> <name>` writes `$WORKBENCH_PROOF_DIR/<name>.png`; `Read` it and look. If it does not
   show the state, press again and shoot again under the same name. A criterion that names several screenshots (before and after a
   press, a second window size with `VERIFY_WINDOW_SIZE=900x600`) gets one `shot` each, in the order the goal names them. A design
   change is captured at 900×600 and at a roomy size.
5. **Stop it, always,** with `scripts/verify-app.sh stop <pid>`, also when a step failed.
6. **Report.** One line per criterion: its id, `holds` or `does not hold`, what you saw (quote the `list` line) and the file. Say plainly
   what you could not reach or may not press. Workbench shows this as a note beside the screenshots; it decides nothing, a person
   looks at them.

## 1. What should be visible

Read the PR (`gh pr view <n> --json title,body,files`, `gh pr diff <n>`) and write a short checklist of things you can see on the
screen: which state, what text, what colour (blue is working or your current step, green done, grey not yet, amber needs you, red broken),
what should now differ. Add one unchanged neighbour as a regression check. If nothing in the diff is visible, say so and stop.

## 2. Pick the scenario

`scripts/verify-app.sh scenarios` lists them. Each is a committed project under `Fixtures/app/<name>/`:

| scenario | what the window shows |
|---|---|
| `draft` | a goal being written, not approved: Goal is current, nothing else started |
| `goal-warning` | a draft with three criteria, two of which cannot be checked (a command not in `[tools] allowed`, a `screenshot:` with no verifier): `Heads up` rows, `1 OF 3 CHECKABLE`, Approve disabled |
| `goal-long-request` | an approved goal with a request long enough to be folded ("Show more"), `command:` and `test:` proofs |
| `goal-approved` | an approved goal, nothing run yet: `Approved` pill, a `Run` button |
| `running` | a turn is open in the log with activity rows, and no live runner (a fixture cannot have one): Run is current, attention is `working`, the Run screen says the runner is gone and offers Run again. Never press Run again here: it starts a real turn |
| `review-changes` | `needs-you` with a real worktree on a base commit and three changed files (two edited, one new), so the Review screen lists them, shows a `Still due` section (the judge, and the `design` stage its config declares for `Sources/**`) and `Open diff` is enabled. Its config names a stand-in editor, so pressing `Open diff` is safe: it only writes down what it was asked to open (`scripts/verify-app.sh calls <pid>` prints it) |
| `needs-you` | a turn ended, no decision: Review is amber, `$1.88 of $5.00`, the Review screen: criteria with core's labels, a denied call, `Accept work` disabled because the fixture has no worktree (diff unavailable) |
| `pr-open` | accepted and shipped, PR #482 open, no review yet |
| `accepted` | accepted, no pull request: the finished banner with `Ship…` and `New goal…`; `Ship…` runs a real preflight on the fixture repo, which has no `origin`, so it shows core's refusal and pushes nothing |
| `cleaned` | merged and cleaned, a turn that reported no cost (`unknown`, never `$0.00`) |
| `discarded` | a Codex turn that ended and was discarded: the finished banner with `New goal…`, `ran 4m12s`, `Files changed: unknown`, no "Review comes next" |
| `corrupt` | a log nothing can be read from: the corrupt-log screen |
| `no-thread` | a project with no thread yet |

A state no scenario has is a new scenario: add it to `AppScenario` in `Tests/WorkbenchAppTests/AppScenario.swift`, rewrite the files with
`WORKBENCH_WRITE_FIXTURES=Fixtures/app swift test --filter FixtureScenarioTests/writeTheScenarios`, and commit them (a test fails when they
differ from the helper). Do not point the app at a real project.

## 3. Start, drive, capture, stop

From the PR's worktree, never the main checkout:

```bash
scripts/verify-app.sh start needs-you     # builds, launches, prints pid=, window=, size=. Keep the pid: every other command needs it.
scripts/verify-app.sh list <pid>          # role <tab> label of what is on screen, as text you can read
scripts/verify-app.sh press <pid> "Doctor"  # an exact label, else a prefix; wait about two seconds after it
scripts/verify-app.sh type <pid> "text"   # sets the focused text field (else the only one); Accessibility, no keystrokes, 2000 characters at most
scripts/verify-app.sh focus <pid> "field" # focuses the text field or area with that text or placeholder and selects what it holds
scripts/verify-app.sh typekeys <pid> "text"  # presses the keys of that text (200 printable characters) into the focused field: the app sees real edits
scripts/verify-app.sh key <pid> tab       # one of return, tab, escape, up, down: Tab or a click away leaves a field, Return and Esc end an edit
scripts/verify-app.sh click <pid> "label" # a real left click in the middle of that label; hover <pid> "label" moves the pointer there
scripts/verify-app.sh scroll <pid> 5      # scroll the content down 5 steps of 40 points (negative: up); it settles for a second or two
scripts/verify-app.sh paste <pid> [image]  # Cmd-V to that pid only, with a generated picture or an image file; the clipboard is restored
scripts/verify-app.sh shot <pid> <name>   # writes <name>.png into $WORKBENCH_PROOF_DIR (default .build/verify); Read it
scripts/verify-app.sh calls <pid>         # what the scenario's stand-in editor was asked to open (review-changes only)
scripts/verify-app.sh stop <pid>          # always, also after a failure
```

- **Which command for what.** `type` sets a field's value through Accessibility, which an app that waits for edits does not see (a SwiftUI
  field that commits on leaving it keeps the old text): to try an edit use `focus`, `typekeys`, then `key tab` or a `click` elsewhere. `press`
  uses Accessibility and never moves focus; `click` is a real click, so it focuses a field and takes the focus from the last one, and
  `hover` shows a hover state.
- **`click`, `hover`, `key`, `typekeys` and `scroll` take over the machine while they run**: they bring the build's window to the front,
  move the pointer (it is put back) and send events. A click or hover happens only when this pid's window is the topmost at that point
  and Accessibility says the element there is the one named (a row scrolled out of view, or under the footer, is refused: scroll to it,
  and wait a second). Run them when nobody is using the computer, and on the Space where the window is: a window on another Space cannot
  be clicked ("Another window is on top there").
- `list` first: it shows the text, the step marks (`Review, needs_you, Needs you`) and the buttons, so most claims can be checked
  without looking at pixels. Then `shot`, and **look at the image**: a claim about colour or layout is checked by the picture.
- A `start` that fails or is interrupted (SIGTERM, SIGHUP, Ctrl-C, a window that never appears) leaves nothing (Ctrl-C has the same handler
  as the others; no test sends it): it ends the app it launched and
  removes the build, the fixture copy and the settings. So if `start` printed no `pid=`, nothing is running and there is nothing to `stop`.
- Every command refuses a pid that `start` did not print. `press` refuses `Choose project…` (the empty screen's button),
  `Choose folder…` (in the project card), `Event log` and `Open the event log`: they open a file panel or another app. A claim about those
  buttons is checked by seeing that they are listed. The project pill (`Projects, now …`) can be pressed: it opens the project card.
  `Doctor` can be pressed: it runs in the fixture project and reads `Problem` there (no config), which is the expected answer.
- If a screenshot shows only a wallpaper, Screen Recording is missing for this terminal; `start` says so before it builds.
- The app is launched with the Dock's environment (a bare `PATH`, nothing of the terminal's profile), and like a person's launch it asks the
  login shell for the real `PATH` first; set `WORKBENCH_SKIP_LOGIN_PATH=1` only for a check that must not read a profile. A tool that
  is only on the terminal's `PATH` is therefore not found in a check unless the app finds it, as for a person.
- **Drafting a goal for real** (`start draft-goal`, whose config names the real Codex as the goal agent): `press "New goal…"`, `type`
  a request, `paste <pid> <image>` (a PNG with a code word drawn in it works: the goal can only name the word if the drafter saw the
  picture), `press "Create"`, then `list` every few seconds until "Drafting the goal…" is gone (about 10 s to a few minutes). It spends
  Codex usage; check the goal on screen and `attachments/1.png` in the fixture project's thread folder. A fake agent cannot stand in for
  this: it is how a Codex that will not start in the drafter's folder, or is not on the app's `PATH`, shows up.
- A before and after: run the same commands from a throwaway worktree of `origin/main` (`git worktree add ../wb-main origin/main`),
  name the shots `before-…` and `after-…`, and remove the worktree.

## 4. Permissions

Screen Recording (start, shot) and Accessibility (list, press, window size) for the terminal running this. Without Accessibility, `start`
still runs and `shot` still works at the launch size; `list` and `press` do not: say what you could not drive and ask the person to
click, then `shot`.

## 5. Report

One line per checklist item: ✅ or ❌, what you saw (quote the `list` line), and the screenshot's path. Then the verdict: matches the PR,
or what differs. Say plainly what you could not check: the project picker, opening the log, any click-through, a real project's data,
anything a scenario does not have. Put the screenshots in the pull request with `pr-shots` (below), and list the files too.

This checks behaviour, not looks. A change to how it looks (layout, colour, spacing) is also reviewed against the mockups in `docs/mac-app/`.

## 6. Post the screenshots to the pull request

A PR that changes what the app shows carries the screenshots that prove it, with the PR's own words about what each one shows. From
the PR's branch checkout, after `shot`:

```bash
cp .build/verify/<name>.png "$(pr-shots path <name>)"   # names it ~/screenshots/claude/<project>/<branch>-<name>-<sha>.png
pr-shots pr                                              # uploads this branch's screenshots and writes the PR's `## Screenshots`
```

`pr-shots` is the same tool Triage uses (`~/.config/pr-shots/config.json` holds the store). Running it again replaces the section, so
re-run it after a push that changes the screen. Only fixture screenshots go up (never a person's own project), and never one that
shows a path or name that is not the fixture's. If `pr-shots` is missing or fails, say so in the PR; do not claim the screenshots are
posted.
