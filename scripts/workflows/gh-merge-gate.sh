#!/bin/bash
# Merge gate for a pocketpi workflow (shell stage).
#
#   gh-merge-gate.sh REVIEW_WORKFLOW AUTHOR [BASE] [METHOD]
#
# For each open, non-draft PR by AUTHOR against BASE:
#   - no pocketpi review of its current head commit yet -> start one
#     (REVIEW_WORKFLOW with inputs pr+commit; pocketpi skips duplicates)
#   - reviewed "Verdict: pass" and GitHub says CLEAN (all checks green,
#     no conflicts) -> merge it, pinned to that exact commit
#   - otherwise -> leave it and say why
# DRY_RUN=1 prints the plan without acting.
# Exits 78 ("nothing to do") when nothing was merged, so polling runs that
# change nothing are not kept in pocketpi's history.
set -euo pipefail
review_wf=${1:?review workflow id}
author=${2:?PR author}
base=${3:-main}
method=${4:-merge}
api=${POCKETPI_URL:-http://127.0.0.1:3457}

# Data goes through temp files, not argv: the run history easily exceeds
# Linux's 128 KiB per-argument limit (exec then fails with exit 126).
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
gh pr list --state open --base "$base" --author "$author" --limit 50 \
  --json number,title,isDraft,mergeStateStatus,headRefOid >"$tmp/prs.json"
curl -sf "$api/api/runs?workflow=$review_wf" >"$tmp/runs.json"

plan=$(python3 -I - "$tmp/prs.json" "$tmp/runs.json" <<'EOF'
import json, re, sys
prs = json.load(open(sys.argv[1]))
runs = json.load(open(sys.argv[2]))["runs"]
PASS = re.compile(r"verdict:\W*pass", re.I)
BLOCK = re.compile(r"verdict:\W*(changes|block|fail|request)", re.I)
for pr in prs:
    n, sha, title = str(pr["number"]), pr["headRefOid"], pr["title"][:60]
    if pr["isDraft"]:
        print(f"wait {n} {sha} draft"); continue
    mine = [r for r in runs if r["inputs"].get("pr") == n and r["inputs"].get("commit") == sha]
    verdict = None
    for r in mine:
        for s in r["stages"]:
            out = s.get("output") or ""
            if PASS.search(out): verdict = "pass"
            elif BLOCK.search(out): verdict = verdict or "block"
    if not mine:
        print(f"review {n} {sha} {title}")
    elif verdict == "block":
        print(f"wait {n} {sha} review asked for changes")
    elif verdict != "pass":
        print(f"wait {n} {sha} review not finished")
    elif pr["mergeStateStatus"] != "CLEAN":
        print(f"wait {n} {sha} GitHub says {pr['mergeStateStatus'].lower()} (checks not all green, or conflicts)")
    else:
        print(f"merge {n} {sha} {title}")
EOF
)

# Stacked PRs: merging a PR whose branch contains another open PR's commits
# lands that code too (GitHub then marks the other PR merged). So a PR that
# contains the head of any PR not cleared to merge waits as well.
# (2026-11-07: #92 carried #90/#91, whose reviews had asked for changes.)
refspecs=$(awk 'NF {printf "+refs/pull/%s/head:refs/pocketpi-gate/pr/%s ", $2, $2}' <<< "$plan")
if [ -n "$refspecs" ]; then
  # shellcheck disable=SC2086
  git fetch -q origin $refspecs
  blocked=$(awk '$1 != "merge" && NF {print $2, $3}' <<< "$plan")
  plan=$(while read -r action n sha rest; do
    [ -z "${action:-}" ] && continue
    if [ "$action" = merge ]; then
      while read -r on osha; do
        [ -z "${on:-}" ] && continue
        if git merge-base --is-ancestor "$osha" "$sha" 2>/dev/null; then
          action=wait; rest="contains #$on, which isn't cleared to merge"; break
        fi
      done <<< "$blocked"
    fi
    echo "$action $n $sha $rest"
  done <<< "$plan")
fi

if [ -n "${DRY_RUN:-}" ]; then echo "$plan"; exit 0; fi

merged=0
while read -r action n sha rest; do
  [ -z "${action:-}" ] && continue
  case "$action" in
    review)
      code=$(curl -s -o /dev/null -w '%{http_code}' -H content-type:application/json -H x-pocketpi:1 \
        -d "{\"inputs\":{\"pr\":\"$n\",\"commit\":\"$sha\"},\"trigger\":\"merge-gate\"}" "$api/api/workflows/$review_wf/run")
      echo "#$n: no review of ${sha:0:7} yet, started one (HTTP $code)" ;;
    merge)
      if gh pr merge "$n" "--$method" --delete-branch --match-head-commit "$sha" >/dev/null; then
        echo "#$n: merged ${sha:0:7} ($rest)"; merged=$((merged + 1))
      else
        echo "#$n: merge refused by GitHub"
      fi ;;
    wait) echo "#$n: waiting: $rest" ;;
  esac
done <<< "$plan"

if [ "$merged" = 0 ]; then
  echo "nothing merged"
  exit 78
fi
echo "merged $merged PR(s)"
