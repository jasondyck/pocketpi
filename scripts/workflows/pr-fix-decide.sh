#!/bin/bash
# Decides whether a review-and-fix PR workflow goes on to fix (shell stage).
#
#   pr-fix-decide.sh PR AUTHOR BASE_COMMIT [MAX_ROUNDS]
#
# Reads this run's "review" stage output from pocketpi:
#   Verdict: pass                -> exit 79 (done, nothing to fix)
#   changes requested, not ours  -> exit 79 (other author or fork: report only)
#   changes requested, MAX_ROUNDS fixes already pushed for this PR
#                                -> exit 1 (fail, so you get a notification)
#   changes requested otherwise  -> exit 0 (the fix stage runs)
# Before exit 79 the worktree goes back to BASE_COMMIT so pocketpi removes it.
set -euo pipefail
pr=${1:?PR number}
author=${2:?PR author}
base_commit=${3:?base commit}
max=${4:-2}
api=${POCKETPI_URL:-http://127.0.0.1:3457}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

done_here() { echo "$1"; git reset -q --hard "$base_commit"; exit 79; }

curl -sf "$api/api/runs/$POCKETPI_RUN_ID" >"$tmp/run.json"
curl -sf "$api/api/runs?workflow=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["run"]["workflow_id"])' "$tmp/run.json")" >"$tmp/runs.json"
gh pr view "$pr" --json author,isCrossRepository -q '[.author.login, .isCrossRepository] | @tsv' >"$tmp/pr.tsv"

read -r verdict rounds < <(python3 -I - "$tmp/run.json" "$tmp/runs.json" "$pr" <<'PY'
import json, re, sys
run = json.load(open(sys.argv[1]))["run"]
runs = json.load(open(sys.argv[2]))["runs"]
review = next((s.get("output") or "" for s in run["stages"] if s["id"] == "review"), "")
if re.search(r"verdict:\W*pass", review, re.I):
    v = "pass"
elif re.search(r"verdict:\W*(changes|block|fail|request)", review, re.I):
    v = "changes"
else:
    v = "none"
# fixes already pushed to this PR by earlier runs of this workflow
rounds = sum(
    1 for r in runs
    if r["inputs"].get("pr") == sys.argv[3]
    and any(s["id"] == "push" and s["status"] == "succeeded" and "pushed" in (s.get("summary") or "") for s in r["stages"])
)
print(v, rounds)
PY
)
IFS=$'\t' read -r pr_author cross <"$tmp/pr.tsv"

case "$verdict" in
  pass) done_here "Review passed: nothing to fix." ;;
  none) echo "The review has no Verdict line; can't decide."; exit 1 ;;
esac
if [ "$pr_author" != "$author" ] || [ "$cross" = true ]; then
  done_here "Review asked for changes, but #$pr is by $pr_author$([ "$cross" = true ] && echo ' from a fork'): not fixing it, left for you."
fi
if [ "$rounds" -ge "$max" ]; then
  echo "Review still asks for changes after $rounds fix round(s) on #$pr: over to you."
  exit 1
fi
echo "Review asked for changes: fixing (round $((rounds + 1)) of $max)."
