---
name: env-setup-git
description: >-
  Set up a Cursor Cloud Agent environment for a new or existing repo: run
  Cursor's built-in /env-setup (or agent-driven Cloud Environment setup) for
  deps and Builds, then layer human git identity, slash-free branch names,
  co-author trailer blocking, and optional SSH commit signing. Use when
  bootstrapping Cloud Agents, wiring .cursor/environment.json install/start,
  or replacing default "Cursor Agent" + Co-authored-by attribution.
---

# Cloud env setup + human git identity

## When to use

- Brand-new project that will run on **Cursor Cloud Agents**
- Existing repo that still commits as `Cursor Agent` with a `Co-authored-by:` trailer
- You want Cloud Agent commits attributed to the **human** (and optionally SSH-signed as them)

## What this skill adds (on top of `/env-setup`)

1. **Cursor `/env-setup` first** — agent-driven Cloud Environment setup (deps, Build/snapshot, `install` / `start` / `terminals`). Do not skip it.
2. **This skill second** — drop in git identity scripts + hooks and wire them into `install` / `start`.
3. **Secrets last** — tell the human how to set personal Cloud Agent secrets for name, email, and optional signing key.

Keep stack-specific install steps (Ruby, Node, Postgres, etc.) in the project's own `.cursor/install.sh` / `start.sh`. This skill only owns the **git attribution** layer.

## Preferred git handling (defaults this skill installs)

| Preference | Behavior |
|------------|----------|
| Author | Human from `GIT_AUTHOR_NAME_OVERRIDE` + `GIT_AUTHOR_EMAIL_OVERRIDE` |
| Co-author trailer | **Blocked** — neutralize Cursor `*.co-author` hooks; strip any `Co-authored-by:` lines |
| Subject line | Strip a trailing period on the first non-blank line |
| Branch names | **No slashes** (blocks managed `cursor/...` prefixes). Prefer short kebab-case (2–3 words). Avoid agent random suffixes (convention) |
| Signing | Optional SSH signing via `GIT_SIGNING_SSH_KEY`; if identity is overridden without a key, disable Cursor's managed signing so GitHub does not show Unverified under the human's name |

When the override secrets are **unset**, leave Cursor's default identity alone (safe for contributors who have not configured personal secrets).

## Steps for the agent

### 1. Run Cursor env setup

Invoke Cursor's built-in **`/env-setup`** (or follow [Cloud Environment Setup](https://cursor.com/docs/cloud-agent/setup): dashboard agent-driven setup / Dockerfile / `.cursor/environment.json`).

Ensure the environment can install deps and produce a successful Build. Commit `.cursor/environment.json` when the repo should own the config.

Minimal shape (extend with project `install` / `start` / `terminals` as needed):

```json
{
  "install": "bash .cursor/install.sh",
  "start": "bash .cursor/start.sh"
}
```

### 2. Add the git layer files

Copy from this skill into the repo (paths relative to skill root):

| Source | Destination |
|--------|-------------|
| `scripts/git-identity.sh` | `.cursor/git-identity.sh` |
| `hooks/pre-commit` | `.githooks/pre-commit` |
| `hooks/commit-msg` | `.githooks/commit-msg` |

Make scripts executable (`chmod +x`).

### 3. Wire install + start

In `.cursor/install.sh` (idempotent), install hooks into `.git/hooks` so Cursor's managed dispatcher still chains to them:

```bash
# Install the repo git hooks. Cursor's managed hook dispatcher chains to
# /workspace/.git/hooks, so these run alongside the managed secret scanner.
for hook in pre-commit commit-msg; do
  [ -f ".githooks/$hook" ] && install -m 755 ".githooks/$hook" ".git/hooks/$hook"
done
```

In `.cursor/start.sh` (runs when an agent boots), call identity setup early (non-fatal):

```bash
bash .cursor/git-identity.sh || true
```

See `templates/install-snippet.sh` and `templates/start-snippet.sh` for copy-paste stubs.

### 4. Document in AGENTS.md (generic)

Add a short Cloud Agents section, for example:

- Commits must be authored as the human configured by Cloud Agent secrets — do **not** author as `Cursor Agent` and do **not** add a `Co-authored-by:` trailer.
- `.cursor/git-identity.sh` (from `start.sh`) sets `user.name` / `user.email` from `GIT_AUTHOR_NAME_OVERRIDE` and `GIT_AUTHOR_EMAIL_OVERRIDE`, disables Cursor `*.co-author` hooks, and signs with `GIT_SIGNING_SSH_KEY` when set.
- `.githooks/commit-msg` strips `Co-authored-by:` and trailing periods on the subject; `.githooks/pre-commit` requires `user.email` to match `GIT_AUTHOR_EMAIL_OVERRIDE` when set, and blocks branch names that contain `/`.
- Prefer short kebab-case branch names with **no** `/` and **no** `cursor/` prefix.
- Do **not** append agent random suffixes to branch names (e.g. `-efe5`, `-99c1`) — document as convention; hooks do not enforce this.
- Prefer short imperative commit subjects (≈70 chars, no trailing period).

### 5. Stop and instruct the human (secrets)

Do **not** invent or paste secret values. End the setup with clear instructions:

---

## How to set git identity variables (human)

Set these as **personal-scoped** secrets in the [Cloud Agents dashboard](https://cursor.com/dashboard/cloud-agents) (or Cursor Settings → Secrets). Personal secrets override team secrets of the same name, so each teammate's agents author/sign as them.

| Secret | Required | Purpose |
|--------|----------|---------|
| `GIT_AUTHOR_NAME_OVERRIDE` | Yes (for human attribution) | Commit author name |
| `GIT_AUTHOR_EMAIL_OVERRIDE` | Yes (for human attribution) | Commit author email (must match the GitHub account / noreply you want on commits) |
| `GIT_SIGNING_SSH_KEY` | Optional | SSH **signing** private key, **base64-encoded** on one line (keeps PEM newlines intact). Register the matching public key as a GitHub **Signing key**. |

### Encode a signing key (optional)

```bash
base64 < ~/.ssh/id_ed25519_signing | tr -d '\n'
# or: base64 -i ~/.ssh/id_ed25519_signing | tr -d '\n'   # macOS
```

Paste the single line into `GIT_SIGNING_SSH_KEY`. If the key cannot be parsed, the script disables signing instead of blocking commits.

### Verify on the next agent run

After secrets are saved, start a Cloud Agent and confirm:

```bash
git config user.name
git config user.email
# optional: git config --get commit.gpgsign
```

Create a throwaway commit on a slash-free branch and confirm GitHub shows the human author (Verified if signing is configured). Also confirm a slashy branch name is rejected at commit time.

### Human checklist

1. Create the three **personal** secrets above (signing key optional but recommended).
2. Register the SSH public key as a GitHub **Signing key** (not only an auth key).
3. Rebuild / refresh the Cloud Agent environment so `install` + `start` pick up the new scripts.
4. Verify: human author, no `Co-authored-by:`, Verified when signing is configured, slash branch rejected on commit.

---

## Gotchas

- `git commit --no-verify` bypasses these hooks.
- The slash rule runs at **commit** time, not branch creation. If the agent is already on `cursor/foo-99c1`, rename first: `git branch -m flat-kebab-name`.
- Random suffixes (`-efe5`, `-99c1`) need AGENTS.md / prompt discipline — not hook-enforced.
- Never put the private signing key in chat or the repo — personal Cloud Agent secret only.
- Name/email override without `GIT_SIGNING_SSH_KEY` leaves commits **unsigned** by design (avoids Cursor-managed signatures under the human's name showing as Unverified).
- Laptop-global `core.hooksPath` setups are **not** present on Cursor VMs. Cloud Agents must use the repo `.githooks` + secrets path from this skill.

## Out of scope

- Language/runtime install recipes (leave to `/env-setup` + project scripts)
- Forcing a specific person's name/email in the skill files (always env-driven)
- Requiring co-author trailers (this skill **removes** them by design)

## Files in this skill

- `scripts/git-identity.sh` — apply overrides, neutralize `*.co-author`, optional SSH sign
- `hooks/pre-commit` — email match + no `/` in branch names + neutralize co-author
- `hooks/commit-msg` — strip `Co-authored-by:` + trailing subject period
- `templates/*` — install/start wiring snippets
