#!/bin/bash
# Release check for a pocketpi workflow (shell stage).
#
#   gh-release-check.sh [BASE] [RELEASE_WORKFLOW]
#
# Looks at origin/BASE (never the working copy): if there are commits since
# the last v* tag and the CHANGELOG's [Unreleased] section has entries, it
# prints the notes and, as the LAST line, the next version:
#   only ### Fixed / ### Security entries      -> patch (0.9.0 -> 0.9.1)
#   any ### Added / Changed / Deprecated        -> minor (0.9.0 -> 0.10.0)
#   ### Removed or "BREAKING" at 1.0 or later   -> major
# Exits 78 ("nothing to do") when there is nothing to release, or a release
# run is already in progress.
set -euo pipefail
base=${1:-main}
release_wf=${2:-release}

git fetch -q origin "$base" --tags
last=$(git describe --tags --abbrev=0 --match 'v[0-9]*' "origin/$base" 2>/dev/null || true)
if [ -n "$last" ]; then
  count=$(git rev-list --count "$last..origin/$base")
  if [ "$count" = 0 ]; then echo "nothing merged since $last"; exit 78; fi
fi
if [ -n "$(gh run list --workflow "$release_wf" --status in_progress --json databaseId -q '.[0].databaseId' 2>/dev/null)" ]; then
  echo "a release is already running"; exit 78
fi

changelog=$(mktemp); trap 'rm -f "$changelog"' EXIT
git show "origin/$base:CHANGELOG.md" > "$changelog"
python3 -I - "${last#v}" "$changelog" <<'EOF'
import re, sys
text = open(sys.argv[2]).read()
m = re.search(r"^## \[Unreleased\][^\n]*\n(.*?)(?=^## \[|\Z)", text, re.S | re.M)
notes = (m.group(1) if m else "").strip()
if not re.search(r"^\s*[-*] ", notes, re.M):
    print("commits since the last tag, but CHANGELOG [Unreleased] has no entries; not releasing")
    sys.exit(78)
last = sys.argv[1] or "0.0.0"
nums = re.match(r"(\d+)\.(\d+)\.(\d+)", last)
major, minor, patch = (int(x) for x in nums.groups()) if nums else (0, 0, 0)
heads = {h.lower() for h in re.findall(r"^###\s+(\w+)", notes, re.M)}
if major >= 1 and ("removed" in heads or "breaking" in notes.lower()):
    version = f"{major + 1}.0.0"
elif heads & {"added", "changed", "deprecated", "removed"}:
    version = f"{major}.{minor + 1}.0"
else:
    version = f"{major}.{minor}.{patch + 1}"
print(f"Since v{last}:\n\n{notes}\n")
print(version)
EOF
