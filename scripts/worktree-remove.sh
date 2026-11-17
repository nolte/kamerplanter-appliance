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
# The root as worktree-add.sh resolves it, a leading ~ included.
root="${NOLTE_WORKTREE_ROOT:-$HOME/repos/.worktrees}"
# shellcheck disable=SC2088 # matches a literal ~/ in the variable, expanded here
case "$root" in
    "~") root="$HOME" ;;
    "~/"*) root="$HOME/${root#\~/}" ;;
esac
repo=$(basename -s .git "$(git remote get-url origin)")
path=$root/$repo/$slug
[ -d "$path" ] || { echo "no worktree at $path" >&2; exit 1; }
branch=$(git -C "$path" symbolic-ref --quiet --short HEAD) ||
    { echo "$path is not on a branch (detached HEAD); remove it with git worktree remove" >&2; exit 1; }

git worktree remove "$path"
echo "removed the worktree $path"
# Exit status 2 alone means the branch is not on origin; anything else (a
# network or login error) keeps the branch, so no unmerged work is lost.
rc=0
git ls-remote --exit-code --heads origin "$branch" >/dev/null || rc=$?
case $rc in
    2)
        git branch -D "$branch" >/dev/null
        echo "deleted the branch $branch (gone on origin)"
        ;;
    0) echo "kept the branch $branch: it still exists on origin (not merged yet?)" ;;
    *) echo "kept the branch $branch: origin could not be asked (exit status $rc)" >&2 ;;
esac
