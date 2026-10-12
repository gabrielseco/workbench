# Triage integration (later)

**Outcome:** from a PR in Triage you can start a Workbench thread with the PR as context ("fix this CI
failure", "address these review comments"), and see the thread's status next to that PR.

**Depends on:** P3 in daily use; proof optional. Do this only once Workbench is something you use daily.

## Why last

Triage is an inbox that works. Integrating early is how Workbench's churn leaked into it. By then Workbench has
a stable core and a stable on-disk format, so the integration is thin.

## Options (decide at the start, by trying the cheapest)

| Option | How | Cost | Coupling |
|---|---|---|---|
| A. URL scheme | Triage opens `workbench://new?repo=…&branch=…&prompt=…`; Workbench creates a draft goal | S | None; one-way |
| B. Shared status file | Workbench writes `status.json` per PR branch; Triage reads it | S | Loose, file format only |
| C. Embed the core | Triage links `WorkbenchCore` and shows threads in its own UI | L | Tight; Triage inherits the process layer |

Recommendation: **A then B.** Skip C unless A and B prove too awkward. Embedding the runner into Triage is
exactly the coupling we backed out of.

## Scope (A + B)

In:
- `workbench://new` handler: repo, branch or PR number, a suggested goal body (from the CI failure or the
  review comments), profile suggestion. Always lands as a **draft** for you to edit and approve.
- Triage "Fix with Workbench" action on CI-failure and review-comment items, building that URL.
- Workbench publishes a small status per branch (`draft`, `running`, `review`, `done`, `failed`) that Triage
  shows as a badge on the PR row.

Out: Triage starting runs itself, shared storage, two-way sync of goals, anything that makes Triage depend on
Workbench being installed (the action is hidden if the URL scheme has no handler).

## Design notes

- **Goal drafting from a PR item:** Triage already builds fix prompts for its "Explain & propose fix" and
  handoff features; reuse that text as the draft's Request, and turn failing check names into criteria.
- **Branch handling:** the thread's worktree is cut from the PR head branch so work lands on the PR; the
  thread branch name makes that explicit. Fork PRs are out of scope (you never work with them).
- **Status file location:** `~/Library/Application Support/Workbench/status/<repo>/<branch>.json`, written
  atomically, tiny, versioned. Triage treats a missing or unreadable file as "no thread".

## Tasks

1. **URL scheme handler** in Workbench with strict parsing and a confirmation of what it will create.
2. **Draft from context.** Request text and criteria generation for CI failure and review comments.
3. **Triage action.** Button on the relevant item types, hidden without a handler, one PR in Triage.
4. **Status publisher** in Workbench, atomic writes, version field.
5. **Status badge** in Triage rows, from the status file.
6. **Docs.** Both repos describe the contract (URL params, status format) in one place.

## Acceptance criteria

- [ ] From a failing-CI item in Triage, one click opens Workbench with a draft goal for that branch.
- [ ] Nothing runs until you approve in Workbench.
- [ ] Triage works unchanged, with no errors, when Workbench is not installed.
- [ ] The badge reflects the thread within a refresh cycle and clears when the thread is discarded.
- [ ] Malformed or hostile URLs are rejected with a visible message; no path traversal, no command strings
      from the URL are ever executed.
- [ ] Triage gains no process-spawning code for this feature.

## Risks

| Risk | Mitigation |
|---|---|
| URL carries untrusted PR text | Treat as data only, show it in the draft for review, never execute |
| Two apps drift on the contract | Version fields on both sides, tests that parse each other's sample payloads |
| Scope creep into "Triage runs agents" | Decision log: Triage only launches and displays; Workbench owns running |

## Demo

A real failing CI item in Triage → Fix with Workbench → edit the draft → approve → review → accept, and the
PR row shows `review` then `done`.

## Open questions

- Do review-comment threads map to one goal or one per thread? Leaning: one goal, comments as criteria.
- Should accepted work push the branch from Workbench, or hand back to Triage's existing flow?
