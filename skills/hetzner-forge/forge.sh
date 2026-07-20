#!/usr/bin/env bash
# hetzner-forge — create a hardened Hetzner Cloud box with the hcloud CLI + cloud-init.
# No Pulumi. Idempotent-ish: reuses an existing SSH key / firewall by name.
#
# Config via env (FORGE_*). Required: FORGE_SSH_PUBKEY. For opencode: FORGE_OPENCODE_API_KEY.
#   FORGE_NAME(forge) FORGE_LOCATION(hil) FORGE_TYPE(cpx22) FORGE_WORKLOAD(base)
#   FORGE_ACCESS(ssh|tailscale) FORGE_ADMIN_USER(deploy) FORGE_SSH_SOURCE(0.0.0.0/0)
#   FORGE_TIMEZONE(UTC) FORGE_BASE_IMAGE(ubuntu-24.04) FORGE_EXTRA_PORTS("")
#   FORGE_OPENCODE_USER(opencode) FORGE_OPENCODE_PASSWORD(generated) FORGE_OPENCODE_PORT(4096)
#   FORGE_TAILSCALE_AUTHKEY  --print-user-data (build cloud-init and exit, create nothing)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/workloads.sh"

NAME="${FORGE_NAME:-forge}"
LOCATION="${FORGE_LOCATION:-hil}"
TYPE="${FORGE_TYPE:-cpx22}"
WORKLOAD="${FORGE_WORKLOAD:-base}"
ACCESS="${FORGE_ACCESS:-ssh}"
ADMIN_USER="${FORGE_ADMIN_USER:-deploy}"
SSH_KEY_NAME="${FORGE_SSH_KEY_NAME:-${NAME}-key}"
SSH_PUBKEY="${FORGE_SSH_PUBKEY:?set FORGE_SSH_PUBKEY to your SSH public key contents}"
SSH_SOURCE="${FORGE_SSH_SOURCE:-0.0.0.0/0}"
TIMEZONE="${FORGE_TIMEZONE:-UTC}"
BASE_IMAGE="${FORGE_BASE_IMAGE:-ubuntu-24.04}"
EXTRA_PORTS="${FORGE_EXTRA_PORTS:-}"
OPENCODE_API_KEY="${FORGE_OPENCODE_API_KEY:-}"
OPENCODE_USER="${FORGE_OPENCODE_USER:-opencode}"
OPENCODE_PASSWORD="${FORGE_OPENCODE_PASSWORD:-}"
OPENCODE_PORT="${FORGE_OPENCODE_PORT:-4096}"
OPENCODE_MODEL="${FORGE_OPENCODE_MODEL:-opencode-go/kimi-k3}"
TAILSCALE_AUTHKEY="${FORGE_TAILSCALE_AUTHKEY:-}"

resolve_workload "$WORKLOAD" "$HERE"
IMAGE="${WL_IMAGE:-$BASE_IMAGE}"
WORKLOAD_PORTS="$(echo "$WL_PORTS $EXTRA_PORTS" | xargs || true)"

# opencode needs a key + a password (generate one if not supplied)
if [ "$WORKLOAD" = "opencode" ]; then
  [ -n "$OPENCODE_API_KEY" ] || { echo "forge: opencode needs FORGE_OPENCODE_API_KEY" >&2; exit 1; }
  if [ -z "$OPENCODE_PASSWORD" ]; then
    OPENCODE_PASSWORD="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9')"
  fi
fi

# --- build cloud-init user_data: a plain bash script (cloud-init runs #! user-data) ---
build_user_data() {
  echo '#!/bin/bash'
  echo 'set -euo pipefail'
  echo 'mkdir -p /opt/forge'
  echo "cat > /opt/forge/harden.sh <<'FORGE_HARDEN_EOF'"
  cat "$HERE/lib/harden.sh"
  echo 'FORGE_HARDEN_EOF'
  printf 'ADMIN_USER=%q ADMIN_SSH_PUBKEY=%q ACCESS=%q TIMEZONE=%q SWAP_GB=%q WORKLOAD_PORTS=%q' \
    "$ADMIN_USER" "$SSH_PUBKEY" "$ACCESS" "$TIMEZONE" "0" "$WORKLOAD_PORTS"
  [ -n "$TAILSCALE_AUTHKEY" ] && printf ' TAILSCALE_AUTHKEY=%q' "$TAILSCALE_AUTHKEY"
  echo ' bash /opt/forge/harden.sh 2>&1 | tee /var/log/forge-harden.log'
  if [ -n "$WL_INSTALL" ]; then
    echo "cat > /opt/forge/install.sh <<'FORGE_INSTALL_EOF'"
    cat "$WL_INSTALL"
    echo 'FORGE_INSTALL_EOF'
    printf 'ADMIN_USER=%q OPENCODE_API_KEY=%q OPENCODE_PORT=%q OPENCODE_USER=%q OPENCODE_PASSWORD=%q OPENCODE_MODEL=%q' \
      "$ADMIN_USER" "$OPENCODE_API_KEY" "$OPENCODE_PORT" "$OPENCODE_USER" "$OPENCODE_PASSWORD" "$OPENCODE_MODEL"
    echo ' bash /opt/forge/install.sh 2>&1 | tee /var/log/forge-install.log'
  fi
}

UD="$(mktemp -t forge-ud)"
build_user_data > "$UD"

if [ "${1:-}" = "--print-user-data" ]; then
  echo "# ---- cloud-init user_data ($(wc -l < "$UD") lines) ----"
  cat "$UD"
  exit 0
fi

echo "==> forge: $NAME  workload=$WORKLOAD  image=$IMAGE  type=$TYPE  loc=$LOCATION  access=$ACCESS"

# --- SSH key (reuse if this public key is already registered, under any name) ---
KEY_BODY="$(awk '{print $2}' <<< "$SSH_PUBKEY")"
FOUND_KEY="$(hcloud ssh-key list -o json 2>/dev/null | python3 -c "import sys,json;b=sys.argv[1];ks=json.load(sys.stdin);print(next((k['name'] for k in ks if b and b in k.get('public_key','')), ''))" "$KEY_BODY" 2>/dev/null || true)"
if [ -n "$FOUND_KEY" ]; then
  echo "==> reusing existing ssh-key $FOUND_KEY"
  SSH_KEY_NAME="$FOUND_KEY"
elif ! hcloud ssh-key describe "$SSH_KEY_NAME" >/dev/null 2>&1; then
  echo "==> creating ssh-key $SSH_KEY_NAME"
  hcloud ssh-key create --name "$SSH_KEY_NAME" --public-key "$SSH_PUBKEY"
fi

# --- Firewall ---
FW="${NAME}-fw"
if hcloud firewall describe "$FW" >/dev/null 2>&1; then
  hcloud firewall delete "$FW" >/dev/null 2>&1 || true
fi
echo "==> creating firewall $FW"
hcloud firewall create --name "$FW" >/dev/null
hcloud firewall add-rule "$FW" --direction in --protocol tcp --port 22 --source-ips "$SSH_SOURCE" --source-ips '::/0' --description SSH >/dev/null
hcloud firewall add-rule "$FW" --direction in --protocol icmp --source-ips 0.0.0.0/0 --source-ips '::/0' --description ICMP >/dev/null
for p in $WORKLOAD_PORTS; do
  hcloud firewall add-rule "$FW" --direction in --protocol tcp --port "$p" --source-ips 0.0.0.0/0 --source-ips '::/0' --description "workload:$p" >/dev/null
done
if [ "$ACCESS" = "tailscale" ]; then
  hcloud firewall add-rule "$FW" --direction in --protocol udp --port 41641 --source-ips 0.0.0.0/0 --source-ips '::/0' --description Tailscale >/dev/null
fi

# --- Server ---
echo "==> creating server $NAME (this takes ~15-30s)…"
hcloud server create \
  --name "$NAME" --type "$TYPE" --image "$IMAGE" --location "$LOCATION" \
  --ssh-key "$SSH_KEY_NAME" --firewall "$FW" \
  --user-data-from-file "$UD" \
  --label managed_by=hetzner-forge --label workload="$WORKLOAD"

IP="$(hcloud server ip "$NAME")"
rm -f "$UD"

echo
echo "================ forge: $NAME is up ================"
echo "  IPv4:   $IP"
echo "  SSH:    ssh $ADMIN_USER@$IP"
echo "  Logs:   ssh $ADMIN_USER@$IP 'sudo tail -f /var/log/forge-harden.log /var/log/forge-install.log'"
echo "  Workload ($WORKLOAD): $WL_READY"
if [ "$WORKLOAD" = "opencode" ]; then
  echo
  echo "  OpenCode web (after cloud-init finishes, ~3-6 min):"
  echo "    Tunnel (this Mac):   ssh -L 4096:localhost:4096 $ADMIN_USER@$IP   then open http://localhost:4096"
  echo "    Tunnel (LAN/phone):  ssh -L 0.0.0.0:4096:localhost:4096 $ADMIN_USER@$IP   then open http://<mac-lan-ip>:4096"
  echo "    Login: $OPENCODE_USER / $OPENCODE_PASSWORD"
fi
echo "  Teardown: hcloud server delete $NAME ; hcloud firewall delete $FW"
echo "===================================================="
