# Profile: OpenCode server box

A hardened box running `opencode serve` behind an nginx **basic-auth** login, so
you open the OpenCode web UI in a browser and drive it with your **opencode-go**
subscription. From-scratch workload (no Hetzner image). opencode runs as a
dedicated **non-sudo `opencode` system user** (the agent can never reach root)
and binds `127.0.0.1:4097`; nginx fronts it on `:4096` with a username + password.
Reached privately over an SSH tunnel.

## Config

```bash
pulumi config set workload       opencode
pulumi config set access         ssh
pulumi config set serverType     cpx21          # hil offers the cpxN1 line; 4 GB is plenty
pulumi config set sshPublicKey   "$(cat ~/.ssh/id_ed25519.pub)"
pulumi config set opencodeUser   forge          # nginx web-login username
pulumi config set opencodeApiKey   "<opencode-go key>"                              --secret
pulumi config set opencodePassword "$(openssl rand -base64 18 | tr -dc A-Za-z0-9)"  --secret
# optional: pulumi config set opencodeModel opencode-go/kimi-k3   (this is the default)
```
Then `pulumi up`. Report the IPv4, the login (`opencodeUser` + generated password),
and the SSH-tunnel command.

## What the install does (`scripts/install-opencode.sh`, in cloud-init after hardening)

1. Installs Node 22, opencode (system-wide binary), nginx, apache2-utils.
2. Creates a **dedicated non-sudo `opencode` system user** — opencode + every agent session run as it.
3. Writes `auth.json` for opencode-go and a default model (`opencodeModel`, Kimi K3) in `~/.config/opencode`.
4. Creates a starter project `/home/opencode/projects/scratch` (setgid, group-writable; admin added to the `opencode` group → manage projects without sudo).
5. `opencode-serve.service` runs `opencode serve --hostname 127.0.0.1 --port 4097` as `opencode`.
6. nginx on `:4096` with `auth_basic` → **SSE-safe** reverse-proxy to `127.0.0.1:4097`.

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

> Log in via the browser's basic-auth prompt (a clean URL). Don't embed the login
> in the URL (`user:pass@host`) — opencode's client router mishandles URL userinfo.

## Notes

- Secrets (API key, web password) are Pulumi secrets (encrypted in state) and also land in the box's cloud-init user_data. Prefer rotatable keys; rotate if torn down.
- opencode is a lightweight client (models run remotely via opencode-go), so `cpx21` (4 GB) is plenty.
- Verify: `ssh <adminUser>@<ipv4> 'systemctl is-active opencode-serve nginx'`.
- opencode-go auth is `{"opencode-go":{"type":"api","key":"…"}}`. If opencode changes its schema, update `scripts/install-opencode.sh`.
