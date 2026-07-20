---
name: hetzner-forge
description: Provision a hardened, ready-to-go Hetzner Cloud box with Pulumi, in one guided flow. Invoked via `/hetzner-forge <freeform>` or natural-language requests ("spin up a Coolify box", "give me a hardened Hetzner server", "tear down the forge box"). Handles preflight (hcloud auth, toolchain), asks for the workload / access model / size / peripherals, writes Pulumi config, runs `pulumi up`, and reports connection details. Defaults to official Hetzner app images when one exists (then layers hardening); falls back to a documented from-scratch install when no image exists. Also handles teardown and status.
---

# /hetzner-forge

Stand up a hardened Hetzner Cloud box, managed as code with Pulumi. One base
layer (non-root sudo user, key-only SSH, UFW, fail2ban, unattended upgrades,
Hetzner Cloud Firewall) plus a pluggable workload (Coolify, Docker, Dokploy, or
a custom target you resolve on the fly) and optional peripherals.

The Pulumi program lives in `pulumi/` next to this file. You copy it into the
user's target project (or run it in place), set config, and `pulumi up`.

## Operating principle

**You run the commands — the user does not.** This skill is agent-driven: you
execute the `hcloud`, `pulumi`, `npm`, and shell steps yourself. Never hand the
user a list of commands to run. Ask the user only for:

- **decisions** (workload, region, size, peripherals),
- **secrets you cannot derive** (e.g. a Tailscale auth key), and
- **confirmation** before anything that creates, changes, or destroys real
  resources (`pulumi up`, `pulumi destroy`).

Derive everything else automatically — the Hetzner token from the active
`hcloud` context, the SSH key from `~/.ssh`, ports from the workload. The
command blocks below are for **you** to run, not to paste at the user.

## Parsing the argument

| Pattern | Mode | What to do |
|---|---|---|
| "spin up X", "give me a hardened box", "new Coolify server" | Create | Run the Create flow |
| "status", "what's the forge box's IP", "is it up" | Status | `pulumi stack output` (see Status) |
| "tear down", "destroy the box", "kill forge" | Teardown | Run the Teardown flow |
| "add a volume / firewall port / private network to X" | Amend | Set the relevant config key, `pulumi up` again |

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

1. **Workload** — `base` (just a hardened box), `coolify`, `docker`, `dokploy`, or something else (→ Step 2 resolution). Default `base`.
2. **Access model** — `ssh` (hardened key-only) or `tailscale` (mesh + SSH fallback). If `tailscale`, ask for a Tailscale **auth key** (from the Tailscale admin console; a one-off/ephemeral key is ideal). Default `ssh`.
3. **Region** — `hil` (US-West/Hillsboro), `ash` (US-East), `fsn1`/`nbg1`/`hel1` (EU), `sin` (APAC). Default `hil` (closest to the user in Oregon).
4. **Size** — a server type. Default `cpx22` (2 vCPU / 4 GB / 80 GB). For Coolify/Dokploy suggest **≥ `cpx22`** (4 GB RAM minimum). Show `hcloud server-type list` if they want the menu.
5. **Peripherals** (optional, default all off) — attached volume (GB), private network, stable primary IP, extra firewall ports, swap.
6. **SSH key** — confirm the public key to authorize. Default `~/.ssh/id_ed25519.pub`; if absent, offer to generate one: `ssh-keygen -t ed25519 -C "hetzner-forge"`.

### Step 2: Resolve the workload

For anything **not** in the built-in registry (`base`, `coolify`, `docker`, `dokploy`), resolve it in this order and tell the user which path you took:

1. **Official Hetzner app image?** Check the live catalog:
   ```bash
   hcloud image list --type app -o columns=name,description | rg -i '<workload>'
   ```
   If a matching image exists → set `workload=custom` + `customImage=<name>` + `customPorts=<the app's ports>`. The program boots the image and hardens over SSH.

2. **No image → documented from-scratch.** Look up the provider's **official** install docs (WebSearch/WebFetch the vendor site), extract the one-line/idempotent install command and the ports the app needs. Then set `workload=custom` + `customInstall="<command>"` + `customPorts=<ports>` + `customDocs=<source URL>`. Record the source URL so the procedure is auditable. See `profiles/from-scratch.md`.

Never invent an installer. Use the vendor's documented method or an official image — nothing else.

### Step 3: Scaffold + configure

Decide where the infra lives. If the user has a target project, copy `pulumi/` into it as `infra/`; otherwise run in place under this skill.

```bash
SRC="$(dirname "$0")/pulumi"          # this skill's pulumi/ template (adjust to install path)
DEST="./infra"                         # or the user's chosen location
cp -R "$SRC" "$DEST" && cd "$DEST"
npm install
pulumi stack init prod                 # or `pulumi stack select prod`
```

Set config (unprefixed keys are read by `src/config.ts`; `hcloud:token` is the provider credential):

```bash
# Provider token — derive it from the active hcloud context; don't ask the user to paste it:
TOKEN=$(python3 -c "import tomllib,os; d=tomllib.load(open(os.path.expanduser('~/.config/hcloud/cli.toml'),'rb')); a=d['active_context']; print(next(c['token'] for c in d['contexts'] if c['name']==a))")
pulumi config set hcloud:token "$TOKEN" --secret

# Core
pulumi config set name        forge
pulumi config set location    hil
pulumi config set serverType  cpx22
pulumi config set workload    coolify
pulumi config set access      ssh
pulumi config set sshPublicKey "$(cat ~/.ssh/id_ed25519.pub)"

# Access = tailscale also needs:
# pulumi config set tailscaleAuthKey "$TS_KEY" --secret

# Custom workload (from Step 2) example:
# pulumi config set workload custom
# pulumi config set customInstall "curl -sSL https://example.com/install.sh | sh"
# pulumi config set customPorts "80,443,3000"
# pulumi config set customDocs "https://docs.example.com/install"

# Peripherals (only what they asked for):
# pulumi config set volumeSizeGb 50
# pulumi config set privateNetwork true
# pulumi config set extraPorts "8080,9000"
```

The CLI token must be **Read & Write** for Pulumi to manage resources. If the
active context's token is read-only, tell the user and have them create a Read &
Write token (Hetzner console → Security → API Tokens) — that's a decision only
they can make.

### Step 4: Preview + apply

```bash
pulumi preview      # show the user what will be created
pulumi up --yes     # after they confirm
```

### Step 5: Report

Print the outputs, especially `nextSteps`:

```bash
pulumi stack output nextSteps
pulumi stack output ipv4
pulumi stack output sshCommand
```

Cloud-init / post-harden takes ~2-8 minutes after the server shows `running`.
Tell the user to watch it:
`ssh <user>@<ip> 'sudo tail -f /var/log/hetzner-forge-harden.log'` (from-scratch)
or check `cloud-init status --wait`.

---

## Status

```bash
pulumi stack output           # all outputs
hcloud server list            # live view of the box
```

## Teardown

```bash
pulumi destroy --yes          # removes server, firewall, volume, network, IP
# pulumi stack rm prod        # optional: drop the stack entirely
```

Warn the user that `pulumi destroy` deletes the volume and its data unless they
detached/snapshotted it first.

---

## Notes that matter

- **Official image + hardening tension.** Hetzner app images (coolify, docker-ce, …) run their own first-boot setup. We do **not** pass our own cloud-init for those — we boot the image and run `harden.sh` over SSH afterwards (the "post-harden" path). From-scratch workloads harden via cloud-init on first boot instead. Both use the same `scripts/harden.sh`.
- **Docker bypasses UFW.** For Docker-based workloads, published container ports skip UFW via Docker's iptables chain. The **Hetzner Cloud Firewall** is the authoritative ingress gate; UFW hardens host-level services. Open workload ports in the firewall (the program does this from the workload's port list + `extraPorts`).
- **Secrets.** Set `hcloud:token` and `tailscaleAuthKey` with `--secret`. The Tailscale key is embedded in `user_data` on the from-scratch path — prefer ephemeral/one-off keys.
- **Post-harden needs a private key.** The image-based path SSHes in as root using `sshPrivateKeyPath` (default `~/.ssh/id_ed25519`) — it must be the private counterpart of `sshPublicKey`.

## Files

- `pulumi/index.ts` — the program: SSH key, firewall, server, peripherals, post-harden.
- `pulumi/src/config.ts` — typed config loader (every knob the skill sets).
- `pulumi/src/workloads.ts` — workload registry + custom resolution.
- `pulumi/src/hardening.ts` — builds cloud-init / the harden env prefix.
- `pulumi/scripts/harden.sh` — the idempotent hardening script (both paths).
- `profiles/coolify.md`, `profiles/dokploy.md`, `profiles/from-scratch.md` — per-workload playbooks.

## Host env

- `hcloud` CLI with a **Read & Write** token in the active context.
- `pulumi` (state backend: Pulumi Cloud or `pulumi login --local`).
- `node` 18+ and network access to install the program's npm deps.
