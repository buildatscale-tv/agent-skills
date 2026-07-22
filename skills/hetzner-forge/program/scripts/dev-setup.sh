#!/usr/bin/env bash
# Dev environment setup for the Hetzner OpenCode box.
# Installs tools the human admin and the OpenCode agent need to work like a local dev machine.
# Run as root or via sudo on the box after install-opencode.sh.
#
# Env (optional):
#   ADMIN_USER                the human/admin sudo user
#   GIT_USER_NAME             git user.name
#   GIT_USER_EMAIL            git user.email
#   TRELLO_TOKEN              Trello API token for the MCP server
#   TRELLO_API_KEY            Trello API key for the MCP server
#   OPENCODE_CONFIG_SOURCE    path on the box to the mirrored opencode config files
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

ADMIN_USER="${ADMIN_USER:-deploy}"
OC_USER=opencode
OC_HOME="$(getent passwd "$OC_USER" | cut -d: -f6)"
CONFIG_SOURCE="${OPENCODE_CONFIG_SOURCE:-/tmp/opencode-config}"

# Common build/dependency tools required by installers below.
apt-get update
apt-get install -y curl ca-certificates gnupg unzip git

# --- GitHub CLI (gh) -------------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  apt-get update
  apt-get install -y gh
  echo "[dev-setup] GitHub CLI installed."
else
  echo "[dev-setup] GitHub CLI already installed."
fi

# --- Docker Engine ---------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/sources.list.d/docker.list >/dev/null
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  usermod -aG docker "$ADMIN_USER"
  usermod -aG docker "$OC_USER"
  echo "[dev-setup] Docker installed and $ADMIN_USER + $OC_USER added to docker group."
else
  # Ensure the opencode service user can run docker without sudo
  if ! id -nG "$OC_USER" | grep -qw docker; then
    usermod -aG docker "$OC_USER"
    echo "[dev-setup] Added $OC_USER to docker group."
  fi
  echo "[dev-setup] Docker already installed."
fi

# --- Bun (used by the Trello MCP server) -----------------------------------
# Always ensure bun is installed to a globally readable path so the opencode
# service user can run MCP servers.
rm -rf /usr/local/bin/bun /usr/local/bun /root/.bun
BUN_INSTALL_DIR="/usr/local/bun"
export BUN_INSTALL="$BUN_INSTALL_DIR"
curl -fsSL https://bun.sh/install | bash
ln -sf "$BUN_INSTALL_DIR/bin/bun" /usr/local/bin/bun
ln -sf "$BUN_INSTALL_DIR/bin/bunx" /usr/local/bin/bunx
chmod -R 755 "$BUN_INSTALL_DIR"
echo "[dev-setup] Bun installed at /usr/local/bin/bun and /usr/local/bin/bunx."

# --- Agent Browser (https://agent-browser.dev/) ------------------------------
if ! command -v agent-browser >/dev/null 2>&1; then
  npm install -g agent-browser
  echo "[dev-setup] agent-browser installed."
else
  echo "[dev-setup] agent-browser already installed."
fi

# --- Chrome + system deps for agent-browser --------------------------------
# agent-browser runs as the opencode user and needs Chrome + shared libraries.
# Install libraries as root, then install Chrome into the opencode user's home.
if command -v agent-browser >/dev/null 2>&1; then
  apt-get install -y libnspr4 libnss3 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 libxcb1 libasound2t64 libgbm1 libx11-6 libxext6 libcairo2 libpango-1.0-0 libpangocairo-1.0-0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libatspi2.0-0t64 libgtk-3-0t64
  sudo -u "$OC_USER" bash -c "cd /home/opencode && agent-browser install" || true
  echo "[dev-setup] agent-browser Chromium + deps installed for $OC_USER."
fi

# --- Git config for admin user ---------------------------------------------
if [ -n "${GIT_USER_NAME:-}" ] && [ -n "${GIT_USER_EMAIL:-}" ]; then
  sudo -u "$ADMIN_USER" git config --global user.name "$GIT_USER_NAME"
  sudo -u "$ADMIN_USER" git config --global user.email "$GIT_USER_EMAIL"
  echo "[dev-setup] Git configured for $ADMIN_USER."
fi

# --- Mirror local opencode config into the service user's home -------------
if [ -d "$CONFIG_SOURCE" ]; then
  install -d -o "$OC_USER" -g "$OC_USER" -m 755 "$OC_HOME/.config"
  rsync -avc "$CONFIG_SOURCE/" "$OC_HOME/.config/opencode/" || cp -r "$CONFIG_SOURCE/." "$OC_HOME/.config/opencode/"
  chown -R "$OC_USER:$OC_USER" "$OC_HOME/.config/opencode"

  # Install MCP server dependencies if a package.json exists
  if [ -f "$OC_HOME/.config/opencode/package.json" ]; then
    sudo -u "$OC_USER" bash -c "cd '$OC_HOME/.config/opencode' && bun install" || \
      sudo -u "$OC_USER" bash -c "cd '$OC_HOME/.config/opencode' && npm install"
  fi

  # Install the Trello MCP server used by opencode.json
  if command -v bun >/dev/null 2>&1; then
    sudo -u "$OC_USER" bun add -g @delorenj/mcp-server-trello@1.7.1 || true
  else
    sudo -u "$OC_USER" npm install -g @delorenj/mcp-server-trello@1.7.1 || true
  fi

  echo "[dev-setup] OpenCode config mirrored and dependencies installed."
fi

# --- Inject Trello secrets into a shared env file --------------------------
if [ -n "${TRELLO_TOKEN:-}" ] && [ -n "${TRELLO_API_KEY:-}" ]; then
  ENV_FILE="$OC_HOME/.config/opencode/.env"
  cat > "$ENV_FILE" <<EOF
TRELLO_TOKEN=$TRELLO_TOKEN
TRELLO_API_KEY=$TRELLO_API_KEY
PATH=/home/opencode/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF
  chmod 600 "$ENV_FILE"
  chown "$OC_USER:$OC_USER" "$ENV_FILE"

  # Make the service load the env file
  sed -i '/EnvironmentFile=/d' /etc/systemd/system/opencode-serve.service
  if ! grep -q "EnvironmentFile=$ENV_FILE" /etc/systemd/system/opencode-serve.service; then
    sed -i "/\[Service\]/a EnvironmentFile=$ENV_FILE" /etc/systemd/system/opencode-serve.service
  fi

  # Source the same env file in .bashrc (covers interactive and login shells
  # because .profile already sources .bashrc). Replace any legacy block.
  BASHRC="$OC_HOME/.bashrc"
  if [ -f "$BASHRC" ]; then
    if grep -q "# opencode-mcp-env" "$BASHRC" 2>/dev/null; then
      sed -i '/# opencode-mcp-env/,/^export PATH=.*bun/d' "$BASHRC"
    fi
    cat >> "$BASHRC" <<EOF

# opencode-mcp-env
if [ -f /home/opencode/.config/opencode/.env ]; then
  set -a
  source /home/opencode/.config/opencode/.env
  set +a
fi
EOF
    chown "$OC_USER:$OC_USER" "$BASHRC"
  fi

  # Remove legacy per-shell exports from .profile
  PROFILE="$OC_HOME/.profile"
  if [ -f "$PROFILE" ] && grep -q "# opencode-mcp-env" "$PROFILE" 2>/dev/null; then
    sed -i '/# opencode-mcp-env/,/^export PATH=.*bun/d' "$PROFILE"
  fi

  # Clean up legacy files
  rm -f /etc/systemd/system/opencode-serve.env
  rm -f "$OC_HOME/.config/opencode/trello-mcp.sh"

  systemctl daemon-reload
  systemctl restart opencode-serve.service
  echo "[dev-setup] Trello secrets injected and service restarted."
fi

echo "[dev-setup] dev environment ready."
