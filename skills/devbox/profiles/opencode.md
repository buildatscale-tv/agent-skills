# OpenCode Agent Dispatch

For devboxes that will run an OpenCode agent. Follow the base SKILL.md lifecycle, but before Step 1 (Create), set up the image and append the opencode session to the spec.

## Prerequisites: Custom image with secrets

OpenCode needs an API key (`OPENCODE_API_KEY`) available in the devbox environment. The simplest way is a thin custom image that attaches vault secrets.

Check if a custom image already exists:
```bash
devbox image list -o json | jq -r '.[] | select(.name | test("builtin") | not) | .name'
```

If one exists with your secrets, skip to the next section. Otherwise:

### 1. Create vault secrets

```bash
echo "$OPENCODE_API_KEY" | nsc vault add --description "OpenCode API key" --revealable
# Returns: sec_xxx
```

Add any other secrets your app needs the same way (e.g. `echo "$GEMINI_API_KEY" | nsc vault add ...`).

### 2. Build the image

You can use **any** Docker base image — you are not limited to Namespace's builtin images. If the project needs a specific runtime, use that as the base (e.g. `ruby:3.3.9-slim`, `node:22-slim`). Install OpenCode in the Dockerfile:

```dockerfile
RUN curl -fsSL https://opencode.ai/install | bash
```

Build with `devbox image build`, using `-f` if the Dockerfile has a non-default name:

```bash
devbox image build ./ -f Dockerfile.devbox --name my-opencode-agent \
  --secrets OPENCODE_API_KEY=sec_xxx
```

If you don't need a custom runtime, extend from `builtin:agents`:

```bash
mkdir -p .devbox-tmp
DIGEST=$(devbox image list -o json | jq -r '.[] | select(.name=="builtin:agents") | .digest')
echo "FROM public.registry.namespace.systems/namespacelabs.dev/internal/devbox/userimages/ext@$DIGEST" > .devbox-tmp/Dockerfile
devbox image build .devbox-tmp/ --name my-opencode-agent \
  --secrets OPENCODE_API_KEY=sec_xxx
```

Note: `builtin:agents` already includes OpenCode. Custom base images need the `curl | bash` install line.

## Before Step 1: Add sessions to spec

After the sed for `name_prefix`, append sessions to the spec.

### Session command rules (mandatory)

Every session command MUST follow these rules. Violations will cause silent failures:

1. **Wrap in `/bin/bash -c '...'`** — not bare commands, not `-lc`. Slim base images may not have login shells.
2. **Use absolute paths** — `cd /workspaces/$REPO_NAME`, never `cd $REPO_NAME` or relative paths. Sessions start from an undefined cwd.
3. **Use `exec`** for the final long-running process — ensures proper signal handling and cleanup.

### Required sessions

**1. Docker Compose services** (if `docker-compose.yml` exists in the project)

Run infrastructure via Docker Compose. Never run databases/caches natively — always use the project's compose file. Docker is provided by the Namespace devbox runtime — do NOT install Docker in `Dockerfile.devbox`.

```yaml
  - name: services
    command: |
      /bin/bash -c '
      cd /workspaces/$REPO_NAME
      exec docker compose up
      '
```

**2. App server** (if the user requests the app to run)

Must wait for dependencies before starting. Determine the start command from the project (`Procfile.dev`, `bin/dev`, `package.json`).

```yaml
  - name: app
    command: |
      /bin/bash -c '
      cd /workspaces/$REPO_NAME
      until pg_isready -h localhost -q 2>/dev/null; do sleep 1; done
      bundle exec rails db:prepare
      exec bin/dev
      '
```

Adapt the wait and start commands per framework:

| Framework | Wait for deps | Install deps | Start command |
|---|---|---|---|
| Rails | `until pg_isready -h localhost -q 2>/dev/null; do sleep 1; done` | `bundle install --quiet` (skip if in image) | `bin/dev` or `bin/rails server` |
| Next.js | (skip if no DB) | `npm install` (skip if in image) | `npm run dev` |
| Astro | (skip if no DB) | `npm install` (skip if in image) | `npm run dev` |

**3. OpenCode** (always added)

OpenCode MUST start from `/workspaces/$REPO_NAME` — if started from any other directory, the web UI won't discover the git project and sessions created via the API won't be visible. It MUST bind to `0.0.0.0` on port `4096` to be reachable via the SSH tunnel.

```yaml
  - name: opencode
    command: |
      /bin/bash -c '
      export PATH="/root/.opencode/bin:$PATH"
      mkdir -p /root/.config/opencode
      echo "{\"permission\":{\"*\":\"allow\"}}" > /root/.config/opencode/opencode.json
      cd /workspaces/$REPO_NAME
      exec opencode serve --hostname 0.0.0.0 --port 4096
      '
```

Then continue with Step 1 (devbox create).

## Model selector

If the user specified `--model X/Y` or "with model X/Y" (e.g. `opencode-go/glm-4.6`), note it for the session creation step.

## Step A: Wait for health + create session

OpenCode does not require authentication by default (`OPENCODE_SERVER_PASSWORD` is not set). Do not pass `-u opencode:$PASS` unless you have explicitly set a server password.

Wait for the server to become healthy, then query `/project` to get the correct project ID before creating a session:

```bash
until curl -fsS http://localhost:$TUNNEL_PORT/global/health >/dev/null 2>&1; do
  sleep 3
done

PROJECT_ID=$(curl -fsS http://localhost:$TUNNEL_PORT/project | jq -r '.[] | select(.worktree | endswith("/'$REPO_NAME'")) | .id')

SID=$(curl -fsS -X POST http://localhost:$TUNNEL_PORT/session \
  -H 'Content-Type: application/json' \
  -d "{\"projectID\":\"$PROJECT_ID\"}" | jq -r '.id')
```

Without `projectID`, the session lands under the `global` project and won't appear in the web UI when viewing the repo project.

If a model override was specified, pass it in the session body:
`{"projectID":"...","model":{"providerID":"<X>","id":"<Y>"}}`

## Step B: Compose prompt + dispatch

Compose the prompt from `prompts/issue.md` or `prompts/adhoc.md`. Substitute placeholders, then send via the local tunnel (no SSH or file upload needed):

```bash
curl -fsS -X POST "http://localhost:$TUNNEL_PORT/session/$SID/message" \
  -H 'Content-Type: application/json' \
  -d '{"parts":[{"type":"text","text":"<PROMPT>"}]}' > /dev/null 2>&1 &
```

## Monitoring

All monitoring commands go through the local tunnel — no SSH needed:

| Check | Command |
|---|---|
| Session info | `curl -s http://localhost:$TUNNEL_PORT/session \| jq '.[] \| {title, cost, tokens: .tokens.output}'` |
| Full transcript | `curl -s http://localhost:$TUNNEL_PORT/session/$SID/message` |
| Projects | `curl -s http://localhost:$TUNNEL_PORT/project` |
| Server log | `devbox session connect $NAME --session opencode` |
| Check for PR | `gh pr list --repo <REPO> --head <BRANCH>` |
