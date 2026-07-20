#!/usr/bin/env bash
# OpenCode server workload. Runs on the box (via cloud-init) AFTER harden.sh.
# Env: ADMIN_USER, OPENCODE_API_KEY, OPENCODE_PORT, OPENCODE_USER, OPENCODE_PASSWORD
#   ADMIN_USER        the human/admin sudo user (from harden.sh)
#   OPENCODE_USER/PASSWORD  the nginx basic-auth *web login* (not a system user)
# opencode + the agent it runs are isolated to a dedicated NON-SUDO system user
# ("opencode") so the agent can never escalate to root.
set -euo pipefail
export HOME="${HOME:-/root}"   # cloud-init runs as root with HOME unset; the opencode installer needs it
export DEBIAN_FRONTEND=noninteractive
PROXY_PORT="${OPENCODE_PORT:-4096}"
APP_PORT=4097                  # opencode binds loopback here; nginx fronts it with basic auth
OC_USER=opencode               # dedicated, no-sudo service user (the agent runs as this)
ADMIN_USER="${ADMIN_USER:-deploy}"

# --- Node + opencode (binary installed system-wide) ---
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs nginx apache2-utils
curl -fsSL https://opencode.ai/install | bash
install -m 0755 /root/.opencode/bin/opencode /usr/local/bin/opencode

# --- dedicated non-sudo service user (never run the agent as root or a sudoer) ---
id "$OC_USER" >/dev/null 2>&1 || adduser --disabled-password --gecos "" "$OC_USER"
OC_HOME="$(getent passwd "$OC_USER" | cut -d: -f6)"

# --- opencode-go auth for the service user ---
install -d -m 700 -o "$OC_USER" -g "$OC_USER" "$OC_HOME/.local/share/opencode"
(umask 077; cat > "$OC_HOME/.local/share/opencode/auth.json" <<JSON
{"opencode-go":{"type":"api","key":"${OPENCODE_API_KEY}"}}
JSON
)
chown -R "$OC_USER:$OC_USER" "$OC_HOME/.local"   # opencode also writes ~/.local/state at runtime

# --- default model so a fresh session is ready to chat (configurable via FORGE_OPENCODE_MODEL) ---
install -d -m 755 -o "$OC_USER" -g "$OC_USER" "$OC_HOME/.config/opencode"
printf '{"model":"%s"}\n' "${OPENCODE_MODEL:-opencode-go/kimi-k3}" > "$OC_HOME/.config/opencode/opencode.json"
chown -R "$OC_USER:$OC_USER" "$OC_HOME/.config"

# --- starter project in the designated folder, manageable by the admin user via group ---
install -d "$OC_HOME/projects/scratch"
printf '# Scratch\nStarter project for OpenCode. Add your own repos under ~/projects.\n' > "$OC_HOME/projects/scratch/README.md"
usermod -aG "$OC_USER" "$ADMIN_USER"                        # admin manages projects without sudo
chmod 750 "$OC_HOME"                                        # let the group traverse the home
chown -R "$OC_USER:$OC_USER" "$OC_HOME/projects"
chmod -R g+rwX "$OC_HOME/projects"
chmod g+s "$OC_HOME/projects" "$OC_HOME/projects/scratch"   # new files inherit the shared group

# --- opencode serve on loopback, as the non-sudo user ---
cat > /etc/systemd/system/opencode-serve.service <<UNIT
[Unit]
Description=OpenCode server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${OC_USER}
Environment=HOME=${OC_HOME}
WorkingDirectory=${OC_HOME}/projects
ExecStart=/usr/local/bin/opencode serve --hostname 127.0.0.1 --port ${APP_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now opencode-serve.service

# --- nginx basic-auth reverse proxy on the access port (opencode has no native auth) ---
htpasswd -bcB /etc/nginx/.htpasswd "${OPENCODE_USER}" "${OPENCODE_PASSWORD}"
cat > /etc/nginx/sites-available/opencode <<'NGINX'
map $http_upgrade $connection_upgrade {
  default upgrade;
  ""      "";
}
server {
  listen 4096;
  location / {
    auth_basic "OpenCode";
    auth_basic_user_file /etc/nginx/.htpasswd;
    proxy_pass http://127.0.0.1:4097;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;   # SSE-safe: no forced upgrade on the event stream
    proxy_buffering off;                                # opencode uses a live event stream
    proxy_read_timeout 3600s;
  }
}
NGINX
if [ "${PROXY_PORT}" != "4096" ]; then
  sed -i "s/listen 4096;/listen ${PROXY_PORT};/" /etc/nginx/sites-available/opencode
fi
ln -sf /etc/nginx/sites-available/opencode /etc/nginx/sites-enabled/opencode
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl restart nginx
echo "[forge] opencode workload installed (user=$OC_USER no-sudo, nginx :$PROXY_PORT -> opencode 127.0.0.1:$APP_PORT)"
