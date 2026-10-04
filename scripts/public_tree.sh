#!/bin/bash
# Prints the git tree id of HEAD minus the paths in .publicignore — the tree published to GitHub (release branch).
# Uses a throwaway index, so the working tree and the real index are untouched.
set -euo pipefail
cd "$(dirname "$0")/.."
IDX=$(mktemp -t lulupet-public-index)
trap 'rm -f "$IDX"' EXIT
export GIT_INDEX_FILE="$IDX"
git read-tree HEAD
grep -v '^\s*#' .publicignore | sed '/^\s*$/d' | while read -r p; do
    git rm -r -q --cached --ignore-unmatch -- "$p" >/dev/null
done
git write-tree
