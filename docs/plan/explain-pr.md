# explain-pr: the output contract

`workbench explain-pr` explains a pull request in Markdown, so another tool can keep the explanation as a note. Triage
is the first consumer: it wraps the file in its own front matter and opens it in Obsidian. This page is what such a
caller may rely on. Anything not written here (the wording of the progress lines, the sections the agent writes) can
change without notice.

## Command

```
workbench explain-pr --pr <n> [--out <file>] [--spec <file>] [--again]
```

Run it in the project's repository (any folder inside it). No thread is needed and none is touched.

| Flag | Meaning |
|---|---|
| `--pr <n>` | Required. The pull request number on the repository `origin` points at. It must be open and its branch on origin (not a fork), as for `pr-review --pr`. |
| `--out <file>` | Also write the explanation to `<file>`, replacing it whole. Its folder must exist; a folder as `<file>` is refused. Relative paths are from the current directory. |
| `--spec <file>` | Give the agent this file (a regular text file of at most 64 KiB) as what the change was written against, instead of the pull request's own title and description. |
| `--again` | Explain again even when the head has not moved. |

There is no `--format` and no `--json`: the output is Markdown only. A later machine-readable form would follow the
global `--json` convention.

## What it does

The plumbing of `pr-review --pr`: `gh pr view` reads the pull request, origin's branch tip is the head, the head is
fetched and checked out in a throwaway worktree, the base is pinned from origin, the diff is saved beside it, and the
review agent (`[agents.review]`, Codex unless configured otherwise) runs read-only on that checkout. Then the checkout
is removed. Nothing is committed, pushed, posted or recorded in a thread's log; `gh` is only asked to read. It holds the
same project lock as `pr-review --pr` (they share `FETCH_HEAD`), so the two never run at once.

## Where the file is

- The explanation is always kept at `.workbench/explains/pr-<n>-<head7>.md` in the project, where `<head7>` is the first
  seven characters of the head commit explained.
- With `--out <file>`, it is also written to `<file>`, and that is the path reported.
- Both are written atomically: a reader sees the whole old file or the whole new one, never a part.
- The agent's transcript and brief stay in `.workbench/explains/pr-<n>-<head7>/` for reading after a failure.

## Reuse

The kept file names its head. When `.workbench/explains/pr-<n>-<head7>.md` already exists for the head origin has now,
no agent runs: the kept file is reported (and copied to `--out` when given) and the command exits 0. `--again` runs the
agent once more and replaces the kept file. A head that has moved names a different file, so it is explained afresh.
Files of older heads are left in place.

## stdout

Progress lines and `note:` lines come first. On success **the last line on stdout is the absolute path of the
explanation's file**, alone: the `--out` file when given, else the kept file. A caller reads the last line and nothing
else.

On failure no path is printed: stdout has only progress lines, and stderr has one line,
`workbench: <kind>: <message>`.

## The file

The Markdown body only. There is no YAML front matter: the caller adds its own (Triage writes `pr`, `head` and
`generated`). A front matter block the agent writes anyway at the top is dropped. The text is trimmed and ends in one
newline. It starts with a level-1 heading naming the change, then a summary, how it works, what a reviewer should look
at, and the tests, though that structure is the agent's and not part of the contract.

## Exit codes

| Code | Kind | When |
|---|---|---|
| 0 | | the explanation was written, or reused for an unmoved head; its path is the last stdout line |
| 1 | `failed` | no explanation: the agent is missing, was at capacity three times, crashed, timed out or was stopped, its answer was empty or missing (front matter alone counts as empty), the file could not be written, or the branch moved while starting; also when `gh` could not read the pull request or origin could not be read. No file is written or reported |
| 2 | `usage` | no `--pr`, a `--pr` that is not a positive number, an option without its value, or an unknown argument |
| 6 | `refused` | nothing was spawned: `gh` is not found, the `--spec` file is not readable text of at most 64 KiB, the `--out` folder does not exist or `--out` is a folder, the pull request is not open, comes from a fork or has a branch name Workbench will not pass to git, origin no longer has the branch, or another `pr-review --pr` or `explain-pr` holds the project |

These are the same as `pr-review --pr` for the same input, except that an explanation has no verdict, so there is no
exit 15, and an unmoved head is reused (exit 0) where `pr-review --pr` refuses it.
