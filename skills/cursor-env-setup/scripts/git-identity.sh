#!/usr/bin/env bash
# Attribute this environment's Cloud Agent commits to the human running the
# agent, instead of the default "Cursor Agent" author + "Co-authored-by:" trailer.
#
# Driven entirely by per-user config so each teammate gets their own attribution:
#   GIT_AUTHOR_NAME_OVERRIDE   your commit author name   (plain env var secret)
#   GIT_AUTHOR_EMAIL_OVERRIDE  your commit author email  (plain env var secret)
#   GIT_SIGNING_SSH_KEY        your SSH signing private key, base64-encoded
#                              (RUNTIME secret; base64 keeps the PEM newlines
#                              intact through single-line secret storage)
#
# Set these as PERSONAL-scoped Cloud Agent secrets; a personal secret overrides
# a team one of the same name, so every teammate's agents author/sign as them.
# When the name/email vars are unset, the default Cursor identity is left alone.
set -euo pipefail

GIT_NAME="${GIT_AUTHOR_NAME_OVERRIDE:-}"
GIT_EMAIL="${GIT_AUTHOR_EMAIL_OVERRIDE:-}"

identity_overridden=0
if [ -n "$GIT_NAME" ] && [ -n "$GIT_EMAIL" ]; then
  identity_overridden=1
  git config --global user.name "$GIT_NAME"
  git config --global user.email "$GIT_EMAIL"

  # Disable ONLY the managed co-author appender (a *.co-author hook in Cursor's
  # managed hooks dir). The dispatcher only runs executable cursor hooks, so
  # dropping the execute bit keeps Cursor's secret-scanner hooks intact.
  hooks_dir="$(git config core.hooksPath 2>/dev/null || true)"
  if [ -n "${hooks_dir:-}" ] && [ -d "$hooks_dir" ]; then
    find "$hooks_dir" -maxdepth 1 -name '*.co-author' -exec chmod -x {} + 2>/dev/null || true
  fi
  echo "git-identity.sh: commits will be authored as $GIT_NAME <$GIT_EMAIL>"
else
  echo "git-identity.sh: GIT_AUTHOR_*_OVERRIDE not set; leaving the default identity in place"
fi

# Commit signing.
#   - With your own SSH signing key (registered as a *Signing key* on GitHub),
#     sign as yourself so commits show "Verified".
#   - Without a key but with an overridden identity, disable signing so commits
#     are not signed by Cursor's managed key under your name (GitHub would then
#     show "Unverified").
#   - Otherwise leave signing untouched (keeps Cursor's default signed commits).
if [ -n "${GIT_SIGNING_SSH_KEY:-}" ]; then
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  key="$HOME/.ssh/git_signing_key"
  # Accept either a base64-encoded key (recommended: a one-line secret keeps the
  # PEM newlines intact) or a raw multi-line key.
  if decoded="$(printf '%s' "$GIT_SIGNING_SSH_KEY" | base64 -d 2>/dev/null)" \
     && printf '%s' "$decoded" | grep -q "PRIVATE KEY"; then
    printf '%s\n' "$decoded" > "$key"
  else
    printf '%s\n' "$GIT_SIGNING_SSH_KEY" > "$key"
  fi
  chmod 600 "$key"
  # Only enable signing if the key actually parses; a malformed key must never
  # block commits (they just stay unsigned instead of failing to sign).
  if ssh-keygen -y -f "$key" > "$key.pub" 2>/dev/null && [ -s "$key.pub" ]; then
    git config --global gpg.format ssh
    git config --global gpg.ssh.program ssh-keygen
    git config --global user.signingkey "$key.pub"
    git config --global commit.gpgsign true
    echo "git-identity.sh: signing commits with provided SSH key"
  else
    echo "git-identity.sh: WARNING - GIT_SIGNING_SSH_KEY could not be parsed; signing disabled. Store the key base64-encoded." >&2
    git config --global commit.gpgsign false
  fi
elif [ "$identity_overridden" -eq 1 ]; then
  git config --global commit.gpgsign false
fi
