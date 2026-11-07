#!/bin/bash
# First stage of a review-and-fix PR workflow (shell stage, worktree run).
#
#   pr-fetch.sh PR [COMMIT]
#
# Points this run's worktree at the PR's current head and saves its diff to
# /tmp/pocketpi-$POCKETPI_RUN_ID.diff. If COMMIT is given and the PR has moved
# on since, exits 78: the newer commit gets its own run.
set -euo pipefail
pr=${1:?PR number}
want=${2:-}
[[ $pr =~ ^[0-9]+$ ]] || { echo "bad PR number: $pr"; exit 1; }

IFS=$'\t' read -r head branch cross author base title < <(gh pr view "$pr" \
  --json headRefOid,headRefName,isCrossRepository,author,baseRefName,title \
  -q '[.headRefOid, .headRefName, .isCrossRepository, .author.login, .baseRefName, .title] | @tsv')

if [ -n "$want" ] && [ "$want" != "$head" ]; then
  echo "superseded: PR #$pr is now at ${head:0:7}, not ${want:0:7}"
  exit 78
fi

git fetch -q origin "refs/pull/$pr/head" "refs/heads/$base:refs/remotes/origin/$base"
git reset -q --hard "$head"
git diff --no-color "origin/$base...HEAD" >"/tmp/pocketpi-$POCKETPI_RUN_ID.diff"

echo "PR #$pr: $title"
echo "Branch: $branch (by $author, head ${head:0:7}, base $base)"
[ "$cross" = true ] && echo "From a fork: can't push fixes to it."
echo "Full diff: /tmp/pocketpi-$POCKETPI_RUN_ID.diff ($(wc -l <"/tmp/pocketpi-$POCKETPI_RUN_ID.diff") lines)"
echo "Files changed:"
git diff --name-only "origin/$base...HEAD"
