#!/usr/bin/env bash
# OpenCode server workload. Runs on the box (via SSH) AFTER harden.sh.
# Uses opencode's native web auth: opencode web reads OPENCODE_SERVER_USERNAME
# and OPENCODE_SERVER_PASSWORD from the environment. No reverse proxy needed.
#
# Env (all injected over SSH, never via cloud-init):
#   ADMIN_USER                 the human/admin sudo user (from harden.sh)
#   OPENCODE_API_KEY           opencode-go API key
#   OPENCODE_PORT              port the web server listens on (default 4096)
#   OPENCODE_SERVER_USERNAME   web-login username (default: opencode)
#   OPENCODE_SERVER_PASSWORD   web-login password
#   OPENCODE_MODEL             default model for new sessions
#   ACCESS                     access mode: ssh | tailscale (default ssh)
#
# opencode + the agent it runs are isolated to a dedicated NON-SUDO system user
# ("opencode") so the agent can never escalate to root.
set -euo pipefail
export HOME="${HOME:-/root}"   # SSH may run as root; the opencode installer needs HOME
export DEBIAN_FRONTEND=noninteractive
PORT="${OPENCODE_PORT:-4096}"
ACCESS="${ACCESS:-ssh}"
OC_USER=opencode               # dedicated, no-sudo service user (the agent runs as this)
ADMIN_USER="${ADMIN_USER:-deploy}"

# Bind address: always loopback. Caddy runs in front of OpenCode on port 80
# (host network) and reverse-proxies to 127.0.0.1:4096. Tailscale serve then
# exposes Caddy on the tailnet HTTPS URL. Public exposure is still blocked by
# the Hetzner Cloud Firewall and host UFW default-deny.
BIND_HOST="127.0.0.1"

# --- Node + opencode (binary installed system-wide) ---
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
curl -fsSL https://opencode.ai/install | bash
install -m 0755 /root/.opencode/bin/opencode /usr/local/bin/opencode

# --- dedicated non-sudo service user (never run the agent as root or a sudoer) ---
id "$OC_USER" >/dev/null 2>&1 || adduser --disabled-password --gecos "" "$OC_USER"
OC_HOME="$(getent passwd "$OC_USER" | cut -d: -f6)"

# --- opencode-go auth for the service user ---
install -d -m 700 -o "$OC_USER" -g "$OC_USER" "$OC_HOME/.local/share/opencode"
if [ -n "${OPENCODE_API_KEY:-}" ]; then
  (umask 077; cat > "$OC_HOME/.local/share/opencode/auth.json" <<JSON
{"opencode-go":{"type":"api","key":"${OPENCODE_API_KEY}"}}
JSON
  )
else
  # No API key was supplied to the agent. Write a placeholder so the service
  # file and permissions are in place; the user replaces this over SSH.
  (umask 077; cat > "$OC_HOME/.local/share/opencode/auth.json" <<JSON
{"opencode-go":{"type":"api","key":"PASTE_YOUR_OPENCODE_GO_API_KEY_HERE"}}
JSON
  )
  echo "[forge] WARNING: no OPENCODE_API_KEY was provided. Replace the placeholder in"
  echo "        $OC_HOME/.local/share/opencode/auth.json and run"
  echo "        'sudo systemctl restart opencode-serve.service' before using OpenCode."
fi
chown -R "$OC_USER:$OC_USER" "$OC_HOME/.local"

# --- default model so a fresh session is ready to chat ---
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

# --- opencode web on the chosen interface, as the non-sudo user, with native auth ---
cat > /etc/systemd/system/opencode-serve.service <<UNIT
[Unit]
Description=OpenCode server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${OC_USER}
Environment=HOME=${OC_HOME}
Environment=OPENCODE_SERVER_USERNAME=${OPENCODE_SERVER_USERNAME:-opencode}
Environment=OPENCODE_SERVER_PASSWORD=${OPENCODE_SERVER_PASSWORD}
WorkingDirectory=${OC_HOME}/projects
ExecStart=/usr/local/bin/opencode web --hostname ${BIND_HOST} --port ${PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now opencode-serve.service

echo "[forge] opencode workload installed (user=$OC_USER no-sudo, native auth :$PORT)"
