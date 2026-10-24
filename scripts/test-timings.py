#!/usr/bin/env python3
"""Turn a `swift test` log into timings: JSON for tools, a markdown table for people and the CI job summary.

    scripts/test-timings.py <test.log> [--json out.json] [--markdown out.md] [--top N]

Reads Swift Testing result lines ("✔ Test foo() passed after 0.123 seconds.", the same for "Suite" and "✘ ... failed").
Exits 0 even when tests failed: it reports, the Test step decides the build.
"""
import argparse
import json
import re
import sys

LINE = re.compile(r"^[✔✘] (Test|Suite) (.+?) (passed|failed) after ([0-9.]+) seconds")


def parse(path):
    rows = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = LINE.match(line)
            if m:
                kind, name, result, secs = m.groups()
                rows.append({"kind": kind.lower(), "name": name.strip('"'), "result": result, "seconds": float(secs)})
    return rows


def markdown(rows, top):
    tests = [r for r in rows if r["kind"] == "test"]
    suites = [r for r in rows if r["kind"] == "suite"]
    failed = [r for r in rows if r["result"] == "failed"]
    out = [f"### Test timings\n\n{len(tests)} tests in {len(suites)} suites, {len(failed)} failed. "
           f"Suite times overlap with test times and with each other when suites run in parallel.\n"]
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
    args = ap.parse_args()
    rows = parse(args.log)
    if not rows:
        print(f"error: no Swift Testing result lines in {args.log}", file=sys.stderr)
        return 1
    if args.json:
        with open(args.json, "w") as f:
            json.dump(sorted(rows, key=lambda r: -r["seconds"]), f, indent=1)
    md = markdown(rows, args.top)
    if args.markdown:
        with open(args.markdown, "w") as f:
            f.write(md)
    else:
        print(md)
    return 0


sys.exit(main())
