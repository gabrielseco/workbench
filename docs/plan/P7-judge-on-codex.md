# P7: The judge runs on Codex

Status: superseded, nothing built. Written 2026-10-17. Retained as the historical motivation for
independent evaluation; [P9: Agent providers](P9-agent-providers.md) replaces this implementation plan.

P9 extracts shared provider adapters for run, judge and automated review instead of a Codex-only
runner. It permits any compatible provider at each responsibility, including the same provider with
independent contexts. It preserves the existing Claude judge default for compatibility; the default
Codex switch, `[judge] reviewer` schema and forced vendor split proposed below are not adopted.
P9 carries forward the judge contract, advisory failure behaviour, images and timeout/retry tests.
Follow P9 for implementation, configuration and the prerequisite gate before SwiftUI.

The remainder records the original unbuilt proposal, not current or planned configuration.

## The idea

Whoever does the work should not be the one who grades it. The split Workbench should have:

| Step | Runs on | Why |
|---|---|---|
| `run`, `send-back`, the follow-up threads | Claude | it writes the code |
| `judge` | Codex | a second AI checks each criterion against the evidence |
| `pr-review` and every other review stage | Codex | a second AI reviews the PR |

Today the first and last rows hold, and `judge` does not: it is a read-only `claude -p` run (`Thread/Judge/`), so the
AI that wrote the diff also says whether the criteria are met. The judge is advisory and never gates `accept` or
`ship`, but it is the verdict people read first, and it is the same model's opinion of its own work.

## What the judge is today

- One read-only `claude -p` turn in its own working folder, its own session, no numbered turn. Fixed budget
  (`Judge.budgetUSD`, $0.50) and timeout (300 s), once per turn unless `--again`.
- Input assembled by Workbench: the goal, the diff (cut at 120 KB), the check result and the tail of its output, the
  verify result, the names of untracked files, and the screenshots as files in its working directory.
- Output: one JSON object, `{criteria: [{id, met, evidence}], concerns}`, held to limits (3 evidence lines per
  criterion, 300 characters each, 8 concerns). Recorded in the `judge.ran` event; `review` shows it next to the
  person's own ticks.
- A missing `claude`, a timeout, a budget stop or an unusable answer mean "no verdict this time", with the reason
  shown. They never fail the thread.

## What to build

### 1. A shared Codex runner

`PRReview` already starts Codex the way the judge needs: `codex exec -s read-only -C <dir> --color never --ephemeral
-o <answer file>`, the prompt through a brief file (the `Spawner` fixes stdin to `/dev/null`, so the argument is a
one-line pointer), retries on "at capacity", a timeout with a process-group sweep, stored transcript. Move that into
one runner that both use, so there is one implementation of "start Codex read-only and get its last message back".
No change in behaviour or events for `pr-review`.

### 2. `[judge] reviewer`

```toml
[judge]
reviewer = "codex"    # "codex" | "claude"; default "codex"
```

- **Codex path:** the same input and the same JSON contract. The brief says to answer with the one JSON object and
  nothing else; `Judge.parse` already takes the outermost object out of fenced or wrapped text. The screenshots are
  attached with `-i`, and their names are listed in the brief. The working folder is the judge's own, as today.
- **Claude path stays** for projects without Codex, selected explicitly. There is no silent fallback: with
  `reviewer = "codex"` and no `codex` on PATH the judge records "no verdict this time: `codex` was not found" and
  the thread stays reviewable, as it does for a missing `claude`.
- **Budget:** `codex exec` does not report a price the way `claude` does, so the dollar budget cannot be enforced
  or recorded. The timeout and the once-per-turn rule are the limits, and `judge.ran` records `cost: unknown` for
  Codex. This is the one thing that gets worse; see the open questions.
- **Events:** `judge.started` and `judge.ran` gain `reviewer`. Everything else about them is unchanged, so old logs
  still read. `review --json` gains `reviewer` inside the existing judge object.
- `doctor` warns when `reviewer = "codex"` and `codex` cannot be found.

### 3. Tests

Extend `fake-codex` (it already scripts verdicts, capacity errors and hangs): a clean verdict, an unmet criterion,
a verdict wrapped in a fence, invalid JSON, "at capacity" then success, a hang ended at the timeout with nothing
left running, screenshots passed with `-i`, `claude` still used when set explicitly, `codex` missing shown as "no
verdict", the default config choosing Codex, and the Claude path unchanged. The `judge.ran` of an old log still
renders.

## Order

1. The shared Codex runner (S), no visible change.
2. `[judge] reviewer`, the Codex path, events, spec, tests (S to M).

## Open questions

- **Default:** `codex` changes what existing projects get on their next `judge`. Default `codex` (what this plan
  proposes) or keep `claude` until a project opts in? A release note either way.
- **Cost:** is "unknown" acceptable for Codex, or should Workbench read the token usage `codex exec` prints and
  record that instead?
- **Screenshots:** Codex accepts images with `-i`, but how well it reads a UI is untested. The Triage pilot (P6
  task 5) is the first real check; if it is poor, a judge on Claude stays available through `reviewer = "claude"`.
- **One runner or two:** whether the judge and the review stages share a config table (`[review] reviewer`) rather
  than `[judge] reviewer`. Default: separate, since the judge is not a stage.
