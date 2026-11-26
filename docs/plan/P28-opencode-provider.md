# P28: OpenCode provider

**Outcome:** every role of a project (goal, plan, run, judge, review, ship, verifier) can run on OpenCode, through a LiteLLM gateway
the user owns, with the same guarantees as Claude and Codex today: a coding turn edits only its worktree, a read-only call cannot
write, a turn always ends and says how, and cost is recorded. A project switches by editing `[agents.<role>]`; nothing else changes.

**Why now:** the company is moving its engineers to OpenCode (about a month from 2026-11-25). Workbench today knows two providers,
`claude` and `codex`, and `codex` is wired in about 30 files as a special case, not as a provider.

**Status:** task 1 (the spike) done, results in [`P28-capabilities.md`](P28-capabilities.md): OpenCode's rules confine a read-only turn
(no shell) but not a coding turn (the shell is unconfined), so read-only roles come first; task 1b showed `sandbox-exec` around the whole process does confine a coding turn, with a loopback
forwarder for the model (seatbelt cannot allow a host). The temp directory and the Swift toolchain are settled (finding 4).

## What exists, and what this adds

Already there and reused as it is:

- `AgentProvider` (`AgentProvider.swift`): `invocation(for:)`, a decoder, and `AgentCapabilities`. A combination a provider cannot
  honour is refused before any process or spend (`AgentRequest.validate`), never weakened.
- `CodexProvider` and `CodexCodingDecoder` are the closest template: JSONL on stdout, a session id, a clear "turn completed" event,
  an allow-list for the child's environment, and a request that states its policy on the command line and ignores the user's config.
- `Spawner`, the kill-tree sweep, bounded lines and output, one `turn.ended` per `turn.started`: all in the process layer, which an
  adapter never touches.
- The fake claude (`Sources/fake-claude`) for hangs, crashes, ignored SIGTERM and leftover children.

New: an `opencode` provider id, its adapter and decoder, a per-run config Workbench writes, and the removal of the places where a
role knows it is talking to Codex.

## What was found (2026-11-25, OpenCode v2.4.0 on the author's machine)

- `opencode run --format json --auto --archived "<prompt>"` prints JSONL. A text-only run gave `step_start`, `text`, `step_finish`;
  every line carries `sessionID`. `step_finish` has `cost` (dollars) and `tokens` (`input`, `output`, `reasoning`, `cache.read/write`).
  Tool parts, errors and a capacity or auth failure were **not** observed yet (task 1).
- Flags that matter: `--model provider/model#variant`, `--session <id>` (create or continue), `--agent`, `--file` (images),
  `--auto` ("approve permissions that are not explicitly denied"), `--standalone` (a private server, so no background service shared
  with the user's own OpenCode), `--archived`, `--title`. There is no sandbox flag.
- The gateway is a provider in `~/.config/opencode/opencode.json`: `gateway`, `@ai-sdk/openai-compatible`, base URL the user's LiteLLM
  proxy, key from `{env:LITELLM_API_KEY}`, models `sonnet-claude`, `opus-claude`, `fable-claude`, `haiku-claude` and others (GPT,
  Gemini, Grok, Qwen, DeepSeek, Kimi, GLM). Model names are `gateway/<name>`. One provider can therefore serve every role, including
  the roles that are Codex-only today.
- That file is the user's. A run that depends on it behaves differently on every machine (the company's will differ), so a run gets a
  config of its own (task 2).

## Capabilities to state (provisional until task 1)

| Capability | OpenCode (hoped) | Decided by |
|---|---|---|
| Read-only, cannot write | permission rules deny `edit`, `bash` writes, `webfetch` | task 1 |
| Read-only, cannot read outside the checkout | probably **no** (`confinesReads: false`, as Codex) | task 1 |
| Coding confined to the worktree, no `git push`, no network | deny rules plus a worktree-only external-directory rule | task 1 |
| Hard dollar cap | the gateway key's `max_budget` (LiteLLM), or the runner stopping a turn when summed `cost` passes the cap | task 1 and 3 |
| Usage | tokens and cost from `step_finish` | built in task 3 |
| Resume | `--session <id>`; the id comes from the stream, as with Codex | task 3 |
| Images | `--file` | task 1 |
| Structured answer | none; the final `text` part is the answer | task 3 |

A capability task 1 cannot show is written `false`, and a request needing it is refused with the sentence that says what to change.
It is never granted on hope (P9 found `git push` going through `-s read-only` on Codex because the user's own config approved it).

## Tasks

One PR each, in this order. Task 1 is docs and a script, no product code.

1. **Spike: what the sandbox really stops. Done 2026-11-25.** A script in `docs/archive`-style `P28-probes/` drives real OpenCode turns on a throwaway
   repo, the way P9's `probe.py` does, and reads the result from the filesystem and the remote, not from what the model said.
   With a Workbench-written config (provider, one model, permission rules) it tried: write a tracked, an untracked and an ignored
   file; write outside the repo (under `$HOME`, not `$TMPDIR`); `git commit`; `git push` to a bare remote; `curl`; read a file
   outside the repo; run a tool that needs a temp dir. It also records the event shapes for a tool call, an error from the gateway
   (bad key, over budget, unknown model, 429) and a killed process, and whether `--auto` can be left out without hanging on a prompt.
   It runs once with the user's own `~/.config/opencode` present and once ignoring it, to see whether the user's config can defeat the
   deny rules. **Output:** [`P28-capabilities.md`](P28-capabilities.md), a matrix like P9's, and the decision below.
   - *If coding cannot be confined:* OpenCode is read-only roles only (judge, review, plan, goal, verifier) and `run` refuses it with
     a message, until the confinement is solved (a macOS `sandbox-exec` wrapper is the candidate, with its own task).
   - *If it can:* continue as written.
1b. **Sandbox a coding turn. Done 2026-11-25** (Swift toolchain; other ecosystems get their lists as they come). Probe `sandbox-exec` (a profile that allows writes only to the worktree and a per-thread scratch
   directory, denies network and writes under `.git`) around the whole `opencode` process, with the same attacks as task 1, plus the
   toolchain a real check needs (SwiftPM, node, a temp dir, `$HOME` caches, the gateway's HTTPS: network is needed for the model, so the
   profile allows only the gateway's host or a local proxy). Output: a section in `P28-capabilities.md`; if it holds, the profile
   becomes part of task 2's config. If it does not, coding on OpenCode is out of scope and the plan says so.
2. **The run config. Built** (`OpencodeConfig`, `OpencodeRunLayout`, and the `sandbox-exec` profile `OpencodeSandbox`; not wired to anything yet). `OpencodeConfig` writes, per run, a JSON file in the turn's output directory and passes it as
   `OPENCODE_CONFIG` (plus whatever task 1 shows is needed to ignore the user's config and the background service): the gateway
   provider with its base URL from the project's `[providers.opencode]` table, the key as `{env:LITELLM_API_KEY}` (never written to
   disk), one model, and the permission rules for the request's policy. Pure function, tested for what it writes per policy, with the
   path and the model name validated before they reach it (`SafeNames`).
2b. **The loopback forwarder. Built** (`LoopbackForwarder`, `ForwardPolicy`; not started by anything yet). The sandbox can only reach loopback
   (seatbelt cannot allow a host), so a coding turn's model traffic goes through a local HTTP server that Workbench runs for the turn.
   It binds `127.0.0.1` on an ephemeral port and forwards only to the one configured upstream, whose scheme, host and port never come from
   a request: `GET` and `POST` on paths under the base path (`/v1/…`), no dot segments, no encoded dot or slash, no absolute-form target.
   It adds the key and drops the client's `Authorization`, cookies and everything else not on a short allow-list, so the child gets a
   placeholder and a shell printing `env` shows `forwarder`. It streams a successful answer as it arrives (the model's tokens are server-sent
   events), buffers an error answer (bounded) and removes the key from it, and never follows a redirect (that would send the key to a host
   nobody configured). One request per connection, a cap on live connections, read, write and idle timeouts, bounded head, body and error
   sizes, and a client that leaves ends the upstream request. `stop()` ends everything, never waits, and is safe to call twice.
   Proved on the real binary and gateway: a sandboxed coding turn through it wrote its worktree, could not write outside, had no network
   and no commit, and printed the placeholder for the key. A coding turn can run only once task 5's `run` wiring starts and stops it.
3. **The adapter and the decoder. Built** (`OpencodeProvider`, `OpencodeDecoder`; not selectable by a role until task 5). `AgentProviderID.opencode`, `OpencodeProvider` (argv, environment allow-list of `PATH`, `HOME`,
   `USER`, `LOGNAME`, `SHELL`, `LANG`, `LC_*`, `TERM` (the set Codex gets), `TMPDIR`, `LITELLM_API_KEY`, and nothing of the project's `env_pass` or another provider's key) and
   `OpencodeDecoder`. The decoder maps `text`, tool parts and `step_finish` to `AgentActivity`, `AgentUsage` and the session handle;
   it counts a turn as a success only when a final `step_finish` with reason `stop` was seen and the process ended on its own with
   status 0 (the Codex rule); a gateway failure (auth, budget, capacity) becomes an `AgentFailure` with the right `retry`. Oversized
   lines, an unknown event type and a stream that stops short are tested the way `CodexCodingDecoder`'s are.
4. **The fake. Done, as a script.** The adapter passes the child only an allow-list of the environment, so `FAKE_CLAUDE` would not reach an
   OpenCode-shaped `fake-claude`; the fake is a shell script the tests write (`RunOpencodeTests`), run for real under `sandbox-exec` behind
   the forwarder. Covered: crash, a gateway error event, a hang ended by the timeout, SIGTERM ignored, a child left in its own process group
   by a turn that succeeded, a SIGKILLed runner (the next run closes the turn and sweeps), `stop` from another process and before the
   process starts, and an opt-in soak (`WORKBENCH_SOAK=1 swift test --filter OpencodeSoakTests`: one `turn.ended` each, nothing listening,
   descriptors flat). All of it is macOS only, as a coding turn on OpenCode is: the Linux gate and its soak do not run it.
5. **Roles stop knowing Codex. Started:** `[providers.opencode]` (`base_url`, `api_key_env`), the registries, doctor, and `plan` and `ship`
   run on it through `OpencodeReadOnlyAgent`, and **`run`** (the coding role) runs under `sandbox-exec` behind the forwarder, started and
   stopped around each turn (a role not yet proven is refused when the config loads); judge, review, goal drafting, the chat and the
   verifier follow in their own PRs. **`judge`** runs on it too (read-only, an empty folder, behind a forwarder like every OpenCode turn; a
   judge with screenshots is refused by name: OpenCode takes no images), and so does **`pr-review`** (read-only in the round's folder, the
   answer is its last message; a `proof` stage is refused by name). **Goal drafting, the chat and the task editor** run on it too (the same read-only turn; no screenshots). Left: the verifier. **The app** offers OpenCode in the Agents card and the new-thread screen where the config names a gateway,
   and a role switched to or from it (there or with `config set`) gets a model and effort the new provider takes.
   Original text: **Roles stop knowing Codex.** `supportedProviders`, `knownProviders`, `defaultProvider` in `AgentsConfig.swift`, `ModelCatalog`,
   `AgentSetup`, `DoctorAgents`, `VerifierConfig`, `ReviewConfig` and the app's agent picker take the provider list from one place.
   `ThreadRunnerCodex.swift` and `ThreadService+PRReviewCodex.swift` become provider-generic code that asks `capabilities`, or are
   split into what is shared and what is the adapter's. A role set to `opencode` works in the goal screen, `plan`, `run`, the judge,
   `pr-review`, `ship` and the verifier. `doctor` checks that `opencode` is on `PATH`, that `LITELLM_API_KEY` is set, and that the
   chosen model is in `opencode models`.
6. **Cost and the budget.** Usage from `step_finish.cost` is recorded on `turn.ended` like Claude's. A goal's `budget_usd` is
   enforced by the way task 1 chose (the gateway's key budget, or the runner stopping the turn). Until then `hardDollarCap` stays
   `false` and a goal with a budget is refused for OpenCode with the sentence Codex's refusal has.
7. **Prove it for real.** `scripts/verify-cli/opencode.sh`: one real turn per role through the gateway, then sabotaged (a deny rule
   removed, the key unset, a model that does not exist), the steps its header names must FAIL. Run by hand once normally and once
   sabotaged; both results go in the PR. Docs: `docs/ARCHITECTURE.md` and `docs/spec/` change in the same PR as the behaviour.

Tasks 5 and 6 can run in parallel after task 3.

## Acceptance

- [ ] With `[agents.*] provider = "opencode", model = "gateway/sonnet-claude"` on every role, a goal goes from draft to an open PR
      with check, judge and `pr-review`, on a real repo, and the log shows one `turn.ended` per `turn.started`.
- [ ] A coding turn cannot change a file outside its worktree, cannot `git push`, and cannot reach the network; the probes in
      `P28-capabilities.md` show it, and a regression test fails if the generated config drops a rule.
- [ ] A read-only call cannot write, and what it can still read outside the checkout is stated in `capabilities`.
- [ ] The user's own OpenCode config (a different provider, a permissive permission block) changes nothing a run does.
- [ ] No credential appears in the event log, a transcript, `displayArguments` or the config file on disk.
- [ ] Cost is recorded for every turn, and a goal's budget is enforced or refused, never ignored.
- [ ] Hangs, crashes, SIGTERM that is ignored and leftover children are tested with the fake and leave nothing behind.
- [ ] Codex and Claude behave as before: their existing tests pass unchanged.

## Out of scope

- OpenCode's own TUI, agents, plugins or MCP servers inside a Workbench run (a run uses one built-in agent and no plugins).
- Running OpenCode against any gateway other than a configured OpenAI-compatible one; `[providers.opencode]` names one base URL.
- Removing Claude or Codex. Switching a project back is editing the same table.
- Resuming a conversation across turns for coding (each turn starts fresh with prepared context, as Codex does today); task 3 stores
  the session id, and using it is a later change once task 1 shows resume is safe.

## Open questions

- Does the company run OpenCode against its own gateway, so that "the user's tokens" and "the company's tokens" are two different
  `[providers.opencode]` tables? If so, the table needs a named profile.
- Is the background service (`--server`, no `--standalone`) acceptable in a run? It shares state between runs; the default here is
  `--standalone` unless task 1 shows a reason not to.
- Which model is the default per role? Suggested: `sonnet-claude` for run, judge and review, `opus-claude` for plan and goal, decided
  by a run of the verify scenario, not by this file.
