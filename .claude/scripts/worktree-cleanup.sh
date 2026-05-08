#!/usr/bin/env bash
set -euo pipefail

MAIN_NAME="specled_ex"

usage() {
    cat <<USAGE
Usage:
  $0 --name <worktree-name>    Clean a single worktree (basename of its directory)
  $0 --all                     Clean every worktree whose branch is fully merged
USAGE
    exit "${1:-1}"
}

mode=""
name=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)
            mode="single"
            name="${2:-}"
            [[ -z "$name" ]] && { echo "Error: --name requires a value." >&2; usage; }
            shift 2
            ;;
        --all)
            mode="all"
            shift
            ;;
        -h|--help)
            usage 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            ;;
    esac
done

[[ -z "$mode" ]] && usage

cleanup_file=$(mktemp)
trap 'rm -f "$cleanup_file"' EXIT

target_found=0

# Iterate via process substitution so we can update outer-scope state inside the loop.
while IFS=$'\t' read -r wpath branch; do
    wname=$(basename "$wpath")
    short_branch=${branch#refs/heads/}

    [[ "$short_branch" == "main" ]] && continue
    [[ "$wname" == "$MAIN_NAME" ]] && continue
    [[ "$mode" == "single" && "$wname" != "$name" ]] && continue
    [[ "$mode" == "single" ]] && target_found=1

    # Skip worktrees whose checkout directory has been removed (prunable). These
    # leave a stale entry in `git worktree list` until `git worktree prune` runs.
    if [[ ! -d "$wpath" ]]; then
        if [[ "$mode" == "single" ]]; then
            echo "Refusing to clean '$wname': checkout at $wpath is missing (prunable). Run 'git worktree prune'." >&2
            exit 1
        fi
        continue
    fi

    dirty=$(git -C "$wpath" status --porcelain 2>/dev/null | wc -l | tr -d ' ' || echo 0)
    ahead=$(git -C "$wpath" rev-list main..HEAD --count 2>/dev/null || echo "?")
    ahead_origin=$(git -C "$wpath" rev-list origin/main..HEAD --count 2>/dev/null || echo "?")
    if [[ "$ahead" != "$ahead_origin" ]] && (( ahead_origin > ahead )) 2>/dev/null; then
        ahead=$ahead_origin
    fi

    if [[ "$ahead" != "0" ]]; then
        if [[ "$mode" == "single" ]]; then
            echo "Refusing to clean '$wname': $ahead unmerged commit(s) on $short_branch (vs main)." >&2
            exit 1
        fi
        continue
    fi

    if [[ "$dirty" != "0" ]]; then
        if [[ "$mode" == "single" ]]; then
            echo "Refusing to clean '$wname': $dirty uncommitted change(s) in $wpath." >&2
            exit 1
        fi
        continue
    fi

    printf '%s\t%s\n' "$wpath" "$short_branch" >> "$cleanup_file"
done < <(git worktree list --porcelain | awk '/^worktree /{path=$2} /^branch /{branch=$2; print path "\t" branch}')

if [[ "$mode" == "single" && "$target_found" -eq 0 ]]; then
    echo "No worktree named '$name' is registered." >&2
    echo "Run 'git worktree list' to see registered worktrees." >&2
    exit 1
fi

if [[ ! -s "$cleanup_file" ]]; then
    echo "No merged worktrees to clean up."
    exit 0
fi

echo ""
echo "The following worktree(s) are fully merged into main with no dirty files:"
echo ""
while IFS=$'\t' read -r wpath branch; do
    printf '  \033[32m✓\033[0m %-45s %s\n' "$(basename "$wpath")" "$branch"
done < "$cleanup_file"
echo ""
echo "This will:"
echo "  1. Remove the git worktree"
echo "  2. Delete the local branch"
echo ""
printf "Proceed? [y/N] "
read -r confirm

if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

echo ""
while IFS=$'\t' read -r wpath branch; do
    cname=$(basename "$wpath")
    printf 'Cleaning up \033[33m%s\033[0m ...\n' "$cname"

    if git worktree remove "$wpath" 2>/dev/null; then
        echo "  Worktree removed"
    else
        echo "  Failed to remove worktree"
    fi

    if git branch -d "$branch" 2>/dev/null; then
        echo "  Branch deleted"
    else
        echo "  Branch already removed or protected"
    fi

    echo ""
done < "$cleanup_file"

echo "Done."
