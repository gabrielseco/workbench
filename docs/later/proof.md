# Proof (later)

**Outcome:** each criterion can carry real evidence (check output, a screenshot, a diff pointer), and an
optional independent verifier can say whether the evidence meets the criteria. This is the "it verifies its
own work and shows me" part.

**Depends on:** P2. Review exists; this makes its criteria checklist evidence-backed instead of self-reported.

## Scope

In:
- Typed proof on criteria: `check`, `screenshot`, `diff`, `note`.
- Screenshot capture protocol for GUI work, driven by a project-provided command.
- A proof gallery in review: evidence next to each criterion.
- Optional **verifier turn**: a separate, read-only Claude session that judges criteria from evidence.

Out: running arbitrary UI automation frameworks for the user, cross-project screenshot tooling, video, CI
integration, anything that makes verification mandatory for every thread.

## Design

### Proof types in the goal

```markdown
- [c1] Retries on 5xx.            - proof: check: swift test --filter SyncClientTests
- [c3] Settings screen unchanged. - proof: screenshot: settings
```

`check:` runs through the P2 check runner for that command. `screenshot:<name>` is satisfied by a file at
`proof/<name>.png` produced during the turn or by the review step.

### Screenshot protocol

Workbench does not know how to drive every app. The project declares a command:

```toml
[project.screenshots]
command = "scripts/snap.sh {out}"   # {out} is replaced with the absolute output path
```

- The turn's system prompt tells Claude that criteria with `screenshot:` proof are satisfied by running that
  command (allowed in the profile as an exact command) and saving to `proof/<name>.png`.
- Workbench also offers "Capture now" in review for the same command, so a missing screenshot is not a
  re-run of the whole turn.
- Files are content-hashed and recorded as `proof.added` events; the gallery reads those, not the folder.

### Verifier turn (optional, bounded)

A second `claude` run, `read-only` profile, given: the goal, the diff, the check outputs and the proof list.
It writes `verdict.json`:

```json
{"criteria":[{"id":"c1","met":true,"evidence":["check: swift test … exit 0"]}],"concerns":[]}
```

Rules, learned the hard way in Triage:
- **Fail only on an evidenced violation of a criterion's literal text.** Everything else goes in `concerns`
  for you to read; it never silently blocks.
- **One pass, proportional.** No open-ended hunting; a fixed budget and turn timeout.
- **It reads evidence, it doesn't re-run the suite.** Checks were already run by Workbench in P2.
- **Advisory.** The decision stays yours. The verdict is shown next to your own ticks.

## Tasks

1. **Typed proof.** Extend the goal parser and the review checklist; tolerate old free-text proofs.
2. **Check proof wiring.** Map `check:` proofs to P2 runs and show pass/fail per criterion.
3. **Screenshot command.** Project setting, allowlist the exact command in the thread's profile, `proof.added`
   events, content hashing.
4. **Capture now.** Review button running the same command with clear permission guidance (screen recording).
5. **Gallery.** Per-criterion evidence view with zoom, before/after if a base capture exists.
6. **Verifier turn.** Prompt builder, read-only profile, strict `verdict.json` schema, tolerant of failure.
7. **Verdict UI.** Show verdict beside manual ticks; disagreement is visible, not resolved automatically.

## Acceptance criteria

- [ ] A goal with a `screenshot:` criterion ends with a recorded PNG shown beside that criterion.
- [ ] A `check:` criterion shows the exit code and output from Workbench's own run.
- [ ] Missing or unreadable proof is shown as missing, never as met.
- [ ] The verifier turn cannot write outside the thread folder (read-only profile; tested with a denied write).
- [ ] A verifier that returns invalid JSON or times out leaves the thread reviewable; the failure is shown.
- [ ] The verifier runs at most once per review unless you ask, and respects its own budget.
- [ ] Screen recording permission missing gives an actionable message, not an empty image.

## Risks

| Risk | Mitigation |
|---|---|
| Verifier becomes an endless gate again | Advisory only, one pass, budget cap, never required |
| Screenshots are project-specific and brittle | The project owns the command; Workbench only stores and shows |
| Claude fakes evidence | Checks are re-run by Workbench; screenshots are timestamped and hashed; the diff is the ground truth |

## Demo

A UI change in Triage: goal with a screenshot criterion, run, see the before/after, ask for a verifier pass,
read its concerns, accept.

## Open questions

- Is "before" captured automatically from `base`? (Costs a second build; likely opt-in per criterion.)
- Should the verifier see the screenshots (vision) or only text evidence? Leaning: include images, keep it
  advisory.
