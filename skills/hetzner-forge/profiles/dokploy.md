# Profile: Dokploy

Dokploy is a self-hosted deployment platform. Hetzner has **no** official Dokploy
image (verified via `hcloud image list --type app`), so this is the
**from-scratch** path: plain Ubuntu + the vendor installer, run in cloud-init
after hardening (`lib/install-dokploy.sh`).

```bash
export FORGE_SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)"
export FORGE_NAME=dokploy FORGE_WORKLOAD=dokploy FORGE_TYPE=cpx21 FORGE_LOCATION=hil
bash forge.sh
```

- Boots `ubuntu-24.04`; cloud-init runs `harden.sh`, then `curl -sSL https://dokploy.com/install.sh | sh` (installs Docker + Swarm + Dokploy).
- Firewall opens **80, 443, 3000**. Dashboard: `http://<ip>:3000`.
- Keep this box dedicated to Dokploy (the installer sets up Docker Swarm).
- Installer source (keep auditable): https://docs.dokploy.com/docs/core/installation — if the command changes, update `lib/install-dokploy.sh`.
