#!/usr/bin/env python3
"""Soak with the real `claude`: N tiny goals through the real CLI, each a new thread, checked afterwards.

    scripts/soak-real.py [--runs 10] [--keep]

Needs a built `workbench` (swift build), `claude` on PATH logged in, and git. It makes a throwaway repo in
a temp directory, uses the cheap model and safe mode, and stops at the first run that breaks an invariant.
It spends subscription usage: about a cent of list price per run with safe mode.
"""
import argparse, json, os, shutil, subprocess, sys, tempfile, time, uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WB = os.path.join(ROOT, ".build", "debug", "workbench")

GOALS = [
    ("add-farewell", "Add a function `farewell(name)` to `greeter.py` returning `\"Goodbye, <name>!\"`, with a unit test.", 'farewell("Ada") returns "Goodbye, Ada!"'),
    ("add-shout", "Add a function `shout(name)` to `greeter.py` returning the greeting from `greet()` in upper case, with a unit test.", 'shout("Ada") returns "HELLO, ADA!"'),
    ("add-whisper", "Add a function `whisper(name)` to `greeter.py` returning the greeting from `greet()` in lower case, with a unit test.", 'whisper("Ada") returns "hello, ada!"'),
    ("add-polite", "Add a function `polite(name)` to `greeter.py` returning `\"Good day, <name>.\"`, with a unit test.", 'polite("Ada") returns "Good day, Ada."'),
    ("add-count", "Add a function `letters(name)` to `greeter.py` returning the number of letters in name, with a unit test.", 'letters("Ada") returns 3'),
]


def sh(*args, cwd, env=None, check=True):
    p = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True)
    if check and p.returncode != 0:
        raise SystemExit(f"FAILED: {' '.join(args)}\n{p.stdout}\n{p.stderr}")
    return p


def fds_of(pid):
    r = subprocess.run(["lsof", "-p", str(pid)], capture_output=True, text=True)
    return len(r.stdout.splitlines())


def make_repo(path):
    os.makedirs(os.path.join(path, "scripts"))
    open(os.path.join(path, "greeter.py"), "w").write('def greet(name):\n    """Return a greeting."""\n    return f"Hello, {name}!"\n')
    open(os.path.join(path, "test_greeter.py"), "w").write(
        "import unittest\nfrom greeter import greet\n\n\nclass T(unittest.TestCase):\n"
        "    def test_greet(self):\n        self.assertEqual(greet('Ada'), 'Hello, Ada!')\n\n\nif __name__ == '__main__':\n    unittest.main()\n")
    p = os.path.join(path, "scripts", "check.sh")
    open(p, "w").write('#!/bin/sh\ncd "$(dirname "$0")/.." && python3 -B -m unittest 2>&1\n')
    os.chmod(p, 0o755)
    g = ["git", "-c", "user.email=t@example.com", "-c", "user.name=t"]
    sh("git", "init", "-q", "-b", "main", cwd=path)
    open(os.path.join(path, ".gitignore"), "w").write("__pycache__/\n")
    sh("git", "add", "-A", cwd=path)
    sh(*g, "commit", "-qm", "initial", cwd=path)


def events(repo, thread):
    out = []
    with open(os.path.join(repo, ".workbench", "threads", thread, "events.jsonl")) as f:
        for line in f:
            out.append(json.loads(line))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=10)
    ap.add_argument("--keep", action="store_true", help="keep the temp repo")
    args = ap.parse_args()
    if not os.path.exists(WB):
        raise SystemExit(f"build first: swift build  (missing {WB})")

    repo = tempfile.mkdtemp(prefix="wb-soak-")
    make_repo(repo)
    env = dict(os.environ)
    sh(WB, "init", cwd=repo, env=env)
    cfg = os.path.join(repo, ".workbench", "config.toml")
    text = open(cfg).read()
    text = text.replace('# check_command = "scripts/check.sh"', 'check_command = "scripts/check.sh"')
    text = text.replace("# default_budget_usd = 5.00", "default_budget_usd = 1.00")
    text += '\n[agents.run]\nmodel = "haiku"\n'
    open(cfg, "w").write(text)

    results, total_cost, total_secs = {}, 0.0, 0.0
    started = time.time()
    for i in range(args.runs):
        name, request, criterion = GOALS[i % len(GOALS)]
        name = f"{name}-{i}"
        sh(WB, "goal", "new", name, "--base", "main", cwd=repo, env=env)
        thread = sorted(os.listdir(os.path.join(repo, ".workbench", "threads")))[-1]
        # the newest thread is the one just made
        thread = [t for t in os.listdir(os.path.join(repo, ".workbench", "threads")) if t.endswith(name)][0]
        gp = os.path.join(repo, ".workbench", "threads", thread, "goal.md")
        g = open(gp).read()
        g = g.replace("TODO(workbench): say what should change, in a few sentences.", request)
        g = g.replace("TODO(workbench): something that can be checked.", criterion + ".")
        g = g.replace("TODO(workbench): how it will be shown (a test, a command, a screenshot).", "a new test passes under `scripts/check.sh`")
        g = g.replace("- TODO(workbench): what must not change.", "- Changing `greet`.")
        g = g.replace("turn_timeout_min: 30", "turn_timeout_min: 10")
        open(gp, "w").write(g)
        sh(WB, "goal", "approve", cwd=repo, env=env)

        t0 = time.time()
        run = sh(WB, "run", cwd=repo, env=env, check=False)
        secs = time.time() - t0
        ev = events(repo, thread)
        starts = [e for e in ev if e["kind"] == "turn.started"]
        ends = [e for e in ev if e["kind"] == "turn.ended"]
        # invariants
        problems = []
        if [e["seq"] for e in ev] != list(range(1, len(ev) + 1)):
            problems.append("seq has a gap")
        if len(starts) != len(ends) or len(ends) != 1:
            problems.append(f"{len(starts)} started / {len(ends)} ended")
        if os.path.exists(os.path.join(repo, ".workbench", "threads", thread, "runner.json")):
            problems.append("runner.json left behind")
        result = ends[0]["data"]["result"] if ends else "none"
        cost = ends[0]["data"].get("cost_usd", 0) if ends else 0
        results[result] = results.get(result, 0) + 1
        total_cost += cost
        total_secs += secs
        print(f"run {i + 1:2d}/{args.runs}  {result:10s} {secs:5.1f}s  ${cost:.4f}  {name}"
              + (f"  PROBLEMS: {problems}" if problems else ""), flush=True)
        if problems:
            raise SystemExit(1)

        # the work: a commit on the thread's branch, main untouched, check passes there
        wt = os.path.join(repo, ".workbench", "worktrees", thread)
        if result == "succeeded":
            ahead = sh("git", "rev-list", "--count", f"main..workbench/{thread}", cwd=repo).stdout.strip()
            chk = sh("scripts/check.sh", cwd=wt, check=False)
            if ahead == "0" or chk.returncode != 0:
                print(f"   work not as claimed: {ahead} commits ahead, check exit {chk.returncode}")
                raise SystemExit(1)
        sh(WB, "abandon", "--force", cwd=repo, env=env)

    # nothing left behind
    left = subprocess.run(["pgrep", "-fl", repo], capture_output=True, text=True).stdout.strip()
    wts = sh("git", "worktree", "list", "--porcelain", cwd=repo).stdout.count("worktree ")
    main_log = sh("git", "log", "--oneline", "main", cwd=repo).stdout.strip().splitlines()
    print()
    print(f"results: {results}")
    print(f"list-price cost ${total_cost:.4f}  wall {time.time() - started:.0f}s  (runs {total_secs:.0f}s)")
    print(f"processes mentioning the repo: {left or 'none'}")
    print(f"worktrees registered: {wts} (1 = only the main checkout)")
    print(f"main commits: {len(main_log)} (1 = untouched)")
    ok = not left and wts == 1 and len(main_log) == 1 and results.get("succeeded", 0) == args.runs
    if not args.keep:
        shutil.rmtree(repo, ignore_errors=True)
    else:
        print("kept:", repo)
    print("SOAK-REAL", "OK" if ok else "NOT OK")
    sys.exit(0 if ok else 1)


main()
