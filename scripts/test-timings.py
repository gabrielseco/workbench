#!/usr/bin/env python3
"""Turn a `swift test` log into timings: JSON for tools, a markdown table for people and the CI job summary.

    scripts/test-timings.py <test.log> [--json out.json] [--markdown out.md] [--top N] [--serial]

Reads Swift Testing result lines ("✔ Test foo() passed after 0.123 seconds.", the same for "Suite" and "✘ ... failed").
Exits 0 even when tests failed: it reports, the Test step decides the build.
"""
import argparse
import json
import re
import sys

# "Test run with N tests ..." is the whole run, not a test: counting it would double the total.
LINE = re.compile(r"^[✔✘] (Test|Suite) (?!run with )(.+?) (passed|failed) after ([0-9.]+) seconds")


def parse(path):
    rows = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = LINE.match(line)
            if m:
                kind, name, result, secs = m.groups()
                rows.append({"kind": kind.lower(), "name": name.strip('"'), "result": result, "seconds": float(secs)})
    return rows


def heavy_share(tests, over=1.0):
    """How many tests take more than `over` seconds, and what share of all test time they hold."""
    total = sum(r["seconds"] for r in tests)
    heavy = [r for r in tests if r["seconds"] > over]
    held = sum(r["seconds"] for r in heavy)
    return len(heavy), (held / total * 100 if total else 0.0), total


def markdown(rows, top, serial=False):
    tests = [r for r in rows if r["kind"] == "test"]
    suites = [r for r in rows if r["kind"] == "suite"]
    failed = [r for r in rows if r["result"] == "failed"]
    heavy, share, total = heavy_share(tests)
    note = ("Run with --no-parallel: each time is the cost of that test alone." if serial else
            "Parallel run: each time includes the wait for a ProcessGate permit, so the ranking shows queueing, "
            "not cost. Use scripts/test-profile.sh for costs.")
    out = [f"### Test timings\n\n{len(tests)} tests in {len(suites)} suites, {len(failed)} failed. "
           f"{heavy} tests over 1 s hold {share:.0f}% of the {total:.0f} s summed test time.\n\n{note}\n"]
    if failed:
        out.append("**Failed**\n\n" + "\n".join(f"- {r['kind']} `{r['name']}` ({r['seconds']:.2f}s)" for r in failed) + "\n")
    for title, group in (("Slowest suites", suites), ("Slowest tests", tests)):
        out.append(f"**{title}**\n\n| seconds | name |\n|---:|---|")
        for r in sorted(group, key=lambda r: -r["seconds"])[:top]:
            out.append(f"| {r['seconds']:.2f} | `{r['name']}` |")
        out.append("")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--json")
    ap.add_argument("--markdown")
    ap.add_argument("--top", type=int, default=20)
    ap.add_argument("--serial", action="store_true", help="the log came from --no-parallel, so times are real costs")
    args = ap.parse_args()
    rows = parse(args.log)
    if not rows:
        print(f"error: no Swift Testing result lines in {args.log}", file=sys.stderr)
        return 1
    if args.json:
        with open(args.json, "w") as f:
            json.dump(sorted(rows, key=lambda r: -r["seconds"]), f, indent=1)
    md = markdown(rows, args.top, args.serial)
    if args.markdown:
        with open(args.markdown, "w") as f:
            f.write(md)
    else:
        print(md)
    return 0


sys.exit(main())
