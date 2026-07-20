# Profile: OpenCode server box

A hardened box running `opencode serve` with its **native web auth**, so you
open the OpenCode web UI in a browser and drive it with your **opencode-go**
subscription. From-scratch workload (no Hetzner image). opencode runs as a
dedicated **non-sudo `opencode` system user** (the agent can never reach root)
and binds `127.0.0.1:4096`. Reached privately over an SSH tunnel — **no ports
are opened** in the firewall.

The install needs secrets (API key, web password), so it runs **post-boot over
SSH** — never via cloud-init user_data. First boot hardens the box; Pulumi then
SSHes in as the admin user and runs the installer with the secrets in its
environment.

## Config

```bash
pulumi config set workload         opencode
pulumi config set access           ssh
pulumi config set serverType       cpx21          # hil offers the cpxN1 line; 4 GB is plenty
pulumi config set sshPublicKey     "$(cat ~/.ssh/id_ed25519.pub)"
pulumi config set opencodeUsername forge          # web-login username (default: opencode)
pulumi config set opencodeApiKey   "<opencode-go key>"                              --secret
pulumi config set opencodePassword "$(openssl rand -base64 18 | tr -dc A-Za-z0-9)"  --secret
# optional: pulumi config set opencodeModel opencode-go/kimi-k3   (this is the default)
```
Then `pulumi up`. Report the IPv4, the login (`opencodeUsername` + generated password),
and the SSH-tunnel command.

## What the install does (`scripts/install-opencode.sh`, over SSH after hardening)

1. Installs Node 22 and opencode (system-wide binary).
2. Creates a **dedicated non-sudo `opencode` system user** — opencode + every agent session run as it.
3. Writes `auth.json` for opencode-go and a default model (`opencodeModel`, Kimi K3) in `~/.config/opencode`.
4. Creates a starter project `/home/opencode/projects/scratch` (setgid, group-writable; admin added to the `opencode` group → manage projects without sudo).
5. `opencode-serve.service` runs `opencode serve --hostname 127.0.0.1 --port 4096` as `opencode`, with `OPENCODE_SERVER_USERNAME` and `OPENCODE_SERVER_PASSWORD` set.

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
