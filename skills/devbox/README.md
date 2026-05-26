# /devbox

Create, manage, and tear down [Namespace](https://namespace.so/?ref=buildatscale-yt) devboxes from any AI agent. Supports GitHub issue dispatch, ad-hoc tasks, multi-variant model comparison, and plain devbox management.

```
/devbox issue 32
/devbox create a sponsors page with logos
/devbox create 3 variants of: design a homepage for a cabinet maker
/devbox give me a box with Gitea in Docker
/devbox tear down issue 32
```

**Agent profiles** layer on runtime-specific dispatch:
- `profiles/opencode.md` for [OpenCode](https://opencode.ai) agent dispatch
- `profiles/claude.md` for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) dispatch

See [SKILL.md](SKILL.md) for the full instruction set.

## Requirements

- [Namespace Devbox CLI](https://namespace.so/docs/devbox.md) - devbox management
  ```bash
  curl -fsSL get.namespace.so/devbox/install.sh | bash
  devbox login
  ```
- [Namespace Cloud CLI](https://namespace.so/docs/reference/cli/installation) (`nsc`) - vault secrets
  ```bash
  curl -fsSL https://get.namespace.so/cloud/install.sh | bash
  nsc login
  ```
- [GitHub CLI](https://cli.github.com/) - repo access and PRs
  ```bash
  gh auth login
  ```
