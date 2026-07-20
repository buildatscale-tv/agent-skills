# Profile: From-scratch / custom workload

When someone asks for a workload with no built-in registry entry (e.g.
"OpenDeploy", "CapRover", "Appwrite"), resolve it here. The goal: **use a
supported Hetzner path by default, and only go from-scratch when necessary —
and when you do, use the provider's documented procedure, not an improvised one.**

## Resolution order

### 1. Is there an official Hetzner app image?

```bash
hcloud image list --type app -o columns=name,description | rg -i '<workload>'
```

If yes → image path:

```bash
pulumi config set workload    custom
pulumi config set customImage <image-name>
pulumi config set customPorts "<ports the app needs>"
pulumi config set customDocs  "<vendor docs URL>"
```

The program boots the image and hardens over SSH (same as coolify/docker).

### 2. No image → documented from-scratch

1. Find the provider's **official** installation docs (search the vendor's site / GitHub README — not a random blog).
2. Extract the idempotent install command (ideally a single `curl … | sh` the vendor publishes) and the ports the app listens on.
3. Configure:

```bash
pulumi config set workload     custom
pulumi config set customInstall "curl -sSL https://<vendor>/install.sh | sh"
pulumi config set customPorts  "80,443,<app-port>"
pulumi config set customDocs   "https://<vendor>/docs/install"
```

`harden.sh` runs first via cloud-init, then `customInstall` runs. Record
`customDocs` so the procedure stays auditable.

## Guardrails

- **Never invent an installer.** Only use an official image or the vendor's documented command. If you can't find a documented method, stop and tell the user rather than guessing.
- **Base image** for from-scratch is `ubuntu-24.04` (override with `baseImage` if the vendor requires a specific distro — then verify hardening still applies).
- **Ports:** only open what the app documents. Everything ingress goes through the Hetzner Cloud Firewall.
- **Docker workloads:** remember published container ports bypass UFW — the Cloud Firewall is the real gate.
- **Promote repeat workloads.** If you provision the same custom target more than once, add it to the registry in `pulumi/src/workloads.ts` (with its image/install + ports + docs) so it becomes a first-class option.

## Example: a provider with no image yet

> "Spin up an OpenDeploy box."

1. `hcloud image list --type app | rg -i opendeploy` → no match.
2. Fetch OpenDeploy's official install docs; find the documented install command + required ports.
3. `pulumi config set workload custom`, `customInstall="<their command>"`, `customPorts="<their ports>"`, `customDocs="<their docs URL>"`.
4. `pulumi up`. Report the dashboard URL from the vendor docs.
