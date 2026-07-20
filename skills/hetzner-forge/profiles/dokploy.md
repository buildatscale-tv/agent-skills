# Profile: Dokploy

Dokploy is a self-hosted deployment platform. Hetzner has **no** official Dokploy
app image (verified via `hcloud image list --type app`), so this is the
**from-scratch** path: plain Ubuntu + the vendor's documented installer, baked
into cloud-init and run after hardening.

## Config

```bash
pulumi config set workload   dokploy
pulumi config set serverType cpx22     # 2 vCPU / 4 GB minimum
pulumi config set sshPublicKey "$(cat ~/.ssh/id_ed25519.pub)"
```

Ports opened in the Hetzner Cloud Firewall: **80, 443, 3000**.

## Flow

1. Server boots plain `ubuntu-24.04`.
2. cloud-init runs `harden.sh` (sudo user, SSH lockdown, UFW, fail2ban, unattended upgrades).
3. cloud-init runs the documented installer: `curl -sSL https://dokploy.com/install.sh | sh` (installs Docker + Swarm + Dokploy).

## After `pulumi up`

- Dashboard: `http://<ipv4>:3000` — finish setup in the browser.
- Deployed apps are served on 80/443 via Dokploy's Traefik.
- Watch progress: `ssh <user>@<ip> 'sudo tail -f /var/log/hetzner-forge-install.log'`.

## Notes

- The installer requires a **fresh** host (it sets up Docker Swarm). Keep this box dedicated to Dokploy.
- Docker-published ports bypass UFW — the Hetzner Cloud Firewall is the ingress gate.
- Installer source (keep this auditable): https://docs.dokploy.com/docs/core/installation
- If the vendor changes the install command, update `dokploy.install` in `pulumi/src/workloads.ts`.
