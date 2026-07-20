# Profile: From-scratch / new workload

When someone asks for a workload with no entry in `lib/workloads.sh` (e.g.
"CapRover", "Appwrite"), resolve it here. **Use a supported Hetzner path by
default; only go from-scratch when necessary — and then use the provider's
documented procedure, never an improvised one.**

## Resolution order

### 1. Official Hetzner app image?
```bash
hcloud image list --type app -o columns=name,description | rg -i '<workload>'
```
If yes → add a case to `resolve_workload()` in `lib/workloads.sh`:
`WL_IMAGE="<image-name>"; WL_PORTS="<ports>"`. `forge.sh` boots it and hardens on top.

### 2. No image → documented from-scratch
1. Find the vendor's **official** install docs (their site / GitHub README — not a blog).
2. Extract the idempotent install command and the ports the app listens on.
3. Create `lib/install-<workload>.sh` (a bash script; env like `install-opencode.sh` if it needs secrets), and add a case to `resolve_workload()`:
   `WL_INSTALL="$here/lib/install-<workload>.sh"; WL_PORTS="<ports>"`.
4. `forge.sh` embeds it in cloud-init and runs it after hardening. Record the docs URL in the script.

## Guardrails
- **Never invent an installer.** Official image or vendor-documented command only. If you can't find a documented method, stop and tell the user.
- Base image for from-scratch is `ubuntu-24.04` (`FORGE_BASE_IMAGE` to override — then re-verify hardening applies).
- Open only the ports the app documents (Cloud Firewall via `WL_PORTS` / `FORGE_EXTRA_PORTS`).
- **cloud-init runs as root with `HOME` unset** — set `HOME` in your install script if the installer needs it (a real gotcha; see `install-opencode.sh`).
- Docker workloads: published container ports bypass UFW — the Cloud Firewall is the gate.
