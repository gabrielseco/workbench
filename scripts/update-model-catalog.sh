#!/bin/bash
# Rewrites the Codex line of Sources/WorkbenchCore/Config/ModelCatalog.swift from the installed Codex CLI (`codex debug models`: the
# models it lists as visible, in its own order), so the Agents card's menu follows the CLI. Claude's line is aliases and is edited by hand.
#   scripts/update-model-catalog.sh          rewrite the file and show the diff
#   scripts/update-model-catalog.sh --check  change nothing; exit 1 when the file differs from the CLI
set -u
cd "$(dirname "$0")/.."
file=Sources/WorkbenchCore/Config/ModelCatalog.swift
command -v codex >/dev/null || { echo "codex is not installed" >&2; exit 2; }
names=$(codex debug models 2>/dev/null | python3 -I -c '
import json, re, sys
data = json.load(sys.stdin)
models = data["models"] if isinstance(data, dict) else data
print(" ".join(m["slug"] for m in models if m.get("visibility") == "list" and re.fullmatch(r"[A-Za-z0-9._:/@\[\]-]{1,100}", m["slug"])))
') || { echo "could not read the Codex model catalog" >&2; exit 2; }
[ -n "$names" ] || { echo "codex listed no models: not changing the catalog" >&2; exit 2; }
line="        .codex: [$(for n in $names; do printf '"%s", ' "$n"; done | sed 's/, $//')],"
if grep -qxF "$line" "$file"; then echo "ModelCatalog is up to date ($(echo "$names" | wc -w | tr -d ' ') Codex models)"; exit 0; fi
[ "${1:-}" = "--check" ] && { echo "ModelCatalog differs from codex debug models; run scripts/update-model-catalog.sh" >&2; exit 1; }
python3 -I - "$file" "$line" <<'PY'
import sys
path, line = sys.argv[1], sys.argv[2]
text = open(path).read().split("\n")
for i, l in enumerate(text):
    if l.strip().startswith(".codex:"):
        text[i] = line
        break
else:
    sys.exit("no .codex line in " + path)
open(path, "w").write("\n".join(text))
PY
git --no-pager diff --stat -- "$file"
