# Agent Skills

Portable AI agent skills that work across harnesses (Claude Code, OpenCode, Cursor, etc.).

Install via `npx skills add` or copy the skill directory into your project.

## Skills

### [/devbox](skills/devbox/)

Create, manage, and tear down [Namespace](https://namespace.so/?ref=buildatscale-yt) devboxes from any AI agent. Supports GitHub issue dispatch, ad-hoc tasks, multi-variant model comparison, and plain devbox management.

### [/hetzner-forge](skills/hetzner-forge/)

Provision a hardened, ready-to-go [Hetzner Cloud](https://www.hetzner.com/cloud) box with Pulumi in one guided flow. Base hardening (non-root sudo user, key-only SSH, UFW, fail2ban, unattended upgrades, Cloud Firewall) plus a pluggable workload — Coolify, Docker, Dokploy, or a custom target the skill resolves from official images or the vendor's documented install. Choose hardened SSH or Tailscale access; add volumes, private networks, and more.

## Install

```bash
npx skills add https://github.com/buildatscale-tv/agent-skills
```

## License

MIT
