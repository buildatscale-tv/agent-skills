---
name: hetzner-forge
description: Provision a hardened, ready-to-go Hetzner Cloud box with Pulumi, in one guided flow. Invoked via `/hetzner-forge <freeform>` or natural-language requests ("spin up a Coolify box", "give me a hardened Hetzner server", "tear down the forge box"). The agent scaffolds a brand-new Pulumi project in the user's workspace (NEVER runs anything in the skill directory), keeps all state locally in the project (no Pulumi Cloud), writes Pulumi config, runs `pulumi up`, and reports connection details. SSH and admin ports are locked to the user's own IPs; only registry-declared public app ports face the internet. Secrets never touch cloud-init/user_data. Defaults to official Hetzner app images when one exists (then layers hardening); falls back to a documented from-scratch install when no image exists. Also handles teardown and status.
---

# /hetzner-forge

Stand up a hardened Hetzner Cloud box, managed as code with Pulumi. One base
layer (non-root sudo user, key-only SSH with root login disabled, UFW,
fail2ban, unattended upgrades, Hetzner Cloud Firewall attached at creation)
plus a pluggable workload (Coolify, Docker, Dokploy, OpenCode, or a custom
target you resolve on the fly) and optional peripherals.

The skill ships only the Pulumi **domain logic** in `program/` (next to this
file) — it has no `Pulumi.yaml`/`package.json` and **cannot run in place**.
Every invocation scaffolds a fresh, self-contained Pulumi project in the
user's workspace, copies `program/` into it, and drives everything there.

## Operating principle

**You run the commands — the user does not.** This skill is agent-driven: you
execute the `hcloud`, `pulumi`, `npm`, and shell steps yourself. Never hand the
user a list of commands to run. Ask the user only for:

- **decisions** (workload, region, size, peripherals, where the project lives),
- **secrets you cannot derive** (e.g. a Tailscale auth key), and
- **confirmation** before anything that creates, changes, or destroys real
  resources (`pulumi up`, `pulumi destroy`).

Derive everything else automatically — the Hetzner token from the active
`hcloud` context, the SSH key from `~/.ssh`, your IPs for `adminCidrs`, ports
from the workload. The command blocks below are for **you** to run, not to
paste at the user.

**Absolute rules:**

1. **Never run anything in the skill's own directory.** No `npm install`, no
   `pulumi` commands, nothing. All work happens in the scaffolded project.
2. **State is local only.** Project-local `file://` backend inside the project
   directory. Never `pulumi login` to Pulumi Cloud.
3. **Secrets are Pulumi secrets** (`--secret`) and travel to the box only over
   SSH — never via cloud-init/user_data (the program enforces this; keep it
   that way if you ever touch it).
4. **No world-open defaults.** SSH + admin ports are scoped to the user's
   detected CIDRs. Only registry-declared public app ports (80/443 on app
   platforms) face the internet, plus anything the user explicitly puts in
   `publicPorts`.
5. The state dir, passphrase file, and stack config must be git-ignored
   **before** the first `pulumi up`.

## Parsing the argument

| Pattern | Mode | What to do |
|---|---|---|
| "spin up X", "give me a hardened box", "new Coolify server" | Create | Run the Create flow |
| "status", "what's the forge box's IP", "is it up" | Status | `pulumi stack output` in the recorded project dir (see Status) |
| "tear down", "destroy the box", "kill forge" | Teardown | Run the Teardown flow |
| "add a volume / firewall port / private network to X" | Amend | Set the relevant config key in the project, `pulumi up` again |

---

## Create flow

### Step 0: Preflight

Run these checks and fix/surface any failure before continuing:

```bash
command -v hcloud  && hcloud version | head -1        # CLI present
hcloud context active                                  # a project token is selected
hcloud context list                                    # show the user their options
command -v pulumi && pulumi version                    # Pulumi present
command -v node   && node --version                    # Node 18+ for the TS program
```

- If `hcloud` is missing: install via `brew install hcloud` (macOS) or the [releases](https://github.com/hetznercloud/cli).
- If no active context: `hcloud context create <name>` (prompts for an API token from the Hetzner console → Security → API Tokens; the token needs **Read & Write**).
- Confirm with the user **which project/context** to deploy into — this is which Hetzner project gets billed.

### Step 1: Gather choices

Ask the user (offer these as options; use sensible defaults so a user can just say "defaults"):

1. **Project location** — where the scaffolded Pulumi project lives. Default `infra/` in the current working directory, or a new `<name>-infra/` when there's no repo. **Record the absolute path** — Status/Teardown/Amend all need it later.
2. **Workload** — `base` (just a hardened box), `coolify`, `docker`, `dokploy`, `opencode` (an OpenCode server, browser UI behind a login — see `profiles/opencode.md`), or something else (→ Step 2 resolution). Default `base`.
3. **Access model** — `ssh` (hardened key-only) or `tailscale` (mesh + SSH fallback). If `tailscale`, ask for a Tailscale **auth key** (from the Tailscale admin console; a one-off/ephemeral key is ideal). Default `ssh`.
4. **Region** — `hil` (US-West/Hillsboro), `ash` (US-East), `fsn1`/`nbg1`/`hel1` (EU), `sin` (APAC). Default `hil` (closest to the user in Oregon).
5. **Size** — a server type. Default `cpx21` (3 vCPU / 4 GB). Note **`hil` only offers the `cpxN1` line** (`cpx11/21/31/41/51`) — `cpx22`/newer gen is EU-only, so `cpx22` in `hil` errors. For Coolify/Dokploy/OpenCode suggest **≥ `cpx21`** (4 GB min). Check a region: `hcloud datacenter describe hil-dc1 -o json | python3 -c 'import sys,json;print(json.load(sys.stdin)["server_types"]["available"])'`.
6. **Peripherals** (optional, default all off) — attached volume (GB), private network, stable primary IP, extra admin ports (`extraPorts`, you-only), swap. Only mention `publicPorts` if the user asks to serve public traffic beyond what the workload already opens.
7. **SSH key** — confirm the public key to authorize. Default `~/.ssh/id_ed25519.pub`; if absent, offer to generate one: `ssh-keygen -t ed25519 -C "hetzner-forge"`.

You do **not** ask about port exposure per box: the workload registry decides
(dashboards = you-only, platform web traffic = public). See "Port model" below.

### Step 2: Resolve the workload

For anything **not** in the built-in registry (`base`, `coolify`, `docker`, `dokploy`, `opencode`), resolve it in this order and tell the user which path you took:

1. **Official Hetzner app image?** Check the live catalog:
   ```bash
   hcloud image list --type app -o columns=name,description | rg -i '<workload>'
   ```
   If a matching image exists → set `workload=custom` + `customImage=<name>` + ports (next bullet). The program boots the image and hardens over SSH.

2. **No image → documented from-scratch.** Look up the provider's **official** install docs (WebSearch/WebFetch the vendor site), extract the one-line/idempotent install command and the ports the app needs. Then set `workload=custom` + `customInstall="<command>"` + ports + `customDocs=<source URL>`. Record the source URL so the procedure is auditable. See `profiles/from-scratch.md`.

**Port classification for custom workloads:** admin/dashboard/control ports go
in `customPorts` (scoped to the user's IPs); ports that must serve the public
internet go in `publicPorts`. When in doubt, classify as admin.

Never invent an installer. Use the vendor's documented method or an official image — nothing else.

### Step 3: Scaffold the project

You create the project from scratch — the skill ships no boilerplate. In the
chosen location (absolute path recorded in Step 1):

```bash
mkdir -p <project> && cd <project>
```

**1. `Pulumi.yaml`** (project name: lowercase letters/digits/dashes, e.g. `forge-infra`):

```yaml
name: forge-infra
runtime: nodejs
description: Hardened Hetzner Cloud box, provisioned by the hetzner-forge skill.
```

**2. `package.json`** — pin exactly the known-good versions (table at the
bottom of this file; bump only if a version was yanked, and tell the user):

```json
{
  "name": "forge-infra",
  "version": "0.1.0",
  "private": true,
  "main": "index.ts",
  "scripts": { "typecheck": "tsc --noEmit" },
  "devDependencies": {
    "@types/node": "22.20.1",
    "ts-node": "10.9.2",
    "typescript": "5.9.3"
  },
  "dependencies": {
    "@pulumi/command": "1.2.1",
    "@pulumi/hcloud": "1.39.1",
    "@pulumi/pulumi": "3.253.0"
  }
}
```

**3. `tsconfig.json`:**

```json
{
  "ts-node": { "transpileOnly": true },
  "compilerOptions": {
    "strict": true,
    "outDir": "bin",
    "target": "es2020",
    "module": "commonjs",
    "moduleResolution": "node",
    "sourceMap": true,
    "experimentalDecorators": true,
    "pretty": true,
    "noFallthroughCasesInSwitch": true,
    "forceConsistentCasingInFileNames": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "lib": ["es2020"]
  },
  "include": ["index.ts", "src/**/*.ts"],
  "exclude": ["node_modules", "bin"]
}
```

**4. `.gitignore`** — every entry here is **mandatory** (it protects state and
secrets). `package-lock.json` is deliberately NOT ignored — commit it for
reproducibility:

```gitignore
node_modules/
bin/
.pulumi/
.pulumi-passphrase
Pulumi.*.yaml
!Pulumi.yaml
*.log
.env
```

**5. Copy the domain logic out of the skill** (resolve `<skill-dir>` to this
skill's absolute directory):

```bash
cp -R <skill-dir>/program/index.ts <skill-dir>/program/src <skill-dir>/program/scripts .
```

**6. Install + typecheck before touching any cloud resource:**

```bash
npm install          # commit the resulting package-lock.json if this is a repo
npm run typecheck    # must pass before the first `pulumi up`
```

### Step 4: Local state + secrets backend

State stays in the project, encrypted with a passphrase only this machine knows:

```bash
cd <project>
openssl rand -base64 32 > .pulumi-passphrase && chmod 600 .pulumi-passphrase
export PULUMI_CONFIG_PASSPHRASE="$(cat .pulumi-passphrase)"
pulumi login "file://$PWD/.pulumi"
pulumi stack init prod --secrets-provider passphrase
```

- `PULUMI_CONFIG_PASSPHRASE` must be exported in **every** shell that runs a
  `pulumi` command (Status/Teardown/Amend included). Never print the
  passphrase, never commit the file.
- If the project is (or becomes) a git repo, verify ignores **before**
  `pulumi up`: `git check-ignore .pulumi/ .pulumi-passphrase Pulumi.prod.yaml`
  must print all three.
- Warn the user once: **the project directory is the only handle on this
  infrastructure.** Losing it (or the passphrase) orphans the box — Pulumi can
  no longer manage or destroy it. Keep the directory; never commit `.pulumi/`.

### Step 5: Configure

Unprefixed keys are read by `src/config.ts` (the source of truth for every
knob and default); `hcloud:token` is the provider credential.

```bash
# Provider token — derive it from the active hcloud context; don't ask the user to paste it:
TOKEN=$(python3 -c "import tomllib,os; d=tomllib.load(open(os.path.expanduser('~/.config/hcloud/cli.toml'),'rb')); a=d['active_context']; print(next(c['token'] for c in d['contexts'] if c['name']==a))")
pulumi config set hcloud:token "$TOKEN" --secret

# Core
pulumi config set name         forge
pulumi config set location     hil
pulumi config set serverType   cpx21
pulumi config set workload     coolify
pulumi config set access       ssh
pulumi config set sshPublicKey "$(cat ~/.ssh/id_ed25519.pub)"

# Your IPs — REQUIRED, there is no world-open default. SSH and admin ports are
# reachable only from these CIDRs. Detect IPv4 (and IPv6 when present):
V4="$(curl -s https://api.ipify.org)/32"
V6="$(curl -s https://api6.ipify.org 2>/dev/null || true)"
CIDRS="$V4"; [ -n "$V6" ] && CIDRS="$CIDRS,$V6/128"
pulumi config set adminCidrs "$CIDRS"

# OpenCode workload (workload=opencode) — see profiles/opencode.md:
# pulumi config set opencodeApiKey "$OPENCODE_KEY" --secret          # the user's opencode-go key
# pulumi config set opencodePassword "$(openssl rand -base64 18 | tr -dc A-Za-z0-9)" --secret
# pulumi config set opencodeUsername forge   # web-login username (default: opencode)

# Access = tailscale also needs:
# pulumi config set tailscaleAuthKey "$TS_KEY" --secret

# Custom workload (from Step 2) example:
# pulumi config set workload custom
# pulumi config set customInstall "curl -sSL https://example.com/install.sh | sh"
# pulumi config set customPorts "3000"          # admin/dashboard ports → you-only
# pulumi config set publicPorts "80,443"        # world-open, only if it serves the public
# pulumi config set customDocs "https://docs.example.com/install"

# Peripherals (only what they asked for):
# pulumi config set volumeSizeGb 50
# pulumi config set privateNetwork true
# pulumi config set extraPorts "8080,9000"      # additional you-only ports
```

The CLI token must be **Read & Write** for Pulumi to manage resources. If the
active context's token is read-only, tell the user and have them create a Read &
Write token (Hetzner console → Security → API Tokens) — that's a decision only
they can make.

### Step 6: Preview + apply

```bash
pulumi preview      # show the user what will be created
pulumi up --yes     # after they confirm
```

### Step 7: Report

Print the outputs, especially `nextSteps` (it states exactly which ports are
you-only vs public):

```bash
pulumi stack output nextSteps
pulumi stack output ipv4
pulumi stack output sshCommand
```

Cloud-init / post-boot steps take ~2-8 minutes after the server shows
`running`. Tell the user to watch it:
`ssh <user>@<ip> 'sudo tail -f /var/log/hetzner-forge-harden.log'` or check
`cloud-init status --wait`.

**End your report with the recorded project path** ("managed from
`<absolute path>` — status/teardown run there") so future sessions can find it.

---

## Status

```bash
cd <project>                                            # the recorded project dir
export PULUMI_CONFIG_PASSPHRASE="$(cat .pulumi-passphrase)"
pulumi stack output                                     # all outputs
hcloud server list                                      # live view of the box
```

If the project path is unknown, check `infra/` in the current repo, then
`~/*-infra` / `<cwd>/*-infra`, then ask the user.

## Teardown

```bash
cd <project>
export PULUMI_CONFIG_PASSPHRASE="$(cat .pulumi-passphrase)"
pulumi destroy --yes          # removes server, firewall, volume, network, IP
# pulumi stack rm prod        # optional: drop the stack entirely
```

Warn the user that `pulumi destroy` deletes the volume and its data unless they
detached/snapshotted it first. After a full teardown the project directory
holds only empty state — safe to delete, but only after `destroy` succeeded.

---

## Notes that matter

- **Secrets architecture.** The Hetzner token and Tailscale/opencode keys are
  Pulumi secrets, encrypted in the local state by the passphrase. On the box,
  cloud-init `user_data` carries **no secrets at all** (it's readable via the
  Hetzner console/API and the box's metadata endpoint): from-scratch hardening
  needs none, the Tailscale auth key is delivered by a post-boot
  `tailscale up` over SSH, and secret-bearing installers (opencode) run
  entirely over SSH. Never reintroduce a secret into `buildCloudInit`.
- **Port model.** The registry classifies each workload's ports: dashboards /
  control UIs (Coolify :8000, Dokploy :3000) are **admin ports**, reachable
  only from `adminCidrs`; the web traffic a platform serves (80/443) is
  **public**, world-open. `base`/`docker`/`opencode` open nothing. Users add
  their own via `extraPorts` (admin) / `publicPorts` (public). The Hetzner
  Cloud Firewall is attached **at server creation** — there is no unfirewalled
  window — and UFW mirrors the same policy on the host.
- **Official image + hardening tension.** Hetzner app images (coolify,
  docker-ce, …) run their own first-boot setup. We do **not** pass our own
  cloud-init for those — we boot the image and run `harden.sh` over SSH
  afterwards (the "post-harden" path), connecting as root. From-scratch
  workloads harden via cloud-init on first boot instead; the same
  `harden.sh` locks root SSH (`PermitRootLogin no`, `AllowUsers <admin>`)
  as its **last** step. From-scratch post-boot steps (Tailscale auth,
  secret-bearing installs) connect as the admin user with `sudo`. If one
  fails because the admin user didn't exist yet, simply re-run `pulumi up`
  — it converges deterministically.
- **Docker bypasses UFW.** Published container ports skip UFW via Docker's
  iptables chain. The **Hetzner Cloud Firewall** is the authoritative ingress
  gate; UFW hardens host-level services.
- **Locked out?** If the user's IP changes, the box is unreachable until
  `adminCidrs` is updated: `pulumi config set adminCidrs <new>/32 && pulumi up`
  (or edit the firewall in the Hetzner console, which also offers a web
  console as a last resort).
- **Post-boot SSH needs a private key.** The remote steps use
  `sshPrivateKeyPath` (default `~/.ssh/id_ed25519`) — the private counterpart
  of `sshPublicKey`. Image-based hardening connects as root; from-scratch
  post-boot steps connect as the admin user with `sudo`. The private key is
  stored as a secret in state.
- **Tailscale.** Prefer ephemeral/one-off auth keys. With `access=tailscale`,
  SSH remains as a fallback, still scoped to `adminCidrs`.

## Known-good dependency versions

Pinned for reproducibility. Write these exact versions into the scaffolded
`package.json`; bump only if one was yanked upstream, and tell the user.

| Package | Version |
|---|---|
| `@pulumi/pulumi` | 3.253.0 |
| `@pulumi/hcloud` | 1.39.1 |
| `@pulumi/command` | 1.2.1 |
| `typescript` | 5.9.3 |
| `ts-node` | 10.9.2 |
| `@types/node` | 22.20.1 |

## Files

- `program/index.ts` — the program: SSH key, firewall (attached at creation), server, peripherals, post-boot SSH steps, outputs.
- `program/src/config.ts` — typed config loader (every knob the skill sets).
- `program/src/workloads.ts` — workload registry + custom resolution, port classification.
- `program/src/hardening.ts` — builds cloud-init (secret-free) and the SSH-delivered env prefixes.
- `program/src/peripherals.ts` — location → network zone mapping.
- `program/scripts/harden.sh` — the idempotent hardening script (both paths).
- `program/scripts/install-opencode.sh` — the OpenCode workload installer (runs over SSH).
- `profiles/coolify.md`, `profiles/dokploy.md`, `profiles/opencode.md`, `profiles/from-scratch.md` — per-workload playbooks.

## Host env

- `hcloud` CLI with a **Read & Write** token in the active context.
- `pulumi` (local `file://` backend only — never Pulumi Cloud).
- `node` 18+ and network access to install the scaffolded project's npm deps.
