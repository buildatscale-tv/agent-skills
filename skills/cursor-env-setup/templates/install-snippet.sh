#!/usr/bin/env bash
# Snippet for .cursor/install.sh — keep project-specific deps above this.
set -euo pipefail

# Install the repo git hooks. Cursor's managed hook dispatcher chains to
# /workspace/.git/hooks, so these run alongside the managed secret scanner.
for hook in pre-commit commit-msg; do
  [ -f ".githooks/$hook" ] && install -m 755 ".githooks/$hook" ".git/hooks/$hook"
done
