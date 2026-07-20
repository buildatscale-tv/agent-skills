# /hetzner-forge

Spin up a **hardened, preconfigured Hetzner Cloud box** with one guided flow —
assembled and managed as code with **Pulumi (TypeScript)**. A foundational
`/infra` you can point at whatever it turns out to be: a plain hardened server,
Coolify, Docker, Dokploy, or any provider you resolve on the fly.

The skill hand-holds you through setup (`SKILL.md`); the `pulumi/` directory is
the reusable program it drives.

## What you get

Every box ships with the same **base hardening**, then layers your workload:

- Non-root **sudo user** with your SSH key; root login set to `prohibit-password`
- **Key-only SSH** (password auth off), `MaxAuthTries` capped
- **UFW** default-deny incoming + **fail2ban** on sshd
- **Unattended security upgrades**, timezone, optional swap
- A **Hetzner Cloud Firewall** as the authoritative ingress gate
- Your choice of **access model**: hardened public SSH, or **Tailscale** mesh with SSH as a locked-down fallback

## Workloads

| Workload | How it's provisioned | Ports opened |
|---|---|---|
| `base` | Just the hardened box | — |
| `coolify` | Official Hetzner **`coolify`** image + post-harden | 80, 443, 8000 |
| `docker` | Official **`docker-ce`** image + post-harden | — (add via `extraPorts`) |
| `dokploy` | **From-scratch** (no image) via the vendor installer | 80, 443, 3000 |
| `opencode` | **From-scratch** OpenCode server — `opencode serve` behind nginx basic-auth, run as a non-sudo user, reached via SSH tunnel | — (tunnel) |
| `custom` | Skill-resolved: official image if one exists, else documented from-scratch | you specify |

**The rule:** prefer a supported Hetzner path (official app image) when one
exists; fall back to the provider's **documented** install procedure only when
no image is available. The skill checks `hcloud image list --type app` live and
looks up vendor docs for anything unknown — see `profiles/from-scratch.md`.

## Quick start

```bash
cd pulumi
npm install
pulumi stack init prod

pulumi config set hcloud:token "$HETZNER_TOKEN" --secret
pulumi config set workload coolify
pulumi config set sshPublicKey "$(cat ~/.ssh/id_ed25519.pub)"

pulumi up
pulumi stack output nextSteps
```

Or just ask an agent: **"/hetzner-forge spin up a Coolify box in Hillsboro"** and
it will run the whole flow, asking only what it needs.

## Configuration

There's no example/placeholder config to copy — the skill sets every value with
`pulumi config set`. Every knob and its default is the typed loader in
`pulumi/src/config.ts` (the source of truth). Highlights:

| Key | Default | Notes |
|---|---|---|
| `location` | `hil` | `hil` (US-West), `ash` (US-East), `fsn1`/`nbg1`/`hel1` (EU), `sin` (APAC) |
| `serverType` | `cpx21` | 3 vCPU / 4 GB. **`hil` only offers the `cpxN1` line** — `cpx22`/newer is EU-only |
| `access` | `ssh` | `ssh` or `tailscale` (needs `tailscaleAuthKey --secret`) |
| `sshSource` | `0.0.0.0/0` | CIDR allowed to reach SSH — tighten to your IP/32 |
| `volumeSizeGb` | `0` | >0 attaches a formatted, automounted volume |
| `privateNetwork` | `false` | private network + subnet, box attached |
| `primaryIpv4` | `false` | stable IPv4 that survives rebuilds (needs `primaryIpDatacenter`) |
| `extraPorts` | — | extra ingress TCP ports, e.g. `8080,9000` |

## How the two hardening paths work

- **Official app image** (coolify/docker): the image runs its own first-boot
  setup, so we don't fight it with our own cloud-init. The box boots the image,
  then Pulumi SSHes in and runs `harden.sh` (the "post-harden" step). Requires
  `sshPrivateKeyPath` (default `~/.ssh/id_ed25519`).
- **From-scratch** (dokploy/base/custom-install): `harden.sh` and the workload
  installer run via cloud-init on first boot, before the box is exposed.

Same `scripts/harden.sh` in both — one source of truth.

> **Docker + UFW:** published container ports bypass UFW via Docker's iptables
> chain. For Docker-based workloads the **Hetzner Cloud Firewall** is what
> actually gates ingress; UFW is there for host-level services.

## Teardown

```bash
pulumi destroy      # removes everything this stack created
```

Snapshot or detach any volume first if you want to keep its data.

## Requirements

- `hcloud` CLI with a **Read & Write** API token in the active context
- `pulumi` + a state backend (Pulumi Cloud or `pulumi login --local`)
- Node 18+

## Layout

```
hetzner-forge/
├── SKILL.md              # the guided setup flow (what agents follow)
├── README.md             # this file
├── profiles/             # per-workload playbooks
│   ├── coolify.md
│   ├── dokploy.md
│   ├── opencode.md
│   └── from-scratch.md
└── pulumi/               # the self-contained Pulumi TypeScript program
    ├── Pulumi.yaml       # project file (per-stack Pulumi.<stack>.yaml is generated, gitignored)
    ├── package.json      # deps pinned to exact versions (no drift)
    ├── tsconfig.json
    ├── index.ts
    ├── src/{config,workloads,hardening,peripherals}.ts
    └── scripts/{harden.sh, install-opencode.sh}
```
