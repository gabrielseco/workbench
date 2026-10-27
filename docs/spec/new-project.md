# `workbench new` and the global config

`workbench new` makes a project; it never starts Claude or a thread. It runs `git` and file copies, then
stops and says what to do next. From there everything is an ordinary thread in an ordinary project.

```
workbench new <name|path> [--in <dir>] [--seed <path>]... [--nested]
```

## What it creates

1. `<parent>/<name>`: a git repository on `main` with one empty commit (`chore: start the project`).
2. With `--seed`, each path copied (never linked) to `vendor/<basename>/` and committed as a second commit.
   `.git` and `.workbench` inside a seed are not copied. A seed is bounded: 10,000 files, 100 MB.
3. `.workbench/` in `.git/info/exclude`, and `.workbench/config.toml` from the same template as `init`, with
   `claude_path` filled in, and an `[agents.run]` table with its `model`, when the global config sets them.

Claude cannot read outside a thread's worktree (the S3 spikes), which is why seeds are copied in.

## Where

Resolved in this order; the first that applies wins, and there is no fallback to the current directory:

1. A path argument (`~/work/kit`, `./kit`, `/abs/kit`): the parent is its directory, the name its last part.
2. `--in <dir>` with a bare name.
3. `projects_dir` from the global config.

With none of them, `new` refuses (exit 2) and says where `projects_dir` goes. A path together with `--in`
uses the path and says on stderr that `--in` was ignored.

## Refusals

All before anything is written, and nothing is left behind on a later failure (directories `new` made are
removed; a directory that was already there is emptied of what `new` wrote).

| Case | Exit |
|---|---|
| Name is not one path component of `[A-Za-z0-9._-]` starting with a letter or digit, or has `..`, a trailing `.` or `.git` | 2 |
| Seed is a symlink or contains one; a seed or something in it cannot be read; two seeds share a basename; a seed is over the bounds; a seed and the new project contain one another | 2 |
| A seed does not exist | 7 |
| The target exists and is not an empty directory, or is a symbolic link | 6 |
| The parent is inside another git repository (name it in the message) and `--nested` was not given | 6 |
| `git` fails (no `user.name`/`user.email`, say) | 1 |

## Global config

`~/.workbench/config.toml`, next to where each project keeps its own `.workbench/`. Optional. If `~` is
itself a git repository (a dotfiles setup), that directory is also the repository's project directory, so
the two share it; the global file is only ever read by `new`, `open` (its `editor`) and `doctor` (to show that `editor`).

```toml
projects_dir = "~/code"   # absolute, or starting with ~/
claude_path  = "claude"   # written into new projects' config
editor       = "cursor"   # `workbench open` when neither --editor nor the project names one

[agents.run]
model = "opus"            # written into new projects' config as their [agents.run] model
```

Only these three keys and `[agents.run]` with only `model`. Anything else (including `check_command`, `setup_command`,
`[tools]`, another table or another key in `[agents.run]`) is an `invalid-config` error naming the file and the key,
because those depend on the stack and belong to the project. A root `model`, which this file used to take, is refused
with a message that says it is now `model` in `[agents.run]`. A run reads the project's own config, so editing the global file never changes an existing project;
`editor` is a personal setting that only `open` uses (see `goal-file.md`, "Tool permissions").

## No remote

A new project has no `origin`. `review` and `accept` work. `ship` stops before pushing, exit 6, with
"this repository has no remote named origin. Add one with `git remote add origin <url>`" (or
`gh repo create --source . --push`).
