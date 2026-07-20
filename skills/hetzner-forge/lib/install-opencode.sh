#!/usr/bin/env bash
# OpenCode server workload. Runs on the box (via cloud-init) AFTER harden.sh.
# Env: ADMIN_USER, OPENCODE_API_KEY, OPENCODE_PORT, OPENCODE_USER, OPENCODE_PASSWORD
set -euo pipefail
export HOME="${HOME:-/root}"   # cloud-init runs as root with HOME unset; the opencode installer needs it
export DEBIAN_FRONTEND=noninteractive
PROXY_PORT="${OPENCODE_PORT:-4096}"
APP_PORT=4097   # opencode binds loopback here; nginx fronts it with basic auth

# --- Node + opencode ---
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs nginx apache2-utils
curl -fsSL https://opencode.ai/install | bash
install -m 0755 /root/.opencode/bin/opencode /usr/local/bin/opencode

# --- authenticate opencode-go for the admin user ---
ADMIN_HOME="$(getent passwd "${ADMIN_USER:-deploy}" | cut -d: -f6)"
install -d -m 700 -o "${ADMIN_USER}" -g "${ADMIN_USER}" "${ADMIN_HOME}/.local/share/opencode"
(umask 077; cat > "${ADMIN_HOME}/.local/share/opencode/auth.json" <<JSON
{"opencode-go":{"type":"api","key":"${OPENCODE_API_KEY}"}}
JSON
)
chown -R "${ADMIN_USER}:${ADMIN_USER}" "${ADMIN_HOME}/.local"   # opencode also writes ~/.local/state at runtime

# --- starter project so the box isn't empty (opencode needs a project to start a session) ---
install -d -m 0755 "${ADMIN_HOME}/projects/scratch"
printf '# Scratch\nStarter project for OpenCode. Add your own repos under ~/projects.\n' > "${ADMIN_HOME}/projects/scratch/README.md"
chown -R "${ADMIN_USER}:${ADMIN_USER}" "${ADMIN_HOME}/projects"

# --- opencode serve on loopback (fronted by nginx) ---
cat > /etc/systemd/system/opencode-serve.service <<UNIT
[Unit]
Description=OpenCode server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${ADMIN_USER}
Environment=HOME=${ADMIN_HOME}
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
echo "[forge] opencode workload installed (nginx :$PROXY_PORT -> opencode 127.0.0.1:$APP_PORT)"
