import Foundation

/// The text of `workbench help`. Each command's own help is cut from it (`Help`), so it is written once.
let workbenchUsage = """
    usage: workbench <command>

    setup
      new <name|path> [--in <dir>] [--seed <path>]... [--nested]
                                 create a project: git repo on main with one empty commit, --seed copies into
                                 vendor/, .workbench/config.toml. Location: a path, else --in, else projects_dir
                                 in ~/.workbench/config.toml (also claude_path, [agents.run] model); refuses a
                                 non-empty target and a place inside another repo unless --nested
      init                       write .workbench/config.toml
      config                     show the resolved config and the command a turn would run
      doctor [--base <branch>] [--editor <name-or-command>] [--json]
                                 run the declared setup and check in a throwaway worktree; changes nothing;
                                 works before goal new and after goal approve, refused only while a run is live;
                                 base without --base: the default branch (origin/HEAD, else main, else master,
                                 else the checked-out branch); prints the editor `open` would use, never starts it

    one thread at a time
      goal new <name>            start a thread with a draft goal to fill in   [--base <branch>]
                                 base without --base: the default branch, as for doctor; printed as base:
                                 --from <goal-file> copies its request, criteria and out of scope into the draft,
                                 and its budget_usd, turn_timeout_min, model and quick; prints the front matter it ignored
                                 --update <branch> continues that branch of origin (ship pushes to it and records its PR)
                                 --quick "<text>" writes a quick goal: the text as its request, `quick: true`, no
                                 criteria (so no judge and no verifier); no agent runs
      goal draft <name> --request "<text>" | --request-file <path>  [--base <branch>] [--replace]
                                 have the goal agent ([agents.goal]) draft the goal from a rough request, read-only and
                                 bounded (300 s; $0.50 on Claude; Codex has no dollar cap, allow_unpriced = false
                                 refuses it); creates a draft
                                 thread, approves nothing, runs nothing; a failed draft leaves nothing behind
                                 --replace: <name> is an existing thread (default: the active one); its title, request,
                                 criteria and out of scope are redrafted and an approved goal returns to draft
                                 refused (exit 6) with no [agents.goal]: write the goal by hand with goal new
      goal approve [id]          approve the goal; any later edit returns it to draft
                                 refused while a proof names a command a run cannot execute
                                 (--allow-unrunnable-proofs to approve anyway; also on run, send-back)
      run                        run Claude on the approved goal in a worktree [--feedback "<text>"] [--no-plan]
                                 (local edits in your checkout are left out; --allow-dirty is ignored)
      send-back "<note>" [--budget <usd>]  next turn with your note and the failed check's output
      stop                       ask the running turn to stop cleanly
      log [-f] [-v] [--seq <n>] [--transcript [--turn <n>]]  what happened; -f follows, -v also shows each check's start,
                                 --seq one event in full, --transcript what the agent printed, as stored (raw)
      status [id] [--all] [--fetch]  where the thread stands; --all: one line per thread; --fetch: ask origin if the base moved
      review [id] [--patch <path>] [--fetch]  the goal's criteria, the diff, the check and denied tools; changes nothing
      next [id]                  what is still due on the thread, from its log: the judge, each review stage that applies to the
                                 change, then accept or ship; the first line is the next step; runs nothing, blocks nothing
      open [id] [--editor <name-or-command>] [--print] [--goal | --diff]
                                 open the thread's worktree in an editor to read what the run changed (--goal: its
                                 goal file instead, which a draft has before any run; --diff: a folder where the
                                 changes are uncommitted work, so the editor lists every changed file): cursor, code,
                                 zed, subl, windsurf or one plain command (given the path last); from --editor, else
                                 `editor` in .workbench/config.toml, else in ~/.workbench/config.toml; never $EDITOR;
                                 --print prints only the path and starts nothing; changes nothing
      grant [id]                 the commands a run was denied, numbered, rated safe / caution / unsafe, with what each
                                 would allow; changes nothing
      grant [id] <n> --once|--thread|--never  decide one: allow it for the next turn, for every later turn of this
                                 thread, or never (stop offering it). 2.1 is the first part of a compound, which is
                                 never granted whole. unsafe needs --allow-dangerous and is once only. A [tools]
                                 denied entry still wins. Written to the log, not to the config.
      judge [id] [--again] [--model <name>] [--budget <usd>]
                                 ask a second, read-only Claude run whether the check, the verifier, its
                                 screenshots and the diff show each criterion holds; advisory, shown by review
                                 beside your own checks, never changes accept or ship; once per turn unless --again
      verifier [id] [--again]    run the project's [verifier] skill as its own Claude run: it builds and drives the app to
                                 the states the goal names, leaves the screenshots in the proof folder and reports per
                                 criterion; advisory, never a pass; once per turn unless --again
      plan [id] [--again] [--model <name>] [--budget <usd>]
                                 a read-only agent run ([agents.plan]: claude or codex) reads the repository
                                 at the base commit against the approved goal and writes the approach; saved
                                 under plans/ in the thread, once per approved goal unless --again; the next
                                 run puts it in the first prompt
      plan show [id]             the latest plan, who wrote it, what it cost and whether it fits the goal
      plan edit [id] [--apply | --from <file>]
                                 copy the plan to plans/draft.md to edit; --apply (or --from) makes the edit the plan
      pr-review --pr <n> [--spec <file>] [--again]
                                 the same review for a pull request no thread made (one written by hand): its own
                                 text is the goal, or the file; kept under .workbench/reviews/, no rounds counted
      pr-review [id] [--again]   after ship: Codex reviews the pull request, read-only, in a throwaway checkout
                                 of its head; prints the findings and records the round (shown by review);
                                 at most max_rounds ([pr_review]) per pull request, --again does not lift that
                                 exit 0 clean, 15 findings to fix, 1 no verdict this time, 6 refused
      review-stage <name> [id] [--again]
                                 the same for the stage <name> of review.stages (pr-review is `pr-review`), with its
                                 own rounds; a stage whose applies_to matches no changed path is skipped (exit 0)
      accept [id] [-m <msg>] [--yes]  commit the work on its branch and end the thread; no push; -m is used only
                                 when accept commits (work already committed keeps its messages)
      ship [id] [--yes] [--no-describe] [--refresh-description] [--no-screenshots|--screenshots] [--keep-worktree]
           [--watch|-w [--timeout <min>] [--interval <s>]] [--review-loop]
                                 push the accepted branch and open its pull request; asks first, after
                                 showing the title and body (written by a read-only turn with no tools, on
                                 [agents.ship]'s provider, from the goal, diff and check; --no-describe uses
                                 the goal's text);
                                 for a thread from goal new --update it proposes edits to the PR's own
                                 title and sections and applies them only on a second yes, or with
                                 --refresh-description; --no-describe skips the proposal;
                                 screenshots the verifier left are put in the PR with `pr-shots`, if it
                                 is installed (--no-screenshots skips it; --screenshots tries again for a shipped thread);
                                 --watch then follows the CI checks (read-only);
                                 --review-loop then has Codex review the pull request and, for each finding round,
                                 starts a follow-up thread on the same branch, runs it and its check, asks before
                                 pushing it (--yes skips that) and reviews again, up to max_rounds; never merges
                                 exit 10 not accepted, 11 already shipped (URL printed), 12 push rejected,
                                 13 a check failed, 14 no result in time,
                                 3 stopped while describing (nothing pushed)
      clean [--yes] [--closed]   remove the worktree and local branch of shipped threads whose pull request is
                                 merged (or closed, with --closed); a dry run unless --yes
      discard [id] [--yes]       throw the work away: delete the worktree and branch, keep the log
      abandon [--force]          end the thread without accepting its work; uncommitted changes in its worktree
                             are saved as abandon.patch in the thread folder first, the branch is kept

    scheduled tasks
      task list                  the tasks in .workbench/tasks/<name>/task.md: when each is due, what it may do (fix:
                                 report or pr), whether its approval still matches the file and its pending script,
                                 the next due time and how the last run ended
      task run <name>            run the task now: take its next units, do the work in a thread, and with fix: pr accept
                                 it when the check passed and open the pull request; fix: report only lists the units;
                                 exit 6 when skipped (a thread is active, the approval is stale, or max_open of its
                                 pull requests are still open), 1 failed, 5 over budget
      task tick                  run the tasks whose time has come, one after the other; what a timer calls
      task timer install [--every <5m..1h>] [--pull-main] | status | remove
                                 make the machine run the tasks: install writes and loads the launchd agent that runs `task tick`
                                 for this project (every 15 minutes by default) and prints the one `sudo pmset repeat` wake line
                                 computed from the tasks' times, which you run yourself (Workbench never runs sudo); status says
                                 whether it will run tonight (agent loaded, last tick, wake schedule, power, FileVault, stale
                                 tasks);
                                 remove unloads it and deletes its files. --pull-main fast-forwards a clean main before each tick.
                                 macOS; elsewhere it prints the crontab line. exit 1 from status when something is broken
      task log <name> [--all]    what the task's last run did: outcome, the full reason, setup, check and its output, the
                                 agent's last message; --all lists every run in one line. exit 7 for no such task
      task new <name> [--include <file>] [--input <path>]...
                                 start a task: .workbench/tasks/<name>/task.md with every setting explained and fix: report, and
                                 a pending.sh that lists nothing; no agent runs. approve refuses it until its instructions
                                 no longer say TODO(workbench). exit 2 for a bad name or path, 6 when the task exists
      task approve <name>        record that the task, as it is now, may run unattended; editing the file or its
                                 pending script revokes it. With fix: pr the task accepts its own work when the check
                                 and the verifier pass and opens the pull request; it never merges

      --json on status, review, log, grant and doctor; exit codes: docs/spec/exit-codes.md

      version
    """
