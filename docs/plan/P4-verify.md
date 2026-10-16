# P4: Verify

**Outcome:** a thread ends with evidence you can look at: screenshots of the change, a recorded verify step
and, optionally, an independent verdict, all produced in the background with no UI and no prompts. First
proven on a web app (expense-tracker, Playwright), then on a native one (Triage, which is the hard case).

**Depends on:** P2.6 merged. Independent of [P3](P3-app.md): the app will only display what this phase
records. This pulls a slice of [`later/proof.md`](../later/proof.md) forward on purpose, because a thread
that cannot show the change on screen cannot be trusted for UI work (friction #41).

## Why Workbench cannot verify today

- `--safe-mode` removes skills, so `/verify`, `verify-ui` and `/design-review` do not exist in a run.
- `[tools] allowed` is `git` and `swift`; with `--permission-prompts none` every other command is denied.
- `--restricted` confines file writes to the worktree; screenshots and bundles are written elsewhere.
- The child environment is an allowlist, so a run does not hold the Screen Recording / Accessibility context
  of the terminal that started it.
- Only the project's `check_command` can make a criterion `passed`; every other proof is "you check".
- Nothing stores or shows a screenshot, and `ship` cannot attach one to the PR.

Opening the allowlist for Claude is the wrong fix: it would trade the boundary for convenience. The fix is
that **Workbench runs the verify step itself**, the way it already runs the check.

## Scope

In:
- `verify_command` in the project config, run by Workbench after a turn's check.
- A fixed environment contract for it (proof dir, port) and the same process-tree cleanup as the check.
- Events and storage for proof, shown by `review`, `status` and `--json`.
- Typed `screenshot:` proof in goals.
- `ship` puts the screenshots in the PR description through `pr-shots`.
- An optional, advisory verifier turn that reads the evidence.
- Pilot on expense-tracker, then Triage.

Out: the app's proof gallery (P3 reads what is recorded here), before/after captures, video, making
verification mandatory, running Claude with screen or browser tools, any change to `--restricted` or the
tool allowlist for the sake of verifying.

## Design

### The verify contract

A project declares one plain command, validated like `check_command`:

```toml
verify_command = "scripts/verify.sh"
```

Workbench runs it in the thread's worktree, after the turn's check, with the check's environment rules plus:

| Variable | Meaning |
|---|---|
| `WORKBENCH_PROOF_DIR` | Absolute, empty directory in the thread folder. The command writes `*.png` here, and may write `verdict.json` |
| `WORKBENCH_PORT` | A free TCP port, so two worktrees never fight over `:3000` |
| `WORKBENCH_THREAD`, `WORKBENCH_GOAL` | Thread id and the path of `goal.md`, so the command can read which pages or states to capture |

Rules:
- Bounded: its own timeout (`verify_timeout_min`, default 10), capped output, and the whole process tree
  (dev servers it started) is swept on every exit path, like the check. A verify that cannot say how it ended
  is a bug.
- Headless by contract. A project whose verify needs the screen (Triage) says so in `doctor`, which checks
  the permission first and fails with an actionable message instead of saving a blank image.
- Its result is recorded, never trusted as a pass: exit code, duration, and the files found in the proof dir.
  A missing or unreadable file is "missing", never "met".
- Failing verify does not block `accept` or `ship`; it is shown, like a failed check.
- Each project owns its command. Workbench does not know Playwright, `bundle.sh` or `ax.swift`.

### Events and storage

`verify.started`, `verify.ended` (`exit_code`, `duration_ms`, `result`) and one `proof.added` per file (`name`,
`path`, `sha256`, `bytes`). The proof dir lives under the thread folder, so `discard` keeps the log and drops
the worktree as it does today. The event log stays the source of truth: the gallery reads `proof.added`,
not the folder. Spec in `docs/spec/event-log.md`; `--json` keys are added, never renamed.

### Typed proof

`proof: screenshot: <name>` is satisfied by `<name>.png` in the latest verify's proof. `review` shows each
criterion with its file, or "missing". `check:` proofs keep today's meaning. Free-text proofs still parse.

### Verifier turn (advisory, one pass)

After verify, `workbench verify --judge` (or a config flag) starts a second `claude` run, read-only, with the
goal, the diff, the check output and the proof list. It writes `verdict.json`
(`{criteria: [{id, met, evidence}], concerns}`). Fails only on an evidenced violation of a criterion's literal
text; everything else is a concern. Fixed budget and timeout, runs once per review unless asked again, and a
bad or missing verdict leaves the thread reviewable with the failure shown. It never gates `accept`.

### Pilots

- **expense-tracker** (Playwright, `verify-ui`): `setup_command = "npm ci"`; `scripts/verify.sh` starts
  `npm run dev:mock` on `$WORKBENCH_PORT`, runs `verify-ui` for the pages the goal names, saves to the proof
  dir. The saved login under `.auth/` is gitignored, so the script regenerates it in the worktree (mock mode
  accepts any email). Mock mode only: `--real` needs a backend and stays out.
- **Triage** (native): `scripts/verify.sh` wraps `bundle.sh` and `snap.sh`. It needs Screen Recording and
  Accessibility for the process that runs it and must not replace the user's installed app without being
  declared (see task 6). Dark mode only.
- crm has no UI driver yet; adding one is its own task in that repo.

## Tasks

1. **`verify_command` step** (done: `Thread/Check/VerifyRunner.swift`). Config key and validation, env contract, bounded run with tree sweep, events,
   `status` shows "verifying", `review` lists the proof files. Fake-claude tests: passing verify, failing verify,
   timeout, killed mid-verify, empty proof dir, a dev-server grandchild left running.
2. **Screenshot proof** (a: parser, `review`, `--json`, PR table: done. b: `ship` attaching through `pr-shots`: done). Parser, `review` and `--json`, spec, "missing" never "met". `ship` attaches the
   screenshots through `pr-shots pr` (or says it is not installed).
3. **expense-tracker pilot** (done 2026-10-16: a throwaway label change, goal to review with a screenshot, `$0.0038` on haiku; see friction #42 to #44; `ship` against a real PR was not run). `.workbench/config.toml` and `scripts/verify.sh` in that repo; one real small UI
   task from goal to PR with screenshots in the description. Record what broke in `FRICTION.md`.
4. **Verifier turn** (done as `workbench judge`: `Thread/Judge/`; not `verify --judge`, since it is its own command with its own once-per-turn rule). Prompt builder (reuse expense-tracker's `verifier` agent text as the starting point),
   strict verdict schema (the verdict is recorded in the `judge.ran` event, the log being the source of truth, not in a `verdict.json`), read-only tool set, budget, failure shown, advisory.
5. **`doctor` checks verify.** Runs `verify_command` in the throwaway worktree, reports duration, files, and a
   missing Screen Recording grant as a clear failure. Writes down whether the child inherits the terminal's
   permissions.
6. **Triage pilot.** Verify script, app-swap policy (a separate throwaway bundle that does not touch the
   installed app, or an explicit declaration that restores it on every path), one real task.
7. **Use it on Triage.** Two threads, both through Workbench end to end: bot findings ordered (yours first,
   newest created first, then others', whose findings show review actions instead of Fix), then "Fix with
   Workbench" on a bot finding as a draft goal (`docs/later/triage-integration.md`, option A).

Tasks 1 and 2 are separate PRs. Tasks 3, 6 and 7 mostly land in the other repos, each with its own PR there.
Docs travel with the code.

## Done when

- [ ] A thread on expense-tracker ends with a PNG shown by `review` and a recorded `verify.ended`.
- [ ] A verify that hangs, crashes or is killed still ends the turn's thread in a recorded state, and leaves
      no dev server running (tested, then checked by hand with `lsof` on the pilot).
- [ ] A criterion with `screenshot:` proof and no file shows "missing".
- [ ] `ship` puts the screenshots in the PR description, or says why not.
- [ ] A bad verdict or a verifier timeout leaves the thread reviewable.
- [ ] No change to `--restricted`, the tool allowlist or safe mode was needed.
- [ ] Triage's two tasks were done through Workbench, and the friction they exposed is written down.

## Risks

| Risk | Mitigation |
|---|---|
| Verify becomes a mandatory gate again | Advisory, never blocks `accept` or `ship`, one pass, budget cap |
| Dev servers outlive the run | Process-tree sweep on every exit path, tested with a grandchild |
| Port collisions between worktrees | Workbench hands out the port; the script must use it |
| Native verify steals focus or replaces the user's app | Separate throwaway bundle, declared in config, never `pkill` on a guess |
| The child lacks Screen Recording | `doctor` fails loudly; the capture refuses to save a blank image |
| Claude fakes evidence | Workbench runs the command and hashes the files; the diff is the ground truth |
| Scope creep into the app's gallery | P3 reads `proof.added`; nothing here draws UI |

## Open questions

- Does the child inherit the terminal's Screen Recording grant when `workbench` is run from iTerm? Task 5.
- One `verify_command` per project, or per criterion? Start with one; the goal file names the pages.
- Should the verifier see the images, or only text evidence? Leaning: include images, keep it advisory.
