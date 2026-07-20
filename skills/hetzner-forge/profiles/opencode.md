# Profile: OpenCode server box

A hardened box running `opencode serve` behind an nginx **basic-auth** login, so
you open the OpenCode web UI in a browser and drive it with your **opencode-go**
subscription. From-scratch workload (no Hetzner image). opencode binds
`127.0.0.1:4097`; nginx fronts it on the access port (`4096`) with a username +
password. Reached **privately over an SSH tunnel** — never the public internet.

## Provisioning — what the driving agent does

1. **Get the opencode-go API key from the user** (only they have it; it's a secret).
2. **Generate a strong web password**, pick a username (`FORGE_OPENCODE_USER`, default `opencode`). `forge.sh` generates the password if you don't pass one, and prints the login. Report both to the user.
3. **Run forge.sh**:
   ```bash
   export FORGE_SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)"
   export FORGE_NAME=forge-oc FORGE_WORKLOAD=opencode FORGE_ACCESS=ssh
   export FORGE_TYPE=cpx21 FORGE_LOCATION=hil
   export FORGE_OPENCODE_API_KEY="<opencode-go key>" FORGE_OPENCODE_USER=forge
   bash forge.sh
   ```
4. **Report** the IPv4, the login (username + generated password), and the SSH tunnel command.

## What the install does (`lib/install-opencode.sh`, in cloud-init after hardening)

1. Installs Node 22, opencode, nginx, apache2-utils.
2. Writes `~/.local/share/opencode/auth.json` = `{"opencode-go":{"type":"api","key":"<key>"}}` (mode 0600), and `chown -R` the admin user's `~/.local` (opencode also writes `~/.local/state` at runtime).
3. `opencode-serve.service` runs `opencode serve --hostname 127.0.0.1 --port 4097` as the admin user with `HOME` set.
4. nginx listens on `4096` with `auth_basic` (htpasswd/bcrypt) → reverse-proxies to `127.0.0.1:4097`.

## Reaching it (private, via SSH tunnel)

The access port (4096) is **closed on the public firewall**:

- **Just this Mac:** `ssh -L 4096:localhost:4096 <adminUser>@<ipv4>` → `http://localhost:4096`.
- **Phone / other LAN devices:** `ssh -L 0.0.0.0:4096:localhost:4096 <adminUser>@<ipv4>` → `http://<mac-lan-ip>:4096`.

If the user's ssh-agent holds many keys, hardening's `MaxAuthTries 3` can reject
the connection — use `-i <the key> -o IdentitiesOnly=yes`.

## Making your first session

OpenCode starts every chat inside a **project (a directory)** — "New session" does
nothing until one is open. The box ships with a starter `~/projects/scratch`. In the
web UI: **Add project** → in the folder box **type a path** (e.g. `/home/deploy/projects`
— it's a *path* picker, not a name search) → open `scratch` → **New session**. Add your
own repos under `~/projects/`.

> Log in via the browser's basic-auth prompt (a clean URL). Don't embed the login in
> the URL (`user:pass@host`) — opencode's client router mishandles URL userinfo.

## Notes

- **Secrets** (the API key, the web password) are passed as env into cloud-init and land in the box's user-data metadata. Prefer rotatable keys; rotate if torn down.
- Sizing: opencode is a lightweight client (models run remotely via opencode-go). `cpx21` (4 GB) is plenty.
- Verify: `ssh <adminUser>@<ipv4> 'systemctl is-active opencode-serve nginx'` and `curl -u user:pass http://localhost:4096/` (200 through the tunnel; 401 without auth).
- Auth mechanism confirmed against a working local install: opencode-go uses `type:"api"` + `key`. If opencode changes its schema, update `lib/install-opencode.sh`.
- `HOME` must be set for the opencode installer (cloud-init runs as root with `HOME` unset) — `lib/install-opencode.sh` sets it.
