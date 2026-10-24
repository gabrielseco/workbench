# P9: Agent providers

Status: plan, nothing built. Written 2026-10-17. Required before [P3](P3-app.md) starts.
Supersedes [P7](P7-judge-on-codex.md)'s proposed fixed provider split. This document describes future
behaviour; the specifications under `docs/spec/` still describe the shipped CLI.

**Outcome:** `run`, `judge` and automated review each work through interchangeable providers, selected
independently in config, while Workbench keeps its existing sequential workflow and reliability guarantees.
Optional agent-assisted goal drafting has its own provider/model selection before approval; manual
goal authoring remains available.

```
Goal (manual or agent draft) → Approve → Run → Judge → Review → Accept / Rerun
              │                         │       │       │
           provider                  provider provider provider
```

This is a responsibility diagram, not a new command order or state machine. Today `judge` is optional
and advisory, `review` displays the local diff/checks, and automated `pr-review` / `review-stage` runs
against a shipped PR. Those entry points, accept/ship gates and send-back behaviour stay as they are.
Here **review execution** means the automated reviewer, not replacing the human's decision with an agent.

### Goal drafting is independent of coding

Choosing an agent to write code must not choose who writes the goal. For example, a user may prefer
Sol for turning a rough request into a precise goal, and Opus for implementation. That is a user/model
preference, not a hardcoded ranking: providers and models are configured separately for each job.
The drafting provider may also be the coding provider with a different model, or the same model.

Goal drafting is planned here, not currently implemented by `goal new` (which writes a template).
Workbench prepares the rough request, declared read-only repository context and goal-file schema;
the drafter returns a proposed title, request, criteria/proof and out-of-scope items. Orchestration
validates the proposal using `GoalFile`/`Goal` rules and presents it as a draft for the person to edit.
Workbench owns thread ids, base, coding provider/model, budgets and approval fields; generated text
cannot change them, mark itself approved or start execution. A suggested coding model is only prose
until the user explicitly selects it. The drafting model never becomes the goal's coding `model`.

Drafting uses the same provider abstraction and enforced read-only policy, its own bounded deadline,
output/spending limits and isolated context/session. It does not open a numbered coding turn, create
a coding worktree or automatically approve a goal. Record draft attempts and their terminal outcomes
in the thread's log, without enabling Run. Preserve manual drafting when no agent is configured.
Use the current judge defaults ($0.50 where enforceable, 300 s) for drafting, with an explicit
`agents.goal.allow_unpriced` opt-in when only the deadline can be enforced.
A failed or cancelled proposal leaves the existing goal untouched; applying a replacement is explicit,
returns any approved goal to draft and requires approval again. Provider/model provenance is retained
with the proposal, separate from coding settings and approval. No automatic goal-drafting retries.

## Starting point

| Area | Built today | Refactoring needed |
|---|---|---|
| Run | `Thread/ThreadRunner.swift` owns the worktree, setup, prompt, turn, check and verify; `Config/ClaudeInvocation.swift` builds Claude argv | Extract invocation, environment, Claude stream parsing and completion classification; retain orchestration |
| Session | `ThreadStore.session` stores a UUID and confirmation in `session.json`; `ThreadRunner` retries an unconfirmed resume without output as a fresh session | Provider-qualified opaque handles and an explicit no-session path; preserve the existing Claude recovery case |
| Judge | `Thread/Judge/ThreadService+Judge.swift` prepares evidence and runs Claude; `Judge.swift` builds its prompt and unwraps Claude JSON before validating criteria | Separate provider envelope decoding from `JudgeVerdict` validation and tool-specific instructions |
| Review | `Thread/PRReview/ReviewStage.swift`, `ReviewConfig.swift` define named stages, rubrics, proof and applicability; only Codex is allowed | Replace the fixed reviewer choice, extract Codex argv/answer-file decoding and capacity detection from `PRReview` and `ThreadService+PRReview` |
| Lifecycle | `ProcessRunner`, `Spawner`, `ChildExitWatcher`, `OrphanSweeper` provide bounded output, exit watching, termination and tree cleanup | Reuse them for every adapter; extend attempt recording and orphan recovery to all enabled responsibilities |
| State and presentation | `ThreadState`, `LogFormatter`, CLI JSON and notices read Claude stream shapes and a single session id | Consume normalized activity for new runs; keep legacy replay |

P6 tasks 1 and 2 are built; its loop-over-stages is not assumed complete here. The runner loads every declared input (the diff, the goal, `proof` images and up to 8 repository
files); what is still missing is the loop over stages.

## Boundaries

Keep three layers in `WorkbenchCore`, with the CLI and later app calling the same services:

1. **Stage orchestration:** existing `ThreadRunner` and `ThreadService` judge/review paths, plus a
   small optional goal-drafting service. They own
   approved goals, input preparation, prompts/rubrics, permission requirements, limits, worktrees,
   locking, retry policy, events and stage result validation. Checks, verify, shipping and approvals
   remain Workbench operations. A provider never accepts, pushes or starts a follow-up itself.
2. **Provider adapters:** a small built-in provider lookup, initially Claude Code and Codex. Each
   adapter owns its CLI argv, protocol/envelope decoding, model argument, auth environment mapping,
   permission-flag translation, session mechanics and transport error classification. It translates a
   Workbench request into an invocation, and provider output into provider-neutral activity and a final
   answer. It knows no criterion ids, review round rules or workflow transitions.
3. **Process lifecycle:** the existing `ProcessRunner` over `Spawner` and `ChildExitWatcher`. It owns
   pipes, deadlines, stop escalation, exit and descendant cleanup. No adapter adds another subprocess
   supervisor, blocking wait or long-lived stdin/control channel.

A finite lookup of built-in adapters is sufficient. No plugin loader, arbitrary shell-command provider,
workflow graph, queue or general-purpose workflow engine. One project, one active thread, no concurrent
agent calls. Adding Gemini CLI later should require an adapter, capability tests and config registration,
not branches inside goal/run/judge/review orchestration. Gemini is an extension target, not claimed built support.

### Provider abstraction

The following are responsibilities for Swift types, not a required final API spelling:

| Type | Contract |
|---|---|
| `AgentProvider` | Stable provider id, capabilities, validated invocation preparation and output decoder; no stage prompts or verdict parser |
| `AgentRequest` | Resolved provider/model, bounded prepared prompt and attachments, working directory, permission policy, deadline, output limits, optional budget and session intent |
| `AgentExecution` | Cancellable handle over `ProcessRun`; ordered activity and exactly one completion, or a recorded launch failure before a handle exists |
| `AgentActivity` | Text, tool activity, permission denial, usage, session update and diagnostic where available; unknown protocol events retain a bounded raw representation |
| `AgentCompletion` | Process outcome plus provider outcome, final answer/reference, optional session handle, optional usage/cost, truncation flags and structured failure information |
| `AgentFailure` | Kind, actionable bounded message, retry classification and diagnostic reference; kinds include missing executable, auth/config, unsupported capability, capacity, protocol, process, timeout, cancellation and interrupted |

Do not equate exit 0 with successful work or a valid evaluation. Preserve exit code/signal and lifecycle
facts separately from provider status; stage validation decides whether a usable stage result exists.
Unparseable or truncated required output fails explicitly, never as a clean review or met criterion.

Execution exposes streaming activity even when a provider only emits a final answer: report start and
completion, with no invented text/tool stream. Byte, line, answer-file, attachment and buffered-activity
limits apply at every boundary. Continue draining after output caps; never let a slow consumer hold a
child open or allow the new normalization layer to queue unbounded activity. Keep cancellation reachable
while awaiting output, files, retries or checkout preparation.

### Capabilities and permission policy

Capabilities describe actual adapter support: native resume (and caller-supplied versus returned ids),
text/tool streaming, image attachments, structured-output assistance, usage reporting, hard dollar cap,
and enforceable permission modes. They are not promises that every provider has the same CLI features.
Validate the resolved stage request before spawning or spending money; `doctor` explains incompatibilities.

- Orchestration chooses a policy such as scoped coding or read-only evidence/repository inspection. The
  adapter translates it to tested native controls; no new Workbench shell parser or permission engine.
- Judge and review must prohibit repository writes and posting, not merely ask politely. Judge gets its
  prepared evidence directory; review gets the existing throwaway checkout and declared evidence.
  Writable answer/transcript files belong in the thread's output area, outside the reviewed checkout.
  A throwaway checkout alone is not read-only enforcement. Refuse a provider/policy pair without verified
  native controls; do not weaken the policy or silently switch providers.
- Preserve coding worktree confinement, denied destructive/shipping tools, unattended execution and the
  host-owned credential boundary. Native controls differ: an adapter is compatible with `run` only after
  its confinement and tool policy pass the same negative tests as the existing Claude path.
- Orchestration supplies allowed environment policy; adapters select only the provider's required auth
  variables. Do not inherit the host environment wholesale or forward one provider's credentials to
  another. Logs redact credentials and prompts from argv as today.
- If screenshots are required, reject missing image capability. If structured output is unavailable,
  request the same answer as text and apply the same validator. No text substitute for visual evidence.
- Missing native resume uses a fresh process with bounded explicit context assembled by orchestration
  from the approved goal, feedback, current diff/checks and prior summary. Record that continuation mode
  and truncation. Never claim the provider remembers omitted context.
- Unknown cost is not zero. Existing `budget_usd` is a hard limit: refuse `run` on an adapter that cannot
  enforce it unless the user explicitly approves an execution policy without a dollar cap. Evaluations and goal drafting
  likewise require an explicit config opt-in to timeout-only spending when hard caps are unavailable.
  Neither timeout nor token reporting is described as an equivalent dollar cap.
  Compatibility exception: legacy Codex review keeps its existing timeout-only policy when no new
  agent selection is configured; display that limitation. New evaluation selections require the explicit
  opt-in when unpriced. This exception never removes the hard cap from legacy coding or judging.

Provider CLI flags and capability claims must be verified against supported installed versions in task 1.
This plan does not prescribe unverified Codex coding or Gemini invocation flags.

### Sessions and provider changes

A session handle is opaque and qualified by provider, purpose and compatible execution settings; it is
not universally a UUID. Coding sessions may persist across turns; drafting, judge and review stay independent,
one-shot evaluations with no access to the coding conversation. Same provider does not mean same session.

A run-provider change starts a fresh session with prepared continuation context. Never pass a Claude id
to Codex, resume an evaluator as the coder, or reuse a handle after incompatible model/permission changes.
Provider/model changes are resolved before an attempt, recorded and shown to the user. Changes to coding
provider, model or permission/spending policy invalidate the execution approval and require explicit
approval before the next coding turn. This extends the existing approved-goal hash check rather than
allowing config edits to bypass it. Bind approval to the resolved coding settings; do not hash secrets or
host-specific executable paths. Evaluation settings remain independent of coding approval.

Treat the event log as authoritative for confirmed session updates. Read old `session.json` as legacy
Claude metadata; if kept as a cache, it must be rebuildable and cannot override the log. A prepared but
unconfirmed handle may be recorded before spawn so crash recovery retains today's safe resume fallback.
No automatic replay of a possibly mutating coding attempt after output or uncertain execution.

## Configuration (proposed, not accepted by today's parser)

```toml
# Optional executable overrides; defaults are the provider CLI names on PATH.
[providers.claude]
executable = "claude"

[providers.codex]
executable = "codex"

[agents.goal]
provider = "codex"
model = "<installed Sol model id>"  # illustrative: use the actual provider model id
allow_unpriced = true

[agents.run]
provider = "claude"
model = "opus"

[agents.judge]
provider = "codex"
# model = "<installed provider model>"
allow_unpriced = true   # explicit timeout-only evaluation; cost remains unknown

[agents.review]
provider = "codex"
allow_unpriced = true

# Optional per-P6-stage override; other stages inherit agents.review.
[review.stage.design]
provider = "gemini"     # only once a compatible Gemini adapter is installed in Workbench
model = "<installed provider model>"
prompt = "docs/REVIEW-DESIGN.md"
inputs = ["diff", "goal", "proof"]
```

The example's Gemini override is illustrative, not runnable in the initial two-provider milestone.
`review.stages` still controls rubric order; it is not a list of providers. Every stage may choose the
same provider for drafting, run, judge and review. Independent review is a separate invocation and
context, not a forced different vendor. Cross-provider review remains a user choice.

Resolution rules:

- No new config preserves current defaults: Claude coding, Claude judge, Codex automated review.
  P7's proposed change to default judging on Codex does not take effect implicitly.
- Drafting: `agents.goal.provider` / `agents.goal.model`, then that provider's model default. With no
  goal-agent config, keep manual/template authoring. Drafting never inherits the goal's coding model
  or root `model`; `agents.goal.allow_unpriced` explicitly permits timeout-only spending when needed.
- Model precedence for coding: approved goal `model`, `agents.run.model`, legacy root `model`, provider
  default. Legacy root model applies only to legacy Claude selection; never send an alias such as
  `opus` to a different provider. An incompatible goal model must be changed and reapproved.
- Judge: explicit `judge --model`, `agents.judge.model`, legacy Claude root model only when no new judge
  selection is configured, provider default. Review: named-stage model, `agents.review.model`, provider
  default. Named review stages also inherit `allow_unpriced` from `agents.review` unless explicitly
  overridden; this flag is invalid for coding, whose spending policy requires goal approval.
  Provider selection follows the corresponding table, with named review overrides first.
- Legacy `claude_path`, tools, safe mode and `env_pass` keep their existing Claude meanings, never become
  generic argv. Legacy `[pr_review]` continues to configure the built-in stage. P6 `reviewer = "codex"`
  is a compatibility alias for that stage's provider; reject both keys together rather than guess.
- `[providers.<id>].executable` overrides only the validated executable path/name, resolved without a
  shell. Model names, stage names and all paths retain `SafeNames`/`Config` validation. Unknown providers, keys and invalid
  capability combinations fail clearly. Explicit choices never silently fall back to another provider.
- Existing timeouts and stage limits remain the defaults. Timeout-only coding needs a new explicit
  approval-bearing policy in the goal schema; until that lands, non-dollar-cap providers cannot run a
  goal requiring `budget_usd`. No fake unlimited budget or ignored goal field.

## Execution contracts

The adapters unwrap provider envelopes; orchestration preserves the existing execution contracts
and adds the draft-proposal contract:

| Responsibility | Valid result | Failure/iteration behaviour |
|---|---|---|
| Goal draft | A proposed draft that passes `GoalFile`/`Goal` validation; host-controlled metadata excluded from agent authority | Invalid/failed/cancelled proposals preserve the previous goal; applying a valid proposal still requires human approval |
| Run | `TurnReport` / `RunResult`: succeeded, failed, stopped, timed_out, budget_exceeded, interrupted; optional summary, usage and session | Preserve checks/verify sequencing, send-back rules and failure review; a success is execution completion, not proof the goal is met |
| Judge | `JudgeVerdict`: every known criterion exactly once, real boolean `met`, bounded evidence and concerns | Keep current advisory semantics, including concerns for insufficient evidence; invalid/missing output means no verdict, with a reason and evidence reference |
| Automated review | Existing bounded findings and exactly one final `VERDICT: CLEAN` or `VERDICT: FIX`, parsed identically for every provider | Missing/ambiguous verdict is failed evaluation; FIX findings feed the existing quoted follow-up request; skipped remains skipped, never clean |

Provider schema helpers are optional transport aids, not alternate validators. Separate process failure
from invalid answer and from a valid negative verdict. Failures report stage/provider/model, cause,
attempt and diagnostic path plus an actionable next step (install/authenticate, change incompatible
config, rerun, or inspect malformed output). Retain usable bounded partial findings as diagnostics, never
promote them to a validated verdict or automatically feed transport errors into coding instructions.

Retries stay orchestration policy. Adapters classify transient errors; they never sleep or retry
internally. Preserve review's three capacity attempts and per-stage round accounting; a transport retry
is not another review round. Backoff is async, cancellable and bounded by the attempt/overall deadline.
Preserve the coding unconfirmed-resume/no-output fallback. Do not add automatic coding retries for
crashes, ambiguous completion or partial writes. Judge remains once per successfully judged turn unless
`--again`; failed evaluation can be rerun as today. Every physical attempt, including a capacity retry,
gets its own terminal record without creating extra numbered coding turns.

## Events and recovery

Keep the single writer, sequence without gaps, current turn/stage events, worktree isolation and decisions.
Add provider/model/continuation metadata to existing start/end records, and bounded normalized activity
for presentation. Preserve legacy `claude` events verbatim and their replay; new raw provider records
must name the provider and retain original payload within documented limits. Do not emit both legacy
and normalized activity into a reducer that counts it twice. Unknown usage/denial counts stay unknown.

Add provider-attempt start/end records with stable ids, responsibility, optional named review stage,
turn/round (none for drafting), provider/model and outcome. Draft attempts are thread-level events
that complete without a coding `turn.started` or an approval event. Drafting adds paired
`goal.draft.started` / `goal.draft.finished` records with proposal reference/provenance or failure; no
approval transition is implied. The enclosing stage owns attempts under the same log lock. A missing
executable/preflight refusal is recorded as a failed evaluation or refusal without pretending a process
spawned; a launch failure after attempt start always closes the attempt. Stage terminal records still
follow their existing contracts, with evaluation interruption recovery added below.

Before any new work, recovery closes unfinished attempts and their enclosing draft/turn/judge/review exactly
once as interrupted, sweeps their descendants and cleans their temporary checkout. Today turn/check/
verify have synthetic recovery, while killed judge/review starts can remain visibly unfinished; P9 must
close that gap without resetting review caps or declaring a pass. Old skipped reviews have no start
and require no synthetic end. Repeated recovery is idempotent. A log write failure must stop and clean
up the child; report persistence failure rather than claim the terminal event was saved. On next open,
recover from the last durable start. No secondary authoritative workflow state.

Update `docs/spec/{event-log,goal-file,cli-json,exit-codes}.md` with the implementation slices that change
behaviour. Before retaining event version 1, prove additive compatibility with old fixtures/readers;
otherwise specify a version migration. Do not relabel old Claude sessions or rewrite historical logs.

## Dependencies and implementation order

P1/P2 process, worktree, approval and log invariants remain prerequisites. Build on P4's evidence and
judge, P5's read-only reviewer/retry loop, and P6's built stage definitions. P6's remaining multi-stage
loop work stays separate: integrate with it if present, but do not make a general workflow scheduler
part of P9. P8 is independent check-performance work, not a reason to change check semantics here.
P7 is replaced by this milestone; its extraction motivation and test cases are retained below.

One slice per PR. Tests and relevant spec updates travel with each slice; no production implementation
is part of this planning change.

| Task | Runnable result | Measurable gate |
|---|---|---|
| 1. Prove adapter capabilities (probed 2026-10-24, results in [P9-capabilities.md](P9-capabilities.md)) | Record supported Claude/Codex versions, invocation fixtures, coding confinement, read-only inspection, auth, images, sessions and spending controls | A capability matrix based on real probes, including attempted forbidden writes; unsupported pairs refused. Settle and specify explicit no-dollar-cap approval before enabling a provider without it |
| 2. Extract current adapters | Claude run/judge and Codex review use the common request/execution boundary over `ProcessRunner` | Existing focused suites pass unchanged in meaning; legacy streams, verdicts, retry count, stop and worktree cleanup match fixtures; no CLI flags in stage orchestration |
| 3. Config, activity and recovery | Independent selections, qualified sessions, normalized events, attempt lifecycle, doctor/CLI output and legacy migration | Old config/log fixtures replay; approval invalidation and provider switch tested; interrupted judge/review and all physical attempts close exactly once; no unsupported setting ignored |
| 4. Enable the second provider per stage | Codex coding/judge, Claude automated review, and optional goal drafting through either provider, subject to task 1 compatibility and explicit spending policy | Each of goal drafting/run/judge/review works with both Claude and Codex, same validators and read-only/isolated policies; provider choice changes config only |
| 5. Exercise the complete loop | Mixed-provider and same-provider demonstrations, failure injection and extended soak | All acceptance criteria below demonstrated; record versions, configs, results and friction before P3 starts |

If a proposed provider cannot meet a stage's boundary in task 1, do not declare task 4 complete: choose
another compatible provider or resolve the missing native support. Gemini may supply that second provider
with the same contract tests, but implementing a third adapter is not required for this milestone.

### Reliability matrix

Run the common lifecycle tests against each adapter using fake executables, not paid agents. Keep
existing `fake-claude` cases and extend the scripted fake-Codex fixtures; a new provider needs the same
suite. Relevant existing suites include `RunnerTests`, `ProcessRunnerTests`, `JudgeTests`, `PRReviewTests`,
`PRReviewCodexTests`, `ReviewStageTests`, `ReviewLoopTests`, `EventLogTests`, `ConfigTests` and `SoakTests`.

For both providers and every enabled responsibility, cover:

- Missing executable, spawn failure, nonzero exit, auth failure, malformed/empty final response, protocol
  noise, oversized line, output/answer cap, slow activity consumer and missing required final output.
- Stop before spawn, during stream, after process exit and during retry backoff; timeout, ignored
  SIGTERM, descendants changing process groups, inherited pipes left open, crash and lost child status.
- Kill the Workbench holder between attempt start/end and between attempt end/stage end; reopen twice:
  one terminal per start, no dangling holder/child/checkout, unchanged caps and contiguous sequence.
- Capacity then success and exhausted retries; no retry of a partially executed coding turn; unconfirmed
  Claude resume fallback, unsupported native sessions, incompatible handles and switching providers.
- Identical valid/invalid judge and review answers through both envelopes, required-image refusal,
  attempts to write tracked/untracked/ignored repository files and to post/push, no credential crossover.
- Draft proposal validation, malformed criteria, attempted approval/metadata injection, stop/failure
  preserving the previous goal, explicit replacement invalidating approval, and drafting-model independence.
- Same provider at all stages with distinct sessions; mixed providers, negative verdict then follow-up,
  explicit rerun after evaluation failure, approval/config changes, old configs and historical replay.

Keep CI's existing reliability and soak gates intact. Extend the 100-fake-run soak to exercise both
adapters and mixed-stage recovery, retaining zero hangs, leftover processes and leaked descriptors.
Before marking complete, record 10 explicitly authorized real end-to-end tasks spanning both coding
providers, both evaluators and at least one mixed-provider and one same-provider setup. Real probes
cost money and are run by hand; ordinary tests remain fake-based. Do not run the full check or soak
locally as part of each PR: follow `AGENTS.md`'s changed-file checks; CI owns the full suite/soak.

## Acceptance criteria (gate for P3)

- [ ] Run, judge and automated review each execute with at least two compatible providers.
- [ ] Optional goal drafting works through two providers independently of coding provider/model, validates
      proposed goals, preserves manual authoring and cannot bypass explicit approval.
- [ ] Config alone selects provider and model independently, including named review overrides and the
      same provider for several responsibilities; changing providers never edits orchestration code.
- [ ] A mixed-provider workflow completes approval, coding, judging, automated review and the existing
      accept/ship/follow-up decisions without changing their order or human authority.
- [ ] Shared stage validators produce the same outcomes for equivalent answers from every provider;
      failed evaluations expose actionable feedback, never a fabricated verdict.
- [ ] Read-only judge/review and coding confinement pass negative tests for both providers.
- [ ] Cancellation, deadlines, failures and retries pass the reliability matrix; every started subprocess
      attempt and enclosing stage has one durable terminal record or is recovered as interrupted.
- [ ] Interruption recovery is idempotent and preserves the single writer, sequential state machine,
      approval, review caps, worktree isolation and retry rules.
- [ ] Current Claude coding/judge and Codex review config, event replay and CLI results remain compatible.
- [ ] Existing reliability tests and extended CI soak pass; real pilot results and friction are recorded.
- [ ] Specs and P3's normalized activity/config expectations match the shipped implementation.

## Open questions to resolve in task 1

- Which supported CLI versions provide the native coding and read-only boundaries required by the
  capability matrix? Pin minimums and probe again when invocation flags change.
- What exact goal-file representation expresses explicitly approved timeout-only coding for providers
  without a hard dollar cap? It must preserve hashes for existing goals and clearly display lost cost
  enforcement. Until specified and implemented, refuse that pairing.
- Can the additive event design remain version 1 for supported historical readers? Decide from fixture
  tests before task 3 writes new events; document any migration before implementation.

## Demo

Draft a goal through Codex with the user's chosen Sol model; edit and explicitly approve it.
Select Claude with Opus for run and Codex for judge/review; complete a task, including one negative verdict and
follow-up. Change config to Codex for run and Claude for judge/review with the necessary explicit
spending approval, and repeat. Use the same provider for drafting and all three execution responsibilities with isolated sessions. Stop a hung
fake, kill the holder mid-evaluation, relaunch and rerun: show complete terminal records, cleanup and
unchanged review caps. The SwiftUI app then consumes these contracts without provider-specific code.
