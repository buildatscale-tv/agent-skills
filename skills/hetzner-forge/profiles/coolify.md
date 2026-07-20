# Profile: Coolify

Coolify is a self-hosted PaaS (Heroku/Netlify alternative). Hetzner publishes an
official `coolify` app image, so this is the **image + post-harden** path.

## Config

```bash
pulumi config set workload   coolify
pulumi config set serverType cpx21     # 4 GB RAM minimum; cpx31 (8 GB) is comfy
pulumi config set sshPublicKey "$(cat ~/.ssh/id_ed25519.pub)"
# sshPrivateKeyPath defaults to ~/.ssh/id_ed25519 (used to SSH in and harden)
```

Watch the region: the default `hil` offers only the `cpxN1` line (`cpx21`,
`cpx31`, …) — `cpx22`/`cpx32` are EU-only and error in `hil`.

Port policy (registry-decided):

- **Admin (your CIDRs only):** `8000` — the Coolify dashboard.
- **Public (world):** `80, 443` — deployed apps served through Coolify's proxy.

## Flow

1. Server boots from the official `coolify` image with the Cloud Firewall already attached (Coolify's own installer runs on first boot).
2. Once first boot settles, Pulumi SSHes in as root and runs `harden.sh`: creates the sudo user, locks down SSH (root login disabled), UFW, fail2ban, unattended upgrades.
3. Ingress: dashboard reachable only from your IPs; app traffic public on 80/443.

## After `pulumi up`

- Dashboard: `http://<ipv4>:8000` — reachable only from your admin CIDRs; create the admin account on first visit.
- Coolify runs on Docker; deployed apps are served via its proxy on 80/443.
- Point a domain at the box and configure it in Coolify for automatic Let's Encrypt.

## Notes

- **Sizing:** Coolify wants ≥ 2 vCPU / 4 GB. Builds are memory-hungry — size up or add swap (`pulumi config set swapSizeGb 4`) on small boxes.
- **UFW vs Docker:** Coolify publishes container ports through Docker's iptables, which bypasses UFW. The Hetzner Cloud Firewall is the real gate here.
- Docs: https://coolify.io/docs
