#!/usr/bin/env python3
"""Gives every tracked file the time of the commit that last touched it.

A fresh checkout gives every file a new modification time, and SwiftPM treats a newer file as changed, so it rebuilds everything and a
restored .build is worth nothing. With these times only what a change touched looks new. Needs the whole history (fetch-depth: 0)."""
import os
import subprocess

git = ["git", "-c", "safe.directory=*"]
log = subprocess.run(git + ["log", "--name-only", "--pretty=format:#%ct", "--no-renames"],
                     capture_output=True, text=True, check=True).stdout
seen, stamp = {}, None
for line in log.splitlines():
    if line.startswith("#"):
        stamp = int(line[1:])
    elif line and line not in seen:
        seen[line] = stamp
restored = 0
for path in subprocess.run(git + ["ls-files"], capture_output=True, text=True, check=True).stdout.splitlines():
    if path in seen and os.path.exists(path):
        os.utime(path, (seen[path], seen[path]))
        restored += 1
print("modification times restored for", restored, "files")
assert restored > 100, "the checkout is too shallow, or git refused it"
