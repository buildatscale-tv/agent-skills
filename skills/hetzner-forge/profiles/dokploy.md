# Profile: Dokploy

Dokploy is a self-hosted deployment platform. Hetzner has **no** official Dokploy
app image (verified via `hcloud image list --type app`), so this is the
**from-scratch** path: plain Ubuntu + the vendor's documented installer, baked
into cloud-init and run after hardening. The installer needs no secrets, so
running it via cloud-init is safe.

## Config

```bash
pulumi config set workload   dokploy
pulumi config set serverType cpx21     # 3 vCPU / 4 GB
pulumi config set sshPublicKey "$(cat ~/.ssh/id_ed25519.pub)"
```

Watch the region: the default `hil` offers only the `cpxN1` line — `cpx22` is
EU-only and errors in `hil`.

Port policy (registry-decided):

- **Admin (your CIDRs only):** `3000` — the Dokploy dashboard.
- **Public (world):** `80, 443` — deployed apps served via Dokploy's Traefik.

## Flow

1. Server boots plain `ubuntu-24.04` with the Cloud Firewall already attached.
2. cloud-init runs `harden.sh` (sudo user, SSH lockdown with root login disabled, UFW, fail2ban, unattended upgrades).
3. cloud-init runs the documented installer: `curl -sSL https://dokploy.com/install.sh | sh` (installs Docker + Swarm + Dokploy).

## After `pulumi up`

- Dashboard: `http://<ipv4>:3000` — reachable only from your admin CIDRs; finish setup in the browser.
- Deployed apps are served publicly on 80/443.
- Watch progress: `ssh <user>@<ip> 'sudo tail -f /var/log/hetzner-forge-install.log'`.

## Notes

- The installer requires a **fresh** host (it sets up Docker Swarm). Keep this box dedicated to Dokploy.
- Docker-published ports bypass UFW — the Hetzner Cloud Firewall is the ingress gate.
- Installer source (keep this auditable): https://docs.dokploy.com/docs/core/installation
- If the vendor changes the install command, update `dokploy.install` in `program/src/workloads.ts`.
