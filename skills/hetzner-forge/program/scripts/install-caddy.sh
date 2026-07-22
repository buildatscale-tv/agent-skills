#!/usr/bin/env bash
# Caddy media server for OpenCode. Runs on the box (via SSH) AFTER install-opencode.sh.
# Builds/runs a small Caddy container that:
#   - serves /media/* from /srv/media
#   - reverse-proxies everything else to OpenCode on 127.0.0.1:4096
#   - listens on port 80 (host network)
# Tailscale serve is then pointed at port 80 so the web UI + media share one origin.
#
# Env:
#   OC_USER     opencode service user (default: opencode)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
OC_USER="${OC_USER:-opencode}"
OC_HOME="$(eval "echo ~$OC_USER")"
CADDY_DIR="/opt/opencode-caddy"
MEDIA_DIR="/srv/media"

# --- Ensure media directory exists and is writable by the opencode user ---
install -d -m 775 -o "$OC_USER" -g "$OC_USER" "$MEDIA_DIR"

# --- Stage Caddy files ---
install -d -m 755 "$CADDY_DIR"
# These are copied from the Pulumi project by the caller (archive preserves the
# top-level directory, so files live under /tmp/opencode-caddy/caddy/).
CADDY_SRC="/tmp/opencode-caddy/caddy"
cp "$CADDY_SRC/Caddyfile" "$CADDY_DIR/Caddyfile"
cp "$CADDY_SRC/Dockerfile" "$CADDY_DIR/Dockerfile"
cp "$CADDY_SRC/AGENTS.md" "$OC_HOME/AGENTS.md"
chown "$OC_USER:$OC_USER" "$OC_HOME/AGENTS.md"

# --- Build and run Caddy on the host network ---
docker build -t opencode-caddy "$CADDY_DIR"

# Stop/remove any previous container so the new image is used.
docker rm -f opencode-media 2>/dev/null || true

docker run -d \
  --name opencode-media \
  --network host \
  --restart always \
  -v "$MEDIA_DIR:$MEDIA_DIR" \
  -w /srv/media \
  opencode-caddy

# --- Point Tailscale serve at Caddy (port 80) ---
# This makes the web UI + media available on the same HTTPS origin.
if command -v tailscale >/dev/null 2>&1; then
  tailscale serve --bg 80
  echo "[forge] Tailscale serve now proxies to Caddy on port 80."
fi

echo "[forge] Caddy media server installed (container=opencode-media, media=$MEDIA_DIR)."
