# Goal file

A goal is one markdown file per thread: `goal.md`. It is written by you (or drafted by Claude and edited
by you), then **approved**. Nothing runs before approval, and a change after approval returns it to draft.

## Shape

```markdown
---
id: g-2026-10-12-retry-backoff
title: Add retry with backoff to the sync client
status: approved            # draft | approved
base: main                  # branch the worktree is cut from
budget_usd: 5.00            # hard cap passed to the CLI (or `spend_policy: timeout_only` instead, below)
turn_timeout_min: 30        # runner kills the turn after this
model: opus                 # optional; --model for every turn of this thread
push_to: feature/x          # optional; continue this branch of origin (base must be origin/feature/x)
approved_at: 2026-10-12T20:10:00Z
approved_hash: 3f2a...      # hash of everything below the front matter
---

## Request

Add exponential retry with jitter to `SyncClient.fetch`, max 5 attempts.

## Criteria

- [c1] `SyncClient.fetch` retries on 5xx and network errors, not on 4xx.
  - proof: test: SyncClientTests/retries
- [c2] Delay grows exponentially with jitter and is capped at 30s.
  - proof: unit test with injected clock
- [c3] The settings screen shows no change.
  - proof: screenshot of Settings

## Out of scope

- Changing the request timeout.
- Retrying uploads.
```

## Rules

- **Criteria are checkable.** Each has an id (`c1`…) and a `proof` line saying how it will be shown.
  `proof` is free text for now; typed proofs (`check:`, `screenshot:`, `diff:`) are described in
  [`later/proof.md`](../later/proof.md).
- **A test proof is `proof: test: <Suite>/<name>[, …]`.** It is decided by the tests the latest turn's check saw
  finish (`check.ran` `tests_passed` and `tests_failed`, read from the `swift test` output as it streamed). A
  name matches a test that equals it or starts with it, so `retries` covers a family; the suite part is not
  compared, because the output does not carry it. `✔ passed` when every name matches a test and every match
  passed (note "named test ran in the check, turn N"); `✘ failed` when any match failed; `you check` when a name
  matches nothing, the check ran after an earlier turn, did not finish, listed no tests (a format the parser
  does not know) or had its list cut at 2000 names. A proof written as prose is read the same way only when
  every word is a recorded test name or filler such as "passes"; anything else in it keeps it `you check`.
- **A screenshot proof is `proof: screenshot: <name>[, <name>…]`.** Each `<name>` is one token of letters, digits,
  `.`, `_` and `-` (at most 64, not starting with a symbol), up to 16 names, a name listed twice counting once; a
  malformed list is a goal error. It is satisfied when the latest turn's proof has `<name>.png` at the top of the
  proof directory for every name. The turn's proof is what the verifier (`[verifier]`, below) left in it, recorded and still there as recorded (and,
  in a log written before `verify_command` was removed, what its verify step left; when both left a file of the same
  name the verifier's is the one used, and both stay in the log). `review` shows `see screenshot` and the files in the
  order named, or `✘ missing` with the reason and the files that are there: no verifier run, a proof
  from an earlier turn, a name with no file, or a recorded file that is gone, unreadable, a link or a different size
  than recorded. One of three missing is `✘ missing`. A screenshot is never `passed`: a person looks at it, and what
  the verifier said about it is a note. `approve` and `run` refuse such a proof when the project has no `[verifier]`
  whose skill is in the base commit (`--allow-unrunnable-proofs` overrides), because nothing could produce it.
- **`ship` puts the screenshots in the pull request.** After the PR exists, the top-level `*.png` files of the
  latest verify step (recorded, and still there as recorded) are copied into a fresh folder that is the
  tool's whole screenshot folder (`PR_SHOTS_DIR`, so no older screenshot is uploaded), under the names
  `pr-shots path <name>` gives, and `pr-shots pr <number>` writes the `## Screenshots` section. `pr-shots`
  runs in the thread's worktree on Workbench's own environment (plus the person's `gh` login and
  `PR_SHOTS_*`/`AWS_*`/`CLOUDFLARE_*` settings), never the model's, with `GH_REPO` dropped. Because the model
  can write in the worktree, a `.pr-shots.json` there that differs from the project checkout's stops the
  upload with a note. A proof belongs to the work it was taken at: when the tree the verify step recorded is not the
  tree of what was committed (the work changed after verify), nothing is uploaded and the note says so; a log with
  no tree recorded is "unknown" and uploads as before. `review` prints the same verdict (`current`, `stale`,
  `unknown`) under the proof files, and `--json` has it as `verify.proof_freshness`. It is a note, not an error, when the tool is missing or fails: the PR is open, the
  worktree is kept and `workbench ship --screenshots` tries again. `--no-screenshots` skips it. At most 20 files.
- **`workbench plan` writes the approach before any edit.** A separate, read-only `claude` run is given the approved
  goal (request, criteria, out of scope), the project's instructions as they were at the base commit, and a
  throwaway detached checkout of the base commit as its working directory (`--restricted` makes that the only place
  it can read; it is removed on every ending). Its tools are `Read`, `Grep` and `Glob`: no `Bash`, `Edit` or `Write`,
  and no `--permission-mode`. It answers in Markdown (approach, files, order, risks). The text is trimmed, stripped
  of machine paths and credentials, cut at 16 KB with a marker, and kept as `plans/plan-N.md` in the thread's folder.
  It needs an approved goal (a draft or a changed one is refused before anything is spent), runs once per approved
  goal unless `--again`, has its own budget (default $1.00) and timeout (10 minutes), and opens no numbered turn.
  The next `run` puts the thread's newest plan in the **first** prompt, after the out-of-scope list, as advice:
  written by another model, the criteria and the out-of-scope list win where they disagree, and a deviation is to
  be said in the summary. A plan made for another version of the goal, or whose file is missing or no longer what
  the log recorded, is left out and `run` says why; `run --no-plan` leaves it out on purpose; follow-up turns
  resume the session and carry no plan. `plan show` prints the newest plan; `plan edit` copies it to
  `plans/draft.md`, and `plan edit --apply` (or `--from <file>`) records the edited text as the newest plan
  (`plan.edited`); a file over 64 KB is refused, not read. No editor is started: every child Workbench runs has no terminal, so you edit the file yourself.
- **`workbench judge` is an advisory second opinion.** A separate, read-only `claude` run is given the goal, the
  work against the base (the worktree as `review` shows it, from the commit it was cut from, committed or not, cut at 120 KB,
  with untracked files named), the check (with the end of its output when it did not
  pass), what the verify step left and, with screenshots, `Read` on them in the folder they are in
  (`--restricted` makes that the only place it can read); with none it has no tools. It answers with one
  JSON object: per criterion `{id, met, evidence}`, and `concerns`. The answer is accepted only if it names
  every criterion once and no other, with real JSON booleans and both lists present; anything else is recorded
  as a failed run. It is told to mark a
  criterion not met only for an evidenced violation of its literal text and to put doubt in `concerns`. Each
  screenshot is listed with its pixel size, so a clipped capture is named as a concern. When the verdict is for
  the latest turn, `ship` writes its `concerns` (at most 5 of 300 characters, the rest counted) into the PR
  description under the criteria table as `Judge concerns`; they never gate. It runs
  once per turn unless `--again`, has its own budget (default $0.50, `--budget`) and a 5 minute limit, and
  `--model` picks a cheaper model for it. The thread's log is held while it runs, so a second judge or a run
  is refused as busy instead of spending on the same turn, and Ctrl-C stops it and records why. `review` shows it as a `Judge` block beside the criteria and the
  check, and says where it disagrees with one of them (it does not resolve it). It never changes what
  `accept` or `ship` do, and a thread that has no verdict is as reviewable as before.
- **`workbench pr-review` is Codex reviewing the shipped pull request.** Workbench starts `codex exec -s read-only`
  itself (`codex` on PATH; no script to keep per project) on a throwaway checkout of the pull request's head, under
  the thread's `pr-review/` folder, removed on every ending. It reviews the branch as `origin` has it,
  fetched at the start of the round: that is the pull request's head the moment a push lands, whereas GitHub's own
  `pull/<n>/head` and API lag behind a push, so they are not read and nothing waits for them. Codex is given a brief in a file (the argument only points at it): the thread's
  goal with its numbered criteria, `AGENTS.md` (else `CLAUDE.md`) at the base unless `project_instructions = false`,
  the optional `[pr_review] checklist` read from the pull request's head, the diff as a file (cut at 400 KiB;
  never `gh pr diff`) and the rule that the answer ends in exactly `VERDICT: CLEAN` or `VERDICT: FIX`. The base is
  fetched from origin for the round (so a stale `origin/<base>` cannot change the diff or the instructions) and
  pinned as one commit, which the brief also gives as the `git diff <base>...<head>` to re-read any part. A goal or
  checklist over 32 KiB is cut with a line in the brief saying where the rest is, never quietly. Workbench
  parses the verdict line itself: a missing, repeated or ambiguous one, or an answer over 256 KiB (whose last line
  cannot be trusted), is a failed round, never clean. It runs in
  Codex's own minimal environment (its login and `CODEX_*`/`OPENAI_*`, not the project's `env_pass`), for at most 20 minutes, and
  retries three times when the model is at capacity. Ctrl-C ends the whole round, also while it waits for GitHub or
  sits out a retry. A round that was killed leaves its `codex` and checkout behind; the next `pr-review` ends them
  first, before any refusal, and every round ends anything `codex` left running in its own session before the
  checkout is removed. The round is on record before it starts and ends in exactly one `pr_review.finished`; `max_rounds` (default 3) counts the `pr_review.started` events of this pull request, so
  only the log can reset it and `--again` (re-review a branch that has not moved) never lifts it. The findings are
  stored in the thread's folder and printed; `review` shows the round and says when the branch has moved since. The
  review needs only the pull request, not the thread's worktree, so it works after `ship` removed it. Nothing is posted
  to the pull request and nothing changes what `accept` or `ship` do.
- **`workbench pr-review --pr <n> [--spec <file>]` is the same review for a pull request no thread made.** A pull
  request written by hand has no goal file and no event log, so: `gh pr view` gives its branch, base, title and
  description (open pull requests from this repository only; a fork, a closed one or a branch name that is not safe
  for git is refused), and the title and description, or the `--spec` file (text, at most 64 KiB), are the goal in
  the brief. The round is the thread's own (`runRound`): the checkout of the branch as origin has it, the base
  pinned, the diff in a file, read-only Codex, a verdict line or a failure. Nothing is written to a log and no round is
  counted, so there is no cap; the findings, the brief and the transcript are kept under
  `.workbench/reviews/pr-<n>-<sha7>/`, and a branch that has not moved there is refused unless `--again`. One such
  review at a time per project (a lock the kernel drops with the process, so the next is `busy` and never stale); it
  first ends what a killed one left, for any pull request. `gh` is told origin's repository (`--repo`) when origin is
  a GitHub URL, and `GH_REPO` is dropped from its environment. Exit codes are the thread review's.
- **`workbench ship --review-loop` turns each round of findings into a follow-up thread.** After the pull request is
  open (or on a thread that already shipped: it starts at the review) it runs `pr-review`. On `VERDICT: FIX`, and
  while `max_rounds` allows another review, it makes a new thread on the same branch (`goal new --update`, named
  `<root name>-review-<n>`), writes its goal itself and approves it: the request holds the findings, quoted line by line
  (so a heading, `---`, a criterion line or a fence in them cannot change the goal), cut at 16 KiB; the criteria are
  "each finding is fixed, or the final message says why it does not apply" and, when `check_command` is set, that the check
  passes. The shipped thread is not touched and stays `accepted`; the follow-up records its `parent`, `root` and `round`
  on `thread.created`, so a UI can show it under the thread it follows. The follow-up runs like any thread. If its check fails the
  loop stops (13); if it changed nothing it stops (15) and pushes nothing. Otherwise the diff is shown and you are
  asked before the push (`--yes` skips the question; with no terminal and no `--yes` nothing is started); it is
  then accepted (only what was shown: a change made while the question waited is refused) and shipped like any update of a pull request, and the new tip is reviewed. Started again, the loop reuses an earlier review's answer only for the commit that review looked at: a branch that moved after the last allowed review is refused (6), and a last review without a verdict is exit 1 again. The ceiling is known up
  front and printed: at most `max_rounds - 1` follow-ups of up to the default budget each. It never merges.
- **Review says who verifies each criterion.** The checklist (`workbench review`, the PR description) is
  unchanged: criteria with their proofs, for a person to tick. Beside it, a table gives each criterion a
  status and a summary line (`Criteria: 1 passed · 0 failed · 4 for you to check`). Workbench runs one
  command itself, the project's check, so only a criterion whose proof is exactly the command the latest
  `check.ran` recorded (not the config as it is now)
  (backticked, with at most words like "exits 0" or "passes") shows `✔ passed` or `✘ failed`, from the
  check recorded after the latest turn. Every other proof is `you check`, with its backticked commands
  listed. A `test:` proof (below) is the other way to a verdict. Nothing is ever passed on Claude's say-so, `review` runs nothing, and none of this gates
  `accept` or `ship`. The PR table carries pass or fail only, never check output.
- **Approval binds a hash.** `approved_hash` covers the body (request, criteria, out of scope) and the front
  matter fields that change what runs (`base`, `budget_usd` or `spend_policy`, `turn_timeout_min`). Edit any of them
  and the status is `draft` again.
- **Out of scope is part of the contract.** The runner puts it in the prompt and the review shows it.
- **`workbench goal new <name>` writes the draft.** Its `base` is `--base` when given, else the repo's default
  branch: the branch `origin/HEAD` points to, else a local `main`, else a local `master`, else the checked-out
  branch, else `main` (an unborn repo). It is not simply the checked-out branch, which may be a feature branch.
  `goal new` prints it as `base: <branch>`; `doctor` without `--base` uses the same default.
- **`workbench goal draft <name> (--request "<text>" | --request-file <path>) [--base <branch>]` has the goal agent write
  the draft** (P9 PR 14). It needs `[agents.goal]` naming a provider (`goal new` stays the only way without one: the
  command is refused, exit 6, and says so). The agent is read-only, asked once, bounded at 300 s and, on Claude, at $0.50;
  Codex has no dollar cap and is refused before it starts unless `[agents.goal] allow_unpriced = true`, the message naming
  that key. It is given the rough request (quoted, at most 16 KiB), the project's instructions file at the base and up to
  400 tracked paths, and the goal-file shape. It may return only `title`, `request`, `criteria` (`text` and `proof`) and
  `out_of_scope`; an answer that sets anything else (`id`, `base`, `model`, `budget_usd`, `spend_policy`,
  `turn_timeout_min`, `push_to`, `status`, `approved…`) is refused, not trimmed. Workbench numbers the criteria `c1`…, and
  the answer must read back through `GoalFile.parse` as the same words (no criterion without a proof, no heading or
  `TODO(workbench)` in the text, no code fence). The goal is written through `goal new`'s creation path: `status: draft`,
  `base` from `--base` or the default, the config's default budget, 30 minutes, no `model`. The drafting model is never the
  goal's coding `model`. A draft that is not a valid goal (failed, timed out, stopped, malformed) creates no thread and no
  file, prints `no draft (cost): reason. Nothing was written.` and exits 1 (3 when stopped); the agent is not retried. The
  agent's proposal is kept beside the thread as `goal-draft/proposal.json`. Nothing here approves the goal or starts a run.
- **`goal draft [<id>] --replace --request …` redrafts an existing goal.** Only `title` and the three sections change;
  the id, base, spend, timeout, `model`, `push_to` and comments stay as they are. `status` becomes `draft` and
  `approved_at` and `approved_hash` are removed, so an approved goal needs `goal approve` again (the command says so). It
  is refused for an ended thread or a live run. A failed draft leaves the file byte-identical.
- **`goal new <name> --from <goal-file>` starts from another goal.** It copies the file's request, criteria and
  out of scope, and its `budget_usd` or `spend_policy`, `turn_timeout_min` and `model`, into the draft. Those are checked by the
  same rules as in any goal (below); a bad one is a usage error (exit 2) naming the key, and nothing is created.
  One the file does not give keeps the default (`default_budget_usd`, 30 minutes, no `model`). The rest of the front
  matter (`id`, `title`, `base`, `status`, `push_to`, `approved_at`, `approved_hash`) belongs to the file's own
  thread and is ignored; `goal new` prints one line naming what it ignored (`ignored from the file: base, status`),
  nothing when there is none. The file's front matter must still be well formed (unknown or repeated keys are goal
  errors) but no key is required in it, and its body must parse as a goal's. The draft is always a draft.
- **The inputs are the goal and the project's instructions file.** The runner builds the first prompt from
  the goal, and puts the repository's `AGENTS.md` (else `CLAUDE.md`) after "Out of scope" under
  `## Project instructions`. Nothing else installed on the machine reaches a run. See "Project
  instructions" below.

## Parsing details

Implemented in `Sources/WorkbenchCore/Goal/`.

- **Front matter is a small subset, not YAML.** `key: value`, one per line, known keys only (unknown and
  duplicate keys are errors, so a typo like `budjet_usd` is caught). A comment starts at `#` after two or
  more spaces, so `title: Fix #12` stays intact. Quote a value to be safe: `title: "Fix  # twelve"`.
- **Required:** `id`, `title`, `base`, `turn_timeout_min`, and `budget_usd` unless `spend_policy` is set. `status`
  defaults to `draft`.
  **Optional:** `spend_policy`, the single value `timeout_only`. Absent, `budget_usd` is a hard dollar cap, as it
  always was. `spend_policy: timeout_only` means **no dollar cap**: `turn_timeout_min` is the only bound on a turn.
  The two exclude each other: a goal with both is an error naming `budget_usd` and `spend_policy` (a kept budget
  that nothing enforces would be an ignored field), and any other value of `spend_policy` is an error naming the key.
  A `budget_usd` goal runs only on an adapter that reports a hard dollar cap; on one that does not, `run` is refused
  before anything starts, with a message that says to change the goal to `spend_policy: timeout_only` and approve it
  again. A `timeout_only` goal runs on any adapter, Claude included: Claude is then started without
  `--max-budget-usd` and its cost is still recorded. `run --budget` and `send-back --budget` are refused on such a goal
  (there is no cap to override). `goal approve`, `status`, `review`, `doctor` and the PR description print
  `no dollar cap: bounded by N min per turn` where a budget would be. **A cost nobody reported is unknown, never 0:**
  `turn.ended` has no `cost_usd`, the thread's total says `unknown` in text and is null in `--json`.
  **An older Workbench fails closed.** Front matter is strict, so a binary from before this key reports
  `unknown key 'spend_policy'` and refuses the goal instead of running it with a cap it cannot see.
  **Optional:** `model`, a model name or alias (`opus`, `claude-opus-5-5`; no leading `-`, no spaces). It
  wins over the config's `model`, which wins over the CLI default, and applies to every turn of the thread,
  send-backs included. The turn's `argv` in `turn.started` shows what ran.
  **Optional:** `push_to`, an existing branch of `origin` the thread continues, such as a pull request's
  branch. `workbench goal new <name> --update <branch>` writes it together with `base: origin/<branch>`, and
  `base` must be exactly that. Before the first turn the run fetches the branch and cuts the worktree from
  its current tip, so review and accept see only what the thread adds on top. The local branch is still
  `workbench/<id>`. `main`, `master`, `trunk` and `develop` are refused. `ship` pushes the work to that
  branch and records the branch's open pull request, instead of creating a branch and a PR
  ([P2.5](../plan/P2.5-ship.md)).
- **Unsafe values are rejected, not escaped.** `id` becomes a directory name and `base` goes into git
  arguments, so `id` is letters, digits, `.`, `_`, `-` (max 100, must start alphanumeric) and `base` may not
  start with `-` or contain `..` or whitespace. `budget_usd` is a positive number, `turn_timeout_min` a whole
  number from 1 to 1440.
- **Criteria** are `- [c<N>] text` with an indented `- proof: ...` line. Ids are unique. Text and proof may
  wrap onto indented continuation lines. A criterion without proof is an error.
- **Out-of-scope bullets wrap like criteria.** An indented line directly under a `- ` bullet continues it;
  any other line in the section is an error.
- **A proof that cannot run blocks approval and the run.** `workbench goal approve` reads the backticked
  commands in each `proof:` and refuses (exit 6, nothing approved) with `[c2] proof names ... ` for one the
  tool set would not let a run execute: denied by a `[tools] denied` pattern, absent from `allowed` (the entry that would permit it is
  named), or `Bash` not available. A span counts as a command when its first word is an executable the
  tool set already names or a path under `./`, `scripts/` or `bin/`, so code identifiers in backticks are
  left alone. A span joined with `&&`, `||`, `;` or `|` is judged part by part. `check_command` counts as
  allowed. The config is not in the hash, so `run` and `send-back` check again against the config as it is
  then and refuse before a turn is spent. `--allow-unrunnable-proofs` (on `goal approve`, `run`,
  `send-back`) goes ahead anyway, for a proof that only looks like a command; `approve` then prints the
  warnings.
- **Errors are collected**, in file order, with line numbers, so one pass fixes the file.
- **Approval state** is derived on every read, never trusted from the file:
  `draft` (not approved), `approved` (status is approved and `approved_hash` matches the content), `stale`
  (status says approved but the hash is missing or differs). Only `approved` runs.
- **What the hash covers:** a version tag, `base`, `budget_usd` (as a number, so `5` equals `5.00`) or, for a
  `timeout_only` goal, the line `spend_policy=timeout_only` in its place (so a goal with a cap keeps its hash, and
  dropping a cap needs a fresh approval), `turn_timeout_min`, `model` and `push_to` (each only when set, so a goal without them keeps its hash), and the body after the
  front matter. Line endings, trailing whitespace and blank
  lines at the edges are normalized first. `title` and `id` are not covered, so renaming a goal does not
  revoke approval.
- **Approving rewrites only** `status`, `approved_at` and `approved_hash`; the body and the author's
  comments are kept as written. Approving an already approved goal changes nothing.

## Tool permissions

One fixed set per project, in `.workbench/config.toml` (no named profiles until there is a real need).
`Config.exampleTOML` is the starting point.

```toml
check_command = "scripts/check.sh"      # optional; written exactly as it will be invoked
# app_type = "web"                      # "web" (default) or "desktop": desktop makes doctor check Screen Recording for the verifier
# setup_command = "mix deps.get"        # optional; run once in a new worktree before its first turn
# copy = [".env.*", "example/.env"]     # optional; git-ignored files copied from your checkout into each new worktree
default_budget_usd = 5.00               # used when drafting a goal
# claude_path = "claude"                # name on PATH, or an absolute path
# model = "opus"                        # --model for every turn; a goal's `model` wins; unset = the CLI default
# judge_model = "sonnet"                # --model for the judge (it only reads); `judge --model` wins; unset = model
# describe_model = "haiku"              # --model for the PR description turn; unset = model
# plan_model = "opus"                   # --model for `workbench plan` (it only reads); `plan --model` wins; unset = model
# safe_mode = true                      # default: no CLAUDE.md, skills, plugins, hooks or MCP in runs
# project_instructions = true           # default: Workbench puts AGENTS.md (else CLAUDE.md) in the first prompt
# env_pass = ["ANTHROPIC_API_KEY"]      # extra variables claude may see
# editor = "cursor"                     # `workbench open`: cursor, code, zed, subl, windsurf or one plain command
# [pr_review]                           # `workbench pr-review`: Codex reviews the shipped pull request
# checklist = "docs/REVIEW.md"          # optional: this project's review invariants, read from the PR head
# max_rounds = 3                        # reviews of one pull request, counted from the event log (1 to 10)
# [review]                              # P6: the review stages, in order (the loop runs only pr-review so far)
# stages = ["pr-review", "design"]      # default ["pr-review"]
# [review.stage.design]                 # one table per stage; [review.stage.pr-review] may replace [pr_review]
# prompt = "docs/REVIEW-DESIGN.md"      # or skill = "...SKILL.md", never both; plus checklist, reviewer,
#                                       # inputs, applies_to, max_rounds
# [providers.codex]                     # P9: the executable of a provider (claude: the same as claude_path)
# executable = "/opt/homebrew/bin/codex"
# [agents.judge]                        # P9: provider, model and allow_unpriced for goal, run, judge and review
# model = "haiku"                       # also [review.stage.<name>] provider, model and allow_unpriced
# [run]                                 # P16: how the verifier's app is started; Workbench runs it and stops it
# command = "npm run dev:mock"          # one plain command, run in the worktree with WORKBENCH_PORT (and PORT) set
# ready_url = "http://localhost:{port}/"  # or ready_line = "on mock data"; exactly one. Any HTTP answer is up
# ready_timeout_s = 120                 # default 120 (1 to 900)
# [verifier]                            # P10: a skill run as its own turn that drives the app and leaves proof
# skill = ".claude/skills/verify/SKILL.md"  # the default; an explicit repo path, read from the base commit
# tools = ["Read", "Bash(scripts/verify-app.sh:*)"]  # what the verifier may use; default ["Read"]; no bare Bash
# model = "sonnet"                      # --model for the verifier; unset = model
# enabled = false                       # the verifier is on by default; this turns it off
# budget_usd = 1.00                     # default 1.00
# timeout_min = 10                      # default 10 (1 to 240)

[tools]
available = ["Read", "Grep", "Glob", "Edit", "Write", "Bash"]
allowed = ["Read", "Grep", "Glob", "Edit", "Write",
           "Bash(git status:*)", "Bash(git diff:*)", "Bash(git add:*)", "Bash(git commit:*)",
           "Bash(swift build:*)", "Bash(swift test:*)"]
denied  = ["Bash(git push:*)", "Bash(gh pr merge:*)", "Bash(rm -rf:*)"]
```

Notes:

- The runner passes `--permission-prompts none --restricted --tools <available> --allowedTools <allowed>
  --disallowedTools <denied>`; the prompt follows `--`. Anything not allowed is denied automatically, and
  the model is told so. That is the whole permission system.
- **`--safe-mode --disable-slash-commands` are passed unless `safe_mode = false`.** They remove everything
  installed on the machine from the run (CLAUDE.md, skills, plugins, hooks, MCP servers, custom agents).
  Measured in task 9: a two-call job went from about 180k tokens of context to 2k, the same result at
  roughly 1/150th of the list price, and far less of the 5-hour window. It applies only to sessions created
  with it; a resumed session keeps the system prompt it was created with.
- **`--restricted` is always passed and cannot be turned off from the config.** It is what confines the
  file tools to the worktree. Bare `Edit`/`Write` in `allowed` are therefore safe, and without
  `--restricted` they would not be: spike S3 showed they can write anywhere on disk.
- **While working, a run is told to prefer the narrowest check it is allowed.** The "Checking your work"
  section of the first prompt says the full `check_command` is run by Workbench when the turn ends, and that
  the run need not run it: if it does, once, and again only after changing something. A criterion that names the
  full check ("`scripts/check.sh` passes") makes a run do exactly that inside its turn, so write it as "the changed
  files lint clean and their suites pass" and let the project's `check_command` prove it. Allowing a narrow test command in `[tools]`
  (for Swift: `Bash(swift build:*)`, `Bash(swift test --filter:*)`) is what gives it a fast loop.
- **The check command is a literal prefix.** `check_command = "scripts/check.sh"` becomes
  `Bash(scripts/check.sh:*)`: `scripts/check.sh` and `scripts/check.sh --fast` run; `./scripts/check.sh`,
  `sh scripts/check.sh` and an absolute path are denied (task 4 smoke test). It must be one plain command,
  with no shell operators or quotes. The runner should tell the model the exact string to use.
- **`setup_command` is run by Workbench, not offered to the model.** One plain command, validated like
  `check_command`, run in the new worktree after it is cut and before the first turn: an install step
  (`mix deps.get`, `npm ci`). It uses the check's machinery (minimal environment, merged streams, process
  tree swept) with a 15 minute limit and 1 MiB of output kept in `setup.log`. It is not added to `allowed`,
  and not run again on a send-back. A failure ends `run` with the command's output and exit code 1 before
  any turn is spent; the worktree is kept and the next `run` tries it again. What it writes into the
  worktree is untracked there: keep installs in ignored paths (`deps/`, `node_modules/`), or they show up
  in the diff.
- **`copy` brings the ignored files a checkout needs into each new worktree.** Repo-relative paths or globs
  (`*` and `?` within one path component, no `**`), copied from the main checkout right after the worktree is
  cut and before `setup_command`, so an install step can read them (`.env.*`, `example/.env`). Only regular files
  that git ignores are copied, by the rules of both the main checkout and the new worktree (which has the base's
  rules): a file either does not ignore would show up in the diff, so it is skipped with that reason. Also skipped,
  with a reason: a symlink (never followed), a file whose folder is a symlink in the worktree, a file over 1 MiB,
  anything past 200 files, and a file already there. A pattern that matches nothing is a note, not an error. At
  most 1000 directory entries are looked at (matching or not) and 20 notes kept, then one line counts the rest. A run
  killed mid-copy finishes the copy on its next `run`, before the first turn. Entries are checked when the
  config loads: no absolute or `~` path, no `.`, `..` or empty parts, nothing under `.git` or `.workbench`.
  `worktree.created` lists what was copied; `doctor` copies too, so its setup and check see the same files a
  thread does, and prints `copy: not copied:` lines for what it left out.
- **`verify_command` and `verify_timeout_min` are gone.** A config that still has either is refused at load with
  "'verify_command' was removed: replace it with a [verifier] table" (not the unknown-key message), so nothing runs
  on a half-migrated project. The project's evidence is made by the verifier ([P10](../plan/P10-skill-verifier.md)),
  a `claude` turn on the project's skill; a project with no skill at the base has no verify step. When a goal has a
  `screenshot:` proof and the verifier will run (on, the default, with its skill in the base commit), the first prompt
  says the verifier captures it, so Claude does not report it as unverified.
- **`[run]` is checked when the config loads** ([P16](../plan/P16-run.md)). `command` is one plain command like `check_command`
  (no operators, quotes or substitutions); exactly one of `ready_url` (an `http` URL on `localhost` or `127.0.0.1`, `{port}`
  standing for the port) and `ready_line` (a regular expression a line of the command's output must match) says when the app
  is up; `ready_timeout_s` is 1 to 900 (default 120). A missing `command`, none or both ready checks, an unknown key or a bad
  value is refused with the key named. Without `[run]` nothing changes. With it, a verifier turn first starts the command in
  the thread's worktree as a child of Workbench (its streams merged, its whole process tree ended on every ending, also on a
  stop and a timeout), on a free port given as `WORKBENCH_PORT` and `PORT`, and starts `claude` only once the app is ready.
  The verifier's environment and prompt then hold `WORKBENCH_RUN_PID`, `WORKBENCH_PORT` and, for `ready_url`,
  `WORKBENCH_RUN_URL`, and the prompt tells it not to start or stop the app. An app that exits, never comes up or is not
  found ends the verifier with `ok: false` and the reason, and spends nothing. The command comes from the project's
  config, never from a file in the worktree. It is launch only: nothing it prints or returns is a verdict.
- **`[verifier]` is checked when the config loads** ([P10](../plan/P10-skill-verifier.md)). `skill` is optional (default `.claude/skills/verify/SKILL.md`) and is an explicit repository path (`.claude/skills/…` and
  `.agents/skills/…` both work; nothing is discovered): no empty value, no absolute path, no `..`. `tools` are
  Claude Code permission patterns; a bare `Bash`, `Bash(*)` and the like are refused, and the list may not be empty.
  `model` is a model name, `enabled` a boolean (`false` turns the verifier off; it is on with no table at all), `budget_usd` a positive number, `timeout_min` 1 to 240; any other key
  (there is no `provider`) is refused with its name. The skill is read from the thread's base commit, never the
  worktree, as a regular file: a symlink, or a path through one (this repository's `.claude/skills/<name>` points
  into `.agents/`), is refused with the real path to use; missing and empty are refused with the path; text over
  32 KiB is cut with a marker. `doctor` reads it at its `--base` and prints the path, size, sha256, model, tools and
  `auto`, and a skill that cannot be used is a warning, not a failure.
- **`workbench verifier [id] [--again]` runs the skill as a separate turn.** Like the judge it is advisory and costs
  money: one `claude -p --output-format json` run in the thread's worktree, in `--safe-mode --restricted
  --disable-slash-commands --add-dir <the turn's proof folder>` (the file tools are confined to the worktree, and the
  proof folder is outside it: the run can `Read` the screenshots it takes), with `--model` from `[verifier] model` (else the coding `model`), the tools of `[verifier]
  tools` as `--tools` and `--allowedTools` and nothing else (the project's `[tools] denied` still applies), its own
  session, `--max-budget-usd` from `budget_usd` and the `timeout_min` deadline. Its prompt holds the skill text read from
  the base commit, the goal's request and criteria, and `WORKBENCH_PROOF_DIR` (the latest turn's `proof/turn-N`, not
  emptied), `WORKBENCH_THREAD` and `WORKBENCH_GOAL`, which its tools see too. It runs once per turn unless `--again`
  (a failed attempt does not count). The thread's log is held while it runs: a second verifier, a judge, a run or a
  send-back is refused as busy, `stop` reaches it, and `doctor` is refused. It runs under the same process layer as
  every `claude`: its own process group, SIGTERM then SIGKILL, the tree swept, and after it ends any process left with
  no live parent and the worktree as its working directory (an app started in a session of its own) is killed. It ends
  in exactly one `verifier.ended` ([event-log.md](event-log.md)), and what it says is stored as a bounded note, never
  as a pass. Unless `[verifier] enabled = false`, a run starts it after the check, when the turn succeeded, the check passed
  (or none is declared), the worktree has a change to look at and no `verifier.ended` exists for the turn; a project
  with no skill file at the base gets no verifier and no event, and any other reason it cannot start (a symlinked or
  oversized skill, no change) is a `verifier.skipped` with the reason and a note; none fails the turn. An answer that is empty is not a success. Every PNG the run adds to, or changes in, the turn's proof folder
  is recorded as `proof.added` (with `source: "verifier"`, the commit and tree it ran at) before `verifier.ended`;
  other files are only listed in `files`. `review` prints a `Verifier` section (and, for an older log, the verify step's): advisory,
  the turn, its cost and time, the screenshots, and what it said as a note (twelve lines at most, each cut), never
  a pass; `review --json` has it as `verifier`. The judge and a review stage that reads `proof` are given every PNG of
  the turn's proof (both sources, bounded as before: eight for the judge, twenty for a stage), each with its pixel
  size, and `review_stage.started` names them in `proof`.
- **Review stages are checked when the config loads** ([P6](../plan/P6-review-stages.md)). A name in
  `review.stages` needs a `[review.stage.<name>]` table unless it is built in (only `pr-review` is); a stage
  name is lower case (letters, digits, `-`, `_`, up to 40), since it becomes a folder in the thread's
  directory. In a stage table `skill`, `prompt`, `checklist` and `inputs` paths stay inside the repository,
  `skill` and `prompt` exclude each other, `reviewer` is `codex` or absent (`"claude"` is refused: choose Claude with
  `provider = "claude"` instead), `inputs` entries are
  `diff`, `goal`, `proof` or a file path (with a `/` or an extension, so a misspelt keyword is refused), and
  `max_rounds` is 1 to 10. `[pr_review]` is the `pr-review` stage's table under its P5 name, with only
  `checklist` and `max_rounds`; it and `[review.stage.pr-review]` together are refused. A stage table not
  listed in `stages` is ignored, and `doctor` says so; it also warns when `stages` leaves out `pr-review` and
  when a stage's `skill` or `prompt` file is missing. A round reads the `skill` or `prompt` file from the
  pull request's checkout and puts its rubric in the brief in place of the built-in report instructions (a
  skill's `## Rubric` section when it has one, else the whole skill under a header saying to ignore steps that
  build, run or post; a prompt file whole); when that file is missing or empty the round fails.
  A stage table may also set `provider`, `model` and `allow_unpriced`, which override `[agents.review]` for that stage;
  `reviewer = "codex"` is read as `provider = "codex"`, and a stage with both keys is refused.
  `workbench review-stage <name>` runs one round of a listed stage (`pr-review` is `workbench pr-review`).
  `proof` attaches the top-level `*.png` files of the thread's latest proof (the verifier's, or an older log's verify step) to the Codex run (`-i`, at
  most 20) and lists their paths in the brief; with no proof, one from before the latest turn, or no
  PNG left, the round fails, never passes, and `doctor` warns when such a stage has no verifier skill at the base.
  `applies_to` globs (`**` any run of folders, `*` within one name) are matched against the files the pull
  request changes (a renamed file counts by its old path and its new one); a stage, `pr-review` included, that matches none is recorded as skipped and runs nothing.
  An empty list (the default) always runs, and so does a round whose list of changed files git could not give
  whole, with a note saying so. Other `inputs` (a file path, or leaving out `diff` or `goal`) are not read
  yet; a round of a stage that sets them says so in a note.
- **Ignored files do not keep a shipped worktree.** After a ship, the worktree is removed only when nothing in
  it could be lost, which means nothing uncommitted: modified, staged and untracked files all keep it. A file
  the repository ignores does not, since git already says what is ignored and a worktree Workbench made holds
  only what its `setup_command`, check or run produced (`node_modules`, a build directory,
  a verify login file). `worktree.removed` names what was ignored in it, so the record shows what went.
- **The child environment is an allowlist**: `PATH HOME USER LOGNAME SHELL LANG TMPDIR TERM
  CLAUDE_CONFIG_DIR` and `LC_*`, plus whatever `env_pass` names. `USER` and `LOGNAME` are required: without
  them `claude` reports "Not logged in" even though the config dir is set. `SSH_AUTH_SOCK` and every token
  variable are left out on purpose, so a model that gets past the allowlist still holds no credentials.
  A version manager's own variables are dropped too (mise on Elixir sets `MIX_HOME` and `MIX_ARCHIVES`), so a
  `setup_command` that passes in your shell can fail here. A failed setup (exit or signal, not a timeout)
  prints a hint at `env_pass`.
- **`workbench doctor [--base <branch>]` proves the declared config works** before any goal exists. It cuts
  a throwaway worktree (reserved id `doctor`, removed on every path, a crash leftover is replaced by the next
  run) at the base (default: the repo's default branch, as for `goal new`), runs `setup_command` then `check_command` through the
  same runners, environment and limits a thread uses, and prints each step's result, duration, output tail
  and, for a failed setup, the `env_pass` hint. It also says where `claude_path` resolves, the `model` (or
  the CLI default), and whether `Bash` is in `[tools].available` and the check is not denied. It runs nothing the config does not
  declare, writes no event into a thread and no file into the project, and refuses while a thread's run is live
  (a turn or check; a draft, an approved goal or a finished turn does not stop it) or another doctor holds the project (a lock on `.workbench/`, which also makes `goal new` wait for it). A worktree it cannot remove is an error
  (exit 1) that names the command to remove it by hand.
  A step the config leaves out is reported, not failed; the check is skipped when a declared setup did not
  pass. Exit 0 when everything declared passed, 1 when a step did not, 3 when stopped (`exit-codes.md`).
  Doctor does not start the `[run]` app either: it prints the command and ready check and warns when the command is a
  repository path that is not at `--base`, or when the verifier is off so nothing would use it.
  Doctor does not run the verifier (it is a paid `claude` turn). It reads `[verifier]`'s skill at `--base` and says
  whether it can be used. With `app_type = "desktop"` and a usable skill, it also checks that the process running
  doctor may record the screen (`CGPreflightScreenCaptureAccess`) and, if not, warns and names the Settings pane
  (a warning, not a failure). `web` (the default) and an unset key are never checked.
- **`editor` is for a person, not a run.** `workbench open [id] [--editor <name-or-command>] [--print] [--goal]` opens the
  thread's worktree (`.workbench/worktrees/<id>`, on `workbench/<id>`) as its own editor window, so Source Control shows
  the branch's diff, which the parent repository's window hides because `.workbench/` is ignored. The thread is the one
  named, else the active one; a thread with no worktree (shipped, accepted, discarded, abandoned, or not run yet) is
  refused (its message points to `--goal`), and so is a worktree path that resolves, after symlinks, outside `.workbench/worktrees/`. The editor comes
  from `--editor`, else `editor` here, else `editor` in `~/.workbench/config.toml` (the global file, which allows this
  key); never from `$EDITOR` or `$VISUAL`, since a terminal editor would block with no terminal. None set is refused
  with what to do. The value is a known name (`cursor`, `code`, `zed`, `subl`, `windsurf`: its launcher on `PATH`, else
  on macOS `open -a "<App>"` with `Cursor`, `Visual Studio Code`, `Zed`, `Sublime Text`, `Windsurf`) or one plain command
  validated like `check_command` (a path in it must be absolute), which gets the worktree path as its last argument. A bad
  value is an `invalid-config` error naming `editor`. The launcher starts through the same spawner as every child (no
  shell), with only `PATH HOME USER LOGNAME SHELL LANG TMPDIR` and `LC_*`, and has 10 seconds to return: one that does
  not is stopped with its process group and reported, a non-zero exit is reported with its last output line, and what it
  prints goes nowhere else. The editor it leaves running is not stopped. `open` writes no event and changes nothing in
  the thread or the worktree; `--print` prints only the path and starts nothing (`cd "$(workbench open --print)"`).
  `--goal` opens the thread's `goal.md` (`.workbench/threads/<id>/goal.md`) instead, which a draft has before any run;
  it needs only that the file exists, and `--print --goal` prints its path.
  `doctor` prints `editor:  <value> (from --editor|project|global)` or `editor:  none set`, never starts it and never
  fails for it; `doctor --editor <value>` shows what that flag would pick. A run never reads the key.
- Unknown keys, unknown tables and syntax outside the supported TOML subset (dotted keys, inline tables,
  multi-line strings) are errors, reported together with line numbers.
- Bash compound commands, substitutions, redirects and out-of-tree paths were all denied by the CLI in S3
  (18 of 18). We do not re-implement any of that; the worktree and the absence of credentials cover the rest.

**Providers and agents (P9 PR 7).** `[providers.claude]` and `[providers.codex]` take `executable`, a command name or
path run without a shell; `[providers.claude]` and `claude_path` name the same executable, so both is refused. An
`[agents.<role>]` table, for `goal`, `run`, `judge` or `review`, takes `provider` (`"claude"` or `"codex"`), `model`
and `allow_unpriced`. With none of these tables a thread behaves as before: Claude runs and judges, Codex reviews, and
goal drafting stays manual. The pair a role may use is limited to what an adapter exists for: `judge`, `review` and
`goal` on `claude` or `codex`, `run` on `claude` only; anything else is refused when the config loads, not ignored, until
coding on the second provider is enabled (P9 task 4). `goal` accepts either provider but nothing drafts yet, and it needs `provider`.
`allow_unpriced` is for evaluations that may run without a dollar cap; `[agents.run]` refuses it, because spending
is approved in the goal. A model is resolved per role: for the judge `judge --model`, then `[agents.judge]`'s
`model`, then `judge_model` and `model` (only while `[agents.judge]` sets no provider or model, and only for Claude),
then the provider's default; for review the stage's `model`, then `[agents.review]`'s, then the default; for coding
the goal's `model`, `[agents.run]`'s, then `model`; drafting never inherits `model`. `workbench doctor` prints
`agent goal:`, `agent run:`, `agent judge:` and `agent review:` lines with the provider and model each resolves to.
**Judge and review on either provider (P9 PR 13).** A Claude review runs through the read-only adapter (`--restricted`, only
the `Read` tool, in the round's folder that holds the brief, the saved diff and the checkout, its own session, a $2 cap);
its answer text is written to the same `round-<n>.findings.md` a Codex answer goes to, and the same `VERDICT: CLEAN|FIX`
parser, answer cap, retry on capacity and `max_rounds` count apply. Claude is not given a stage's `proof` screenshots (it has no
image input and there is no text substitute), so such a stage fails the round. A Codex judge runs read-only with the
hardened call (`--ignore-rules`, `approval_policy="never"`), is asked for the same JSON as text, has its screenshots attached
with `-i`, and writes its last message to `judge/turn-<n>.answer.txt` in the thread's folder; the same validator accepts it
only if it names every criterion once. Codex has no dollar cap and no `model` here (a `model` on a Codex judge or review
is refused when the config loads, also through a stage that inherits it), so a Codex judge or review is refused before
anything starts unless its table says `allow_unpriced = true` (`[agents.judge]`, `[agents.review]` or the stage's table,
which inherits `[agents.review]`'s); the message names the key and the refusal is recorded as a failed judge or round.
Exception: a review whose provider no `provider` key chose (the default Codex, or P6's `reviewer = "codex"`) keeps
running timeout-only without the opt-in. A Claude judge or review keeps its dollar cap and `allow_unpriced` changes
nothing for it. `judge --budget` with a Codex judge is a usage error. A review's `cost_usd` is recorded when its provider
reports one (Claude); unknown is absent, never 0, and `review` prints a Codex judge's cost as `cost unknown`. The
executables (`[providers.<id>]`, `claude_path`) take effect for every role; `run` and goal drafting are unchanged.

## Project instructions

Safe mode keeps `claude` from reading `CLAUDE.md`, so Workbench reads the project's instructions file itself
and includes it in the first prompt. Implemented in `Sources/WorkbenchCore/Thread/ProjectInstructions.swift`.

- **Which file.** `AGENTS.md` at the top level of the repository, else `CLAUDE.md`. The first that is a
  regular file wins; a symlink, a submodule or a directory counts as absent. Neither: no section.
- **Read from the base commit, through git** (`git ls-tree`, `git cat-file`), never the filesystem. The main
  checkout and the worktree, which the run may already have edited, cannot change it. The commit is the one
  the worktree was cut from, recorded in the `worktree.created` event (older threads fall back to the
  merge-base of the thread branch and `base`). A file over 1 MiB is not read (git writes the whole object before we see it) and counts as absent; of a smaller one at most 64 KiB is used.
- **Imports.** A line that is exactly `@<relative path>` is replaced by that file's content. Relative paths
  resolve from the importing file's directory and must stay inside the repository. Absolute paths, `..`
  escapes, symlinks, missing files, directories, a file already included and a depth over 3 are left as
  written and listed in `skipped`. At most 32 files are imported, and none once the text is past the size limit. A line is an import only when it is exactly `@path`: no indentation, no spaces, nothing after it. Lines inside fenced code blocks are not expanded (a fence closes only on a line of the same character that is at least as long) and are listed in `skipped` as "inside a code block".
- **Normalised.** A leading BOM is dropped, CRLF becomes LF, invalid UTF-8 is replaced.
- **Size.** At most 16384 bytes including the marker: cut at a line boundary, with a final line
  `[project instructions truncated at 16384 bytes]`. The import cutoff counts expanded text; a replaced
  import directive does not consume the size limit.
- **Where.** After "Out of scope" and before "Checking your work", under `## Project instructions`, introduced
  by a fixed sentence that says Workbench does the pushing and opening of pull requests after review, so the
  run commits in its worktree and stops.
- **When.** In every prompt built from the goal: the first turn, and a first turn that did not succeed and is
  run again. A feedback turn resumes the session and does not repeat it.
- **Recorded.** Such a turn's `turn.started` has `instructions` (see the event log spec). The text itself is
  in `prompts/turn-N.md`.
- **Opt out.** `project_instructions = false` in `config.toml`.
