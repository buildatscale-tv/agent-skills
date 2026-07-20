# Profile: OpenCode server box

A hardened box running `opencode web` with its **native web auth**, so you
open the OpenCode web UI in a browser and drive it with your **opencode-go**
subscription. From-scratch workload (no Hetzner image). opencode runs as a
dedicated **non-sudo `opencode` system user** (the agent can never reach root)
and binds `127.0.0.1:4096`. Reached privately over an SSH tunnel — **no ports
are opened** in the firewall.

The install needs the web password (so it can set native auth) and the
opencode-go **API key**. Both are stored as Pulumi secrets and travel to the box
over SSH only — never via cloud-init `user_data`.

**Recommended flow:** the agent scaffolds the project and sets `opencodePassword`
and `opencodeUsername`, then **pauses** so you can set `opencodeApiKey` directly
with `pulumi config set ... --secret` in the project directory. The plaintext key
never passes through the agent's context — it goes straight into encrypted Pulumi
state and is only used by Pulumi during the SSH-delivered install.

**Fallback options:**
- Give the agent the key directly (still encrypted in Pulumi state, but the agent
  sees the plaintext briefly).
- Omit the key entirely; the installer writes a placeholder and you replace it
  manually over SSH after deploy.

## Config

The agent scaffolds the project and sets everything except the API key. Then it
pauses and you run this in the project directory:

```bash
export PULUMI_CONFIG_PASSPHRASE="$(cat .pulumi-passphrase)"
pulumi config set opencodeApiKey "<opencode-go key>" --secret
```

Other config the agent handles for you:

```bash
pulumi config set workload         opencode
pulumi config set access           ssh
pulumi config set serverType       cpx21          # hil offers the cpxN1 line; 4 GB is plenty
pulumi config set sshPublicKey     "$(cat ~/.ssh/id_ed25519.pub)"
pulumi config set opencodeUsername forge          # web-login username (default: opencode)
pulumi config set opencodePassword "$(openssl rand -base64 18 | tr -dc A-Za-z0-9)"  --secret
# optional: pulumi config set opencodeModel opencode-go/kimi-k3   (this is the default)
```

Then `pulumi up`. At the end, run `pulumi stack output summary` for the full markdown
report, and `pulumi stack output opencodePassword --show-secrets` to retrieve the
generated web password.

If you prefer the agent to handle the API key directly (higher friction for the
agent, lower friction for you), or want to add the key manually over SSH after
deploy, see Fallback options above.

## What the install does (`scripts/install-opencode.sh`, over SSH after hardening)

1. Installs Node 22 and opencode (system-wide binary).
2. Creates a **dedicated non-sudo `opencode` system user** — opencode + every agent session run as it.
3. Writes `auth.json` for opencode-go (or a placeholder if you omitted `opencodeApiKey`) and a default model (`opencodeModel`, Kimi K3) in `~/.config/opencode`.
4. Creates a starter project `/home/opencode/projects/scratch` (setgid, group-writable; admin added to the `opencode` group → manage projects without sudo).
5. `opencode-serve.service` runs `opencode web --hostname 127.0.0.1 --port 4096` as `opencode`, with `OPENCODE_SERVER_USERNAME` and `OPENCODE_SERVER_PASSWORD` set.

## Reaching it (private, via SSH tunnel)

- **This Mac:** `ssh -L 4096:localhost:4096 <adminUser>@<ipv4>` → `http://localhost:4096`
- **Phone / LAN:** `ssh -L 0.0.0.0:4096:localhost:4096 <adminUser>@<ipv4>` → `http://<mac-lan-ip>:4096`

If your ssh-agent holds many keys, use `-i <key> -o IdentitiesOnly=yes` (harden.sh caps `MaxAuthTries`).

## Making your first session

opencode starts every chat inside a **project (a directory)** — "New session"
does nothing until one is open. The box ships with `/home/opencode/projects/scratch`.
In the web UI: **Add project** → in the folder box **type a path**
(`/home/opencode/projects` — it's a *path* picker, not a name search) → open
`scratch` → **New session**. The default model is Kimi K3.

> Log in via the browser's native auth prompt. Don't embed the login in the URL
> (`user:pass@host`) — opencode's client router mishandles URL userinfo.

## Notes

- Secrets (API key, web password) are Pulumi secrets (encrypted in the local state by the project passphrase) and travel to the box only inside the SSH session — they are never in user_data. Still prefer rotatable keys; rotate if torn down.
- opencode is a lightweight client (models run remotely via opencode-go), so `cpx21` (4 GB) is plenty.
- Verify: `ssh <adminUser>@<ipv4> 'systemctl is-active opencode-serve'`.
- opencode-go auth is `{"opencode-go":{"type":"api","key":"…"}}`. If opencode changes its schema, update `scripts/install-opencode.sh`.
