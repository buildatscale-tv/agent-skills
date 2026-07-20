# Agent Skills

Portable AI agent skills that work across harnesses (Claude Code, OpenCode, Cursor, etc.).

Install via `npx skills add` or copy the skill directory into your project.

## Skills

### [/devbox](skills/devbox/)

Create, manage, and tear down [Namespace](https://namespace.so/?ref=buildatscale-yt) devboxes from any AI agent. Supports GitHub issue dispatch, ad-hoc tasks, multi-variant model comparison, and plain devbox management.

### [/hetzner-forge](skills/hetzner-forge/)

Provision a hardened, ready-to-go [Hetzner Cloud](https://www.hetzner.com/cloud) box with **Pulumi (TypeScript)** in one guided flow. Base hardening (non-root sudo user, key-only SSH, UFW, fail2ban, unattended upgrades, Cloud Firewall) plus a pluggable workload — Coolify, Docker, Dokploy, an OpenCode server (browser UI behind a login, run as a non-sudo user), or a custom target resolved from official images or the vendor's documented install. State-managed: `pulumi up` to reconcile, `pulumi destroy` for a clean teardown.

## Install

```bash
npx skills add https://github.com/buildatscale-tv/agent-skills
```

## License

MIT
