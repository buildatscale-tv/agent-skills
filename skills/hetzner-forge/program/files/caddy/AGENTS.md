# Web UI images

**How it works:** Caddy serves **`/media/*`** from **`/srv/media`** on port `80`, reverse proxying OpenCode web on port `4096`. Both share the same origin, so images render inline in the OpenCode web UI.

**When you save screenshots or other images for the user to see in the thread:**

1. Write files under **`/srv/media/`** (use clear filenames).
2. In your reply, use markdown **`![description](/media/<filename>)`** — relative path, same origin.

Example: `![screenshot](/media/dashboard.png)`

**Notes:**
- `/srv/media` is writable by the `opencode` user.
- Caddy runs as a Docker container on the host network (`opencode-media`).
- The web UI is exposed via Tailscale serve on `https://<node>.tailnet.ts.net/`.
