#!/usr/bin/env bash
# Snippet for .cursor/start.sh — call early; non-fatal if secrets are unset.
set -euo pipefail

bash .cursor/git-identity.sh || true
