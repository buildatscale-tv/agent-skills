---
name: devbox
description: Create, manage, and tear down Namespace devboxes. Invoked via `/devbox <freeform>` or natural-language requests. Handles creating devboxes from a static spec, configuring SSH and GitHub auth, opening tunnels, teardown, and lookup. When the request involves dispatching work to an agent (issue, ad-hoc task, variants), the OpenCode profile at profiles/opencode.md layers on agent dispatch and monitoring. Also handles plain "give me a devbox" requests with no agent dispatch.
---

# /devbox

Create and manage Namespace devboxes. Each box gets its own name, SSH alias, and forwarded ports.

When the request involves agent work (an issue, ad-hoc task, or variant comparison), follow the OpenCode profile after the base lifecycle:
- [OpenCode profile](profiles/opencode.md) for boxes with `opencode serve`

## Parsing the /devbox argument

| Pattern | Mode | What to do |
|---|---|---|
| "tear down issue 32", "destroy that devbox", "kill the variants" | Teardown | Jump to Teardown section |
| "status", "how's issue 32 doing" | Status | Jump to Lookup + status check |
| "<N> variants/versions of <work>", "fan out <N> <work>" | Multi-variant | Run lifecycle N times in parallel. Requires an agent profile. |
| "issue 32", "#32", "ticket 42", bare integer | Issue dispatch | Run lifecycle once. Requires an agent profile. |
| "create a sponsors page", "refactor auth", any task description | Ad-hoc dispatch | Run lifecycle once. Requires an agent profile. |
| "give me a devbox", "spin up a box", no task specified | Plain devbox | Run lifecycle only (no agent dispatch). |

---

## Lifecycle

### Identifiers

Compute before starting. Report connection details to the user immediately.

| Value | Issue mode | Ad-hoc / plain mode |
|---|---|---|
| `PREFIX` | `issue-<N>-` | `<slug>-` (lowercase, alphanum + hyphens, max 30 chars) |
| `BRANCH` | `agent/issue-<N>` | `agent/<slug>` (skip for plain devbox) |
| `APP_PORT` | `30000 + N` | Pick a free port in 30100-30999 |
| `TUNNEL_PORT` | `40000 + N` | `APP_PORT + 10000` |
| `REPO` | from `--repo` flag, else `git remote get-url origin` | same |

### Step 0: Resolve image

Before creating the devbox, determine which image to use. Check in this order:

1. **User-specified image** ("use my opencode image", "use the rails image") — look it up:
   ```bash
   devbox image list -o json | jq -r '.[] | .name'
   ```

2. **`Dockerfile.devbox` in the project root** — if it exists, this project defines its own devbox image. Check if a matching image is already built, and build/rebuild if needed:
   ```bash
   if [ -f Dockerfile.devbox ]; then
     IMAGE_NAME="${REPO_NAME}-devbox"
     EXISTING=$(devbox image list -o json | jq -r --arg name "$IMAGE_NAME" '.[] | select(.name==$name) | .name')
     if [ -z "$EXISTING" ]; then
       echo "Building image $IMAGE_NAME from Dockerfile.devbox..."
       devbox image build ./ -f Dockerfile.devbox --name "$IMAGE_NAME" \
         --secrets OPENCODE_API_KEY=<sec_id>
     fi
   fi
   ```
   The `<sec_id>` comes from `nsc vault list` or a prior vault add. Check the agent profile for secret setup.

3. **No Dockerfile.devbox, no user preference** — fall back to the spec's default (`builtin:agents`).

Override the spec's `image:` line via sed if using a non-default image.

**Custom images:** Namespace supports any Docker base image — you are not limited to `builtin:agents` or `builtin:base`. If the project needs a specific runtime (e.g. `ruby:3.3.9-slim`, `node:22`), create a `Dockerfile.devbox` in the project root. Namespace converts any image into its optimized format.

**Do NOT install Docker in `Dockerfile.devbox`.** Namespace devboxes provide Docker automatically (`setup_docker_client: true`). Only add application-level dependencies (runtimes, libraries, tools) to the image. Docker commands like `docker compose up` work out of the box in session commands.

### Step 1: Create

Resolve the repo from `--repo` flag or `git remote get-url origin`. Derive `REPO_NAME` (the final path segment) for use in session commands.

**If the project has a `devbox.yaml` in the root**, use it directly — it already contains the image, sessions, and repo config. Only rewrite `name_prefix:`:

```bash
mkdir -p .devbox-tmp
REPO=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||')
REPO_NAME=$(basename "$REPO")

if [ -f devbox.yaml ]; then
  sed 's/^name_prefix:.*/name_prefix: <PREFIX>/' devbox.yaml > .devbox-tmp/spec.yaml
else
  # No project spec — build one from the skill's base template
  sed 's/^name_prefix:.*/name_prefix: <PREFIX>/' .agents/skills/devbox/devbox.yaml > .devbox-tmp/spec.yaml
  [ -n "$IMAGE_NAME" ] && sed -i 's/^image:.*/image: '"$IMAGE_NAME"'/' .devbox-tmp/spec.yaml
  [ -n "$REPO" ] && echo "repository: github.com/$REPO" >> .devbox-tmp/spec.yaml
  # Append sessions per the OpenCode profile instructions
fi

devbox create --from .devbox-tmp/spec.yaml 2>&1 | tee .devbox-tmp/create.log
NAME=$(grep -oE 'ssh [^ ]+\.devbox\.namespace' .devbox-tmp/create.log | head -1 | awk '{print $2}' | sed 's/\.devbox\.namespace$//')
echo "devbox: $NAME"
```

When a project `devbox.yaml` exists, skip the "Add sessions to spec" step in the agent profile — sessions are already defined.

### Step 2: Configure

```bash
devbox configure-ssh "$NAME" >/dev/null
devbox setup-github "$NAME" || echo "setup-github skipped (gh CLI not on image)"
```

`setup-github` requires `gh` on the devbox. It ships with `builtin:agents` / `builtin:base` but not with custom base images (e.g. `ruby:*-slim`). The command is non-critical — repo cloning works via the spec's `repository:` line regardless.

### Step 3: Open tunnels

Forward ports from the devbox to localhost. Adjust the remote targets to match whatever the devbox runs (values below are defaults from the Constants table).

```bash
ssh -fN -o LogLevel=ERROR -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  -L <TUNNEL_PORT>:localhost:<TUNNEL_REMOTE_PORT> \
  -L <APP_PORT>:<APP_BIND_HOST>:<APP_PORT_INTERNAL> \
  "$NAME.devbox.namespace"
```

For plain devbox requests, stop here. Report the box name + SSH alias.

**For agent dispatch requests**, continue with the relevant profile.

---

## Teardown

| Step | Command |
|---|---|
| Kill tunnels | `pkill -f "ssh.*<NAME>.devbox.namespace"` |
| Expire box | `devbox expire <NAME> --force` |

---

## Lookup

Box names encode the dispatch identity via `name_prefix`:
- Issue: `issue-<N>-<random>` (e.g. `issue-32-rsep2bmaq4`)
- Ad-hoc: `<slug>-<random>`

```bash
devbox list -o json | jq -r '.[] | select(.name | startswith("issue-32-")) | .name'
```

Or by deterministic port (issue mode): `lsof -iTCP:40032 -sTCP:LISTEN`.

---

## Constants

| Name | Default | What it's for |
|---|---|---|
| `APP_PORT_INTERNAL` | 4321 | Dev server port inside the box (Astro default) |
| `APP_BIND_HOST` | `[::1]` | Astro binds IPv6; tunnel target must match |
| `TUNNEL_REMOTE_PORT` | 4096 | Agent server port inside the box (OpenCode default) |

Change these when the spec's session command moves to a different stack or agent runtime.

Common overrides by framework:

| Framework | `APP_PORT_INTERNAL` | `APP_BIND_HOST` |
|---|---|---|
| Astro | 4321 | `[::1]` |
| Rails | 3000 | `localhost` |
| Next.js | 3000 | `localhost` |
| Vite | 5173 | `localhost` |

## Files

- `devbox.yaml` - static Namespace devbox spec. `name_prefix:` is rewritten per dispatch via `sed`.
- `profiles/opencode.md` - OpenCode agent dispatch and monitoring.
- `prompts/issue.md`, `prompts/adhoc.md` - prompt templates (used by agent profiles).

## Host env

- `gh auth status` green; GitHub auth is forwarded into the box.
