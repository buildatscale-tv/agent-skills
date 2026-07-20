# Profile: Coolify

Coolify is a self-hosted PaaS. Hetzner publishes an official `coolify` app image,
so this is the **image + hardening** path.

```bash
export FORGE_SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)"
export FORGE_NAME=coolify FORGE_WORKLOAD=coolify FORGE_TYPE=cpx21 FORGE_LOCATION=hil
bash forge.sh
```

- Boots the official `coolify` image; `harden.sh` runs on top via cloud-init.
- Firewall opens **80, 443, 8000**. Dashboard: `http://<ip>:8000` (create the admin on first visit); apps served via the proxy on 80/443.
- Sizing: Coolify wants ≥ 4 GB (`cpx21`+); builds are memory-hungry — bump `FORGE_TYPE` or add `FORGE_SWAP_GB`.
- **Docker + UFW:** published container ports bypass UFW; the Hetzner Cloud Firewall is the real ingress gate.
- Docs: https://coolify.io/docs
