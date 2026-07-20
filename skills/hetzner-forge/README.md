# /hetzner-forge

Spin up a **hardened, preconfigured Hetzner Cloud box** with one guided flow —
assembled and managed as code with **Pulumi (TypeScript)**. A foundational
`/infra` you can point at whatever it turns out to be: a plain hardened server,
Coolify, Docker, Dokploy, OpenCode, or any provider you resolve on the fly.

The skill hand-holds an agent through setup (`SKILL.md`): it **scaffolds a
brand-new Pulumi project in your workspace** (the skill itself ships only the
domain logic in `program/` and never runs in place), keeps **all state locally**
in that project (no Pulumi Cloud), and locks the box to **your IPs only** —
SSH and admin dashboards are never exposed to the open internet.

## What you get

Every box ships with the same **base hardening**, then layers your workload:

- Non-root **sudo user** with your SSH key; **root login disabled** and `AllowUsers` restricted
- **Key-only SSH** (password auth off), `MaxAuthTries` capped
- **UFW** default-deny incoming + **fail2ban** on sshd
- **Unattended security upgrades**, timezone, optional swap
- A **Hetzner Cloud Firewall attached at server creation** — no unfirewalled window — as the authoritative ingress gate
- Your choice of **access model**: hardened SSH scoped to your IPs, or **Tailscale** mesh with SSH as a locked-down fallback

## Port model

The workload registry classifies every port:

| Class | Reachable from | Examples |
|---|---|---|
| SSH + admin ports | **Your detected IPs only** (`adminCidrs`) | SSH :22, Coolify dashboard :8000, Dokploy dashboard :3000 |
| Public ports | The world | 80/443 on app platforms (Coolify/Dokploy) |
| *(none)* | — | `base`, `docker`, and `opencode` open nothing extra |

Add your own with `extraPorts` (you-only) or `publicPorts` (world-open — only
when a box should genuinely serve the public internet).

## Secrets

- The Hetzner token and any Tailscale/opencode keys are **Pulumi secrets**, encrypted in the local state by a per-project passphrase (a 0600, git-ignored file).
- cloud-init `user_data` carries **no secrets at all** (it's visible via the Hetzner console and the box's metadata endpoint). Secret-bearing steps — `tailscale up`, the OpenCode install — run post-boot **over SSH**.
- SSH and admin dashboards are scoped to your IPs; the OpenCode box opens no ports at all and is reached via SSH tunnel.

## Workloads

| Workload | How it's provisioned | Admin ports (you-only) | Public ports (world) |
|---|---|---|---|
| `base` | Just the hardened box | — | — |
| `coolify` | Official Hetzner **`coolify`** image + post-harden | 8000 | 80, 443 |
| `docker` | Official **`docker-ce`** image + post-harden | — | — (add via `extraPorts`/`publicPorts`) |
| `dokploy` | **From-scratch** (no image) via the vendor installer | 3000 | 80, 443 |
| `opencode` | **From-scratch** OpenCode server — `opencode serve` with native web auth, run as a non-sudo user, installed over SSH, reached via SSH tunnel | — | — |
| `custom` | Skill-resolved: official image if one exists, else documented from-scratch | you specify (`customPorts`) | you specify (`publicPorts`) |

**The rule:** prefer a supported Hetzner path (official app image) when one
exists; fall back to the provider's **documented** install procedure only when
no image is available. The skill checks `hcloud image list --type app` live and
looks up vendor docs for anything unknown — see `profiles/from-scratch.md`.

## Quick start

Ask an agent: **"/hetzner-forge spin up a Coolify box in Hillsboro"** — it
scaffolds the project, configures it, and runs the whole flow, asking only
what it needs.

Doing it by hand (what the agent does for you):

```bash
mkdir my-forge-infra && cd my-forge-infra
# write Pulumi.yaml, package.json, tsconfig.json, .gitignore (see SKILL.md Step 3)
cp -R <skill-dir>/program/index.ts <skill-dir>/program/src <skill-dir>/program/scripts .
npm install && npm run typecheck

openssl rand -base64 32 > .pulumi-passphrase && chmod 600 .pulumi-passphrase
export PULUMI_CONFIG_PASSPHRASE="$(cat .pulumi-passphrase)"
pulumi login "file://$PWD/.pulumi"
pulumi stack init prod --secrets-provider passphrase

pulumi config set hcloud:token "$HETZNER_TOKEN" --secret
pulumi config set workload coolify
pulumi config set sshPublicKey "$(cat ~/.ssh/id_ed25519.pub)"
pulumi config set adminCidrs "$(curl -s https://api.ipify.org)/32"

pulumi up
pulumi stack output nextSteps
```

## Configuration

There's no example config to copy — every value is set with `pulumi config set`.
Every knob and its default is the typed loader in `program/src/config.ts` (the
source of truth). Highlights:

| Key | Default | Notes |
|---|---|---|
| `location` | `hil` | `hil` (US-West), `ash` (US-East), `fsn1`/`nbg1`/`hel1` (EU), `sin` (APAC) |
| `serverType` | `cpx21` | 3 vCPU / 4 GB. **`hil` only offers the `cpxN1` line** — `cpx22`/newer is EU-only |
| `access` | `ssh` | `ssh` or `tailscale` (needs `tailscaleAuthKey --secret`) |
| `adminCidrs` | **required** | Your CIDRs (comma-separated v4/v6). SSH + admin ports are reachable only from these — there is no world-open default |
| `extraPorts` | — | extra admin-scoped TCP ports (you-only), e.g. `8080,9000` |
| `publicPorts` | — | explicitly world-open TCP ports |
| `volumeSizeGb` | `0` | >0 attaches a formatted, automounted volume |
| `privateNetwork` | `false` | private network + subnet, box attached |
| `primaryIpv4` | `false` | stable IPv4 that survives rebuilds (needs `primaryIpDatacenter`) |

## How the two hardening paths work

- **Official app image** (coolify/docker): the image runs its own first-boot
  setup, so we don't fight it with our own cloud-init. The box boots the image,
  then Pulumi SSHes in and runs `harden.sh` (the "post-harden" step).
- **From-scratch** (dokploy/base/custom-install): `harden.sh` runs via
  cloud-init on first boot. The installer runs there too **only if it needs no
  secrets** (dokploy); secret-bearing installers (opencode) and
  `tailscale up` run post-boot over SSH instead.

Same `scripts/harden.sh` in both — one source of truth. It applies the SSH
lockdown (`PermitRootLogin no`, `AllowUsers <admin>`) as its **last** step so
post-boot SSH steps can connect during first boot.

> **Docker + UFW:** published container ports bypass UFW via Docker's iptables
> chain. For Docker-based workloads the **Hetzner Cloud Firewall** is what
> actually gates ingress; UFW is there for host-level services.

## State, status, teardown

All Pulumi state lives in the project directory (`.pulumi/`, encrypted with
`.pulumi-passphrase`). **The project directory is the only handle on the
infrastructure** — lose it (or the passphrase) and the box is orphaned. Keep
the directory; never commit `.pulumi/` or the passphrase.

```bash
cd <project>
export PULUMI_CONFIG_PASSPHRASE="$(cat .pulumi-passphrase)"
pulumi stack output      # status
pulumi destroy           # removes everything this stack created
```

Snapshot or detach any volume first if you want to keep its data.

## Requirements

- `hcloud` CLI with a **Read & Write** API token in the active context
- `pulumi` (local `file://` backend — never Pulumi Cloud)
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
└── program/              # domain logic only — copied into the scaffolded project
    ├── index.ts          #   (deliberately NOT a runnable project:
    ├── src/              #    no Pulumi.yaml/package.json ship with the skill)
    └── scripts/
```
