#!/bin/bash
# Last stage of a review-and-fix PR workflow (shell stage).
#
#   pr-push.sh PR BASE_COMMIT
#
# Pushes the fix commits onto the PR's branch, only if the PR is still at the
# commit that was reviewed (never force-pushes). The new head then gets its
# own review, and the merge gate merges it once that one passes. Afterwards
# the worktree goes back to BASE_COMMIT so pocketpi removes it.
set -euo pipefail
pr=${1:?PR number}
base_commit=${2:?base commit}

IFS=$'\t' read -r head branch < <(gh pr view "$pr" --json headRefOid,headRefName -q '[.headRefOid, .headRefName] | @tsv')
# The fix commits sit on top of the head we reviewed, so the PR's current
# head must still be an ancestor of HEAD; if not, someone pushed meanwhile.
if ! git merge-base --is-ancestor "$head" HEAD; then
  echo "PR #$pr moved on to ${head:0:7} while fixing: not pushed, the new commit gets its own review."
  git reset -q --hard "$base_commit"
  exit 79
fi
n=$(git rev-list --count "$head..HEAD")
if [ "$n" = 0 ]; then
  echo "The fix stage made no commits: nothing to push."
  exit 1
fi
git log --format='  %h %s' "$head..HEAD"
git push -q origin "HEAD:refs/heads/$branch"
git reset -q --hard "$base_commit"
echo "pushed $n fix commit(s) to $branch (#$pr)"
