---
name: hetzner-forge
description: Provision a hardened, ready-to-go Hetzner Cloud box with the hcloud CLI + cloud-init, in one guided flow. Invoked via `/hetzner-forge <freeform>` or natural-language ("spin up a Coolify box", "give me a hardened Hetzner server", "make me an OpenCode box", "tear down forge"). Handles preflight (hcloud auth), asks for the workload / access / size, builds cloud-init, creates SSH key + Cloud Firewall + server via `hcloud`, and reports connection details. Prefers official Hetzner app images when one exists (then hardens); falls back to a documented from-scratch install otherwise. No Pulumi — just `hcloud` + cloud-init.
---

# /hetzner-forge

Stand up a hardened Hetzner Cloud box. One base layer (non-root sudo user,
key-only SSH, UFW, fail2ban, unattended upgrades, Cloud Firewall) plus a
pluggable workload (Coolify, Docker, Dokploy, OpenCode, or a documented custom
target). Everything is the **`hcloud` CLI + a cloud-init script** — no Pulumi,
no state backend, no language runtime.

`forge.sh` (next to this file) is the one entrypoint. It reads `FORGE_*` env
vars, builds the cloud-init user-data, and creates the resources.

## Operating principle

**You run the commands — the user does not.** Execute the `hcloud`/`forge.sh`
steps yourself. Ask the user only for: **decisions** (workload, region, size),
**secrets you can't derive** (an OpenCode API key, a Tailscale auth key), and
**confirmation** before creating or destroying real resources. Derive the SSH
key from `~/.ssh`, generate passwords, etc.

## Parsing the argument

| Pattern | Mode |
|---|---|
| "spin up X", "make me an OpenCode box", "hardened server" | Create → run the flow |
| "status", "what's the IP" | `hcloud server list` / `hcloud server describe <name>` |
| "tear down", "destroy X" | `hcloud server delete <name> && hcloud firewall delete <name>-fw` |

## Create flow

### 1. Preflight
```bash
hcloud version >/dev/null && hcloud context active   # a project token is selected
hcloud context list                                  # confirm WHICH project with the user
```
If no context: `hcloud context create <name>` (needs a **Read & Write** token from
console.hetzner.cloud → Security → API Tokens).

### 2. Gather choices (ask; sensible defaults so "defaults" works)
- **Workload**: `base` | `coolify` | `docker` | `dokploy` | `opencode`. (Default `base`.)
- **Region**: `hil` (US-West/Hillsboro), `ash` (US-East), `fsn1`/`nbg1`/`hel1` (EU), `sin` (APAC). Default `hil`.
- **Size**: default `cpx21` (3 vCPU / 4 GB). Note **hil only offers the `cpxN1` line** (`cpx11/21/31/41/51`) — the newer `cpx*2`/`cx*3` gen is EU-only. Check with:
  ```bash
  hcloud datacenter describe hil-dc1 -o json | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['server_types']['available'])"
  ```
- **SSH key**: default `~/.ssh/id_ed25519.pub`; offer to generate if absent. `forge.sh` reuses a key already registered in the project (matched by public-key material) — no duplicate-key errors.
- **Access** (opencode/private workloads): `ssh` tunnel (default) or `tailscale`.

### 3. Run forge.sh
Set `FORGE_*` and run it (see `forge.sh` header for the full list):
```bash
export FORGE_SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)"
export FORGE_NAME=forge-oc FORGE_LOCATION=hil FORGE_TYPE=cpx21 FORGE_WORKLOAD=opencode FORGE_ACCESS=ssh
# opencode: provide the user's key; a strong web password is generated + reported
export FORGE_OPENCODE_API_KEY="$OPENCODE_KEY" FORGE_OPENCODE_USER=forge
bash forge.sh
```
`forge.sh --print-user-data` builds the cloud-init and exits (creates nothing) — use it to preview.

### 4. Report
Print the IPv4, the SSH command, the workload's access line, and (for opencode)
the login + the SSH-tunnel command. Cloud-init keeps provisioning on the box for
~3-6 minutes after `forge.sh` returns:
```bash
ssh <adminUser>@<ip> 'sudo tail -f /var/log/forge-harden.log /var/log/forge-install.log'
```

## Workloads

| Workload | How | Ports |
|---|---|---|
| `base` | Hardened box only | — |
| `coolify` | Official `coolify` image + hardening | 80, 443, 8000 |
| `docker` | Official `docker-ce` image + hardening | — (use `FORGE_EXTRA_PORTS`) |
| `dokploy` | From-scratch (vendor installer) | 80, 443, 3000 |
| `opencode` | From-scratch: opencode + nginx basic-auth, private via SSH tunnel | — (tunnel) |

For an unknown workload: check `hcloud image list --type app` for an official
image; if none, use the vendor's **documented** installer (see
`profiles/from-scratch.md`) — never invent one.

## Teardown
```bash
hcloud server delete <name>
hcloud firewall delete <name>-fw
```

## Files
- `forge.sh` — entrypoint: build cloud-init, create ssh-key/firewall/server, report.
- `lib/harden.sh` — the idempotent hardening script (runs first on the box).
- `lib/workloads.sh` — workload → image / install script / ports.
- `lib/install-opencode.sh`, `lib/install-dokploy.sh` — from-scratch installers.
- `profiles/*.md` — per-workload playbooks.

## Host env
- `hcloud` CLI with a **Read & Write** token in the active context.
- `python3` (used for the key-reuse lookup). `openssl` (password generation).
