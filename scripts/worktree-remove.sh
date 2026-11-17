#!/usr/bin/env bash
# Retire a worktree that task worktree:add created, once its pull request has
# merged: removes <root>/<repo>/<slug> and deletes its local branch.
#
# Wired in Taskfile.yml as `task worktree:remove -- <slug>`.
#
# Pull requests merge by squash, so `git branch -d` never sees the branch as
# merged. The branch is deleted only when its remote branch is gone, which
# delete_branch_on_merge does after the merge; otherwise it is kept and named.
# A worktree with uncommitted changes is not removed (git worktree remove
# refuses it), so nothing unsaved is lost.
set -euo pipefail

slug=${1-}
[ -n "$slug" ] && [ "$#" -eq 1 ] || { echo "Usage: task worktree:remove -- <slug>" >&2; exit 2; }
root=${NOLTE_WORKTREE_ROOT:-$HOME/repos/.worktrees}
repo=$(basename -s .git "$(git remote get-url origin)")
path=$root/$repo/$slug
[ -d "$path" ] || { echo "no worktree at $path" >&2; exit 1; }
branch=$(git -C "$path" rev-parse --abbrev-ref HEAD)

git worktree remove "$path"
echo "removed the worktree $path"
git fetch --prune --quiet origin
if git ls-remote --exit-code --heads origin "$branch" >/dev/null; then
    echo "kept the branch $branch: it still exists on origin (not merged yet?)"
else
    git branch -D "$branch" >/dev/null
    echo "deleted the branch $branch (gone on origin)"
fi
