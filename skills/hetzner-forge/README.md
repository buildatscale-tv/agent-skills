# /hetzner-forge

Spin up a **hardened, preconfigured Hetzner Cloud box** with one guided flow —
built with the **`hcloud` CLI + cloud-init**. A foundational `/infra` you can
point at whatever it turns out to be: a plain hardened server, Coolify, Docker,
Dokploy, or an OpenCode server you drive from your browser.

No Pulumi, no state backend, no language runtime — just `hcloud` and a cloud-init
script. The skill hand-holds setup (`SKILL.md`); `forge.sh` is the entrypoint.

## What you get

Every box ships with the same **base hardening** (`lib/harden.sh`), then layers a
workload:

- Non-root **sudo user** with your SSH key; root login `prohibit-password`
- **Key-only SSH** (`MaxAuthTries 3`, no password auth)
- **UFW** default-deny + **fail2ban** on sshd
- **Unattended security upgrades**, timezone, optional swap
- A **Hetzner Cloud Firewall** as the authoritative ingress gate

## Workloads

| Workload | How | Ports |
|---|---|---|
| `base` | Just the hardened box | — |
| `coolify` | Official Hetzner `coolify` image + hardening | 80, 443, 8000 |
| `docker` | Official `docker-ce` image + hardening | — (`FORGE_EXTRA_PORTS`) |
| `dokploy` | From-scratch via the vendor installer | 80, 443, 3000 |
| `opencode` | From-scratch: `opencode serve` behind **nginx basic-auth**, reached privately over an SSH tunnel | — (tunnel) |

## Quick start

```bash
export FORGE_SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)"
export FORGE_NAME=forge-oc FORGE_WORKLOAD=opencode FORGE_TYPE=cpx21 FORGE_LOCATION=hil
export FORGE_OPENCODE_API_KEY="$OPENCODE_KEY" FORGE_OPENCODE_USER=forge
bash forge.sh
# forge.sh --print-user-data  → build+print the cloud-init, create nothing
```

Or ask an agent: **"/hetzner-forge make me an OpenCode box in Hillsboro"** and it
runs the flow, asking only what it needs.

## The OpenCode box

`opencode serve` has no built-in auth, so it binds `127.0.0.1:4097` and **nginx**
fronts it on `:4096` with an HTTP basic-auth login (username + generated
password). The access port stays **closed on the public firewall** — reach it
privately over an SSH tunnel:

```bash
# just this Mac
ssh -L 4096:localhost:4096 <adminUser>@<ip>            # then http://localhost:4096
# phone / other LAN devices
ssh -L 0.0.0.0:4096:localhost:4096 <adminUser>@<ip>    # then http://<mac-lan-ip>:4096
```

It authenticates with your **opencode-go** subscription (the API key you supply
is written to `~/.local/share/opencode/auth.json` on the box). See
`profiles/opencode.md`.

## Config (FORGE_* env)

All documented in `forge.sh`'s header. Highlights: `FORGE_NAME`, `FORGE_LOCATION`
(`hil` default — note hil only offers the `cpxN1` line), `FORGE_TYPE` (`cpx21`),
`FORGE_WORKLOAD`, `FORGE_ACCESS` (`ssh`|`tailscale`), `FORGE_SSH_PUBKEY`,
`FORGE_EXTRA_PORTS`, `FORGE_TAILSCALE_AUTHKEY`, and the `FORGE_OPENCODE_*` set.

## Teardown

```bash
hcloud server delete <name>
hcloud firewall delete <name>-fw
```

## Requirements

- `hcloud` CLI with a **Read & Write** API token in the active context
- `python3` (key-reuse lookup), `openssl` (password generation)

## Layout

```
hetzner-forge/
├── SKILL.md              # the guided flow (what agents follow)
├── README.md             # this file
├── forge.sh              # entrypoint: cloud-init + hcloud create
├── lib/
│   ├── harden.sh         # base hardening (runs first on the box)
│   ├── workloads.sh      # workload → image / install / ports
│   ├── install-opencode.sh
│   └── install-dokploy.sh
└── profiles/             # per-workload playbooks
    ├── opencode.md  coolify.md  dokploy.md  from-scratch.md
```
