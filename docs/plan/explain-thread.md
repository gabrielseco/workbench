# explain-thread: the output contract

`workbench explain-thread` explains one review thread of a GitHub pull request: what the reviewers ask for, whether it
holds, and a proposed fix. Triage is the first consumer: it shows the answer beside the thread. This page is what such a
caller may rely on. Anything not written here (the wording of progress and `note:` lines, how the agent words its
answer) can change without notice.

## Command

```
workbench explain-thread --pr <n> --thread <id>
```

Run it in the project's repository (any folder inside it). No thread of Workbench is needed and none is touched.

| Flag | Meaning |
|---|---|
| `--pr <n>` | Required. The pull request number on the repository `origin` points at. It must be open and its branch on origin (not a fork), as for `explain-pr`. |
| `--thread <id>` | Required. The review thread's GraphQL node id (`PRRT_…`, as `reviewThreads { nodes { id } }` gives it): letters, digits, `_`, `-`, `=` and `+`, at most 128 characters. |

There is no `--out`, no `--again` and no global `--json`: the answer is always the JSON line below, and nothing is kept
for reuse.

## What it gathers

Everything comes from the number and the id; the caller passes nothing else.

- The pull request: `gh pr view <n> --json headRefName,baseRefName,title,body,state,isCrossRepository`. Its title and
  description go to the agent.
- The thread: `gh api graphql` with a query on `node(id:)` (never a mutation): its file path, line (or original line and
  start line for a range), outdated and resolved flags, the pull request it is on, and every comment (author, body,
  time, diff hunk, outdated), read 100 at a time up to 1000 and put oldest first. A longer thread is cut and a `note:`
  says so.
- The head: origin's tip of the pull request's branch (`git ls-remote`), fetched and checked out in a throwaway worktree
  under `.workbench/explains/pr-<n>-thread-<id>/`; the base is pinned from origin and the diff is saved beside it.
- The code around the line: 20 lines either side of the commented line or range, from the head's checkout, the
  commented lines marked. For an outdated thread the original line is used and the brief says it may have moved; the
  thread's diff hunk is given in any case.

## What it does

The review agent (`[agents.review]`, Codex unless configured otherwise) runs read-only on that checkout with the above in
its brief, the comments quoted in a fence. Then the checkout is removed. Nothing is committed, pushed, replied, resolved
or recorded in a thread's log; `gh` is only asked to read. It holds the same project lock as `pr-review --pr` and
`explain-pr` (they share `FETCH_HEAD`), so none of them runs beside another. The agent's brief and transcript stay in
`.workbench/explains/pr-<n>-thread-<id>/` for reading after a failure, replaced by the next run of the same thread.

## stdout

Progress lines and `note:` lines come first. On success **the last line on stdout is one JSON object**, on one line:

```json
{"head_sha":"<40 hex>","pr":12,"proposed_fix":"<Markdown>","reasoning":"<Markdown>","thread":"PRRT_…"}
```

| Field | Type | Meaning |
|---|---|---|
| `reasoning` | string, non-empty | What the thread asks for, whether it holds against the code and the diff, and why. Markdown. |
| `proposed_fix` | string, non-empty | The change proposed (often with a unified diff in a fenced block), or what to reply when the thread does not hold. Markdown. A proposal only: nothing is applied. |
| `pr` | number | The `--pr` given. |
| `thread` | string | The `--thread` given. |
| `head_sha` | string | The head commit the agent read. |

Keys may be added later; a caller ignores the ones it does not know. A caller reads the last line and nothing else.

On failure no object is printed: stdout has only progress lines, and stderr has one line,
`workbench: <kind>: <message>`.

## Exit codes

| Code | Kind | When |
|---|---|---|
| 0 | | the last stdout line is the object above |
| 1 | `failed` | no explanation: the agent is missing, was at capacity three times, crashed, timed out or was stopped, or its answer was empty, missing, not a JSON object, or lacked a non-empty `reasoning` or `proposed_fix` string; also when `gh` could not read the pull request or the thread (other than its not existing) or origin could not be read |
| 2 | `usage` | no `--pr` or `--thread`, a `--pr` that is not a positive number, a `--thread` that is not a node id, an option without its value, or an unknown argument |
| 6 | `refused` | nothing was spawned: `gh` is not found, GitHub has no review thread with that id (or the id is of something else), the thread is on another pull request or another repository's, the pull request is not open, comes from a fork or has a branch name Workbench will not pass to git, origin no longer has the branch, or another `pr-review --pr`, `explain-pr` or `explain-thread` holds the project |
