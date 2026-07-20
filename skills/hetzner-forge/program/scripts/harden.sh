#!/usr/bin/env bash
# hetzner-forge :: base hardening
#
# Idempotent and parameterised entirely via environment variables, so the same
# script runs both from cloud-init (the from-scratch path) and over SSH (the
# post-harden path for official app images).
#
#   ADMIN_USER        non-root sudo user to create           (default: deploy)
#   ADMIN_SSH_PUBKEY  public key authorised for ADMIN_USER   (recommended)
#   ACCESS            ssh | tailscale                        (default: ssh)
#   TAILSCALE_AUTHKEY auth key, required when ACCESS=tailscale. SECRET — only
#                     ever passed over the SSH post-harden path, never via
#                     cloud-init user_data.
#   TIMEZONE          e.g. UTC, America/Los_Angeles          (default: UTC)
#   SWAP_GB           swap file size in GB, 0 = none         (default: 0)
#   ADMIN_CIDRS       space-separated CIDRs allowed to reach SSH and
#                     WORKLOAD_PORTS (default: empty = world; the Pulumi
#                     program always passes real CIDRs)
#   WORKLOAD_PORTS    space-separated admin TCP ports, UFW-scoped to ADMIN_CIDRS
#   PUBLIC_PORTS      space-separated world-open TCP ports   (default: empty)
#   SSH_PORT          sshd port                              (default: 22)
set -euo pipefail

ADMIN_USER="${ADMIN_USER:-deploy}"
ACCESS="${ACCESS:-ssh}"
TIMEZONE="${TIMEZONE:-UTC}"
SWAP_GB="${SWAP_GB:-0}"
ADMIN_CIDRS="${ADMIN_CIDRS:-}"
WORKLOAD_PORTS="${WORKLOAD_PORTS:-}"
PUBLIC_PORTS="${PUBLIC_PORTS:-}"
SSH_PORT="${SSH_PORT:-22}"

log() { echo "[hetzner-forge] $*"; }
export DEBIAN_FRONTEND=noninteractive

# --- needrestart: never prompt (breaks unattended installs) ----------------
mkdir -p /etc/needrestart/conf.d
cat > /etc/needrestart/conf.d/99forge.conf <<'EOF'
$nrconf{kernelhints} = -1;
$nrconf{restart} = 'a';
EOF

# --- timezone --------------------------------------------------------------
timedatectl set-timezone "$TIMEZONE" 2>/dev/null || true

# --- base packages ---------------------------------------------------------
apt-get update -y
apt-get install -y --no-install-recommends \
  sudo curl ca-certificates ufw fail2ban unattended-upgrades

# --- non-root admin user ---------------------------------------------------
if ! id "$ADMIN_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$ADMIN_USER"
fi
usermod -aG sudo "$ADMIN_USER"
echo "$ADMIN_USER ALL=(ALL:ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-forge-$ADMIN_USER"
chmod 0440 "/etc/sudoers.d/90-forge-$ADMIN_USER"
if [ -n "${ADMIN_SSH_PUBKEY:-}" ]; then
  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
  echo "$ADMIN_SSH_PUBKEY" > "/home/$ADMIN_USER/.ssh/authorized_keys"
  chmod 600 "/home/$ADMIN_USER/.ssh/authorized_keys"
  chown "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh/authorized_keys"
fi

# --- SSH hardening (drop-in; Ubuntu 22.04+ honours sshd_config.d) -----------
# Root login fully disabled and only the admin user may SSH. The restart that
# applies this is deliberately the LAST step of this script: post-boot SSH
# steps (post-harden, tailscale-up, secret installs) connect as root while
# first boot is still in progress, and an established session survives the
# restart — a new root connection must keep working until we're done.
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-forge.conf <<EOF
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
X11Forwarding no
MaxAuthTries 3
AllowUsers $ADMIN_USER
EOF

# --- unattended security upgrades ------------------------------------------
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now unattended-upgrades 2>/dev/null || true

# --- fail2ban --------------------------------------------------------------
mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/forge-sshd.conf <<EOF
[sshd]
enabled  = true
port     = $SSH_PORT
maxretry = 5
bantime  = 1h
EOF
systemctl enable --now fail2ban 2>/dev/null || true

# --- swap (optional) -------------------------------------------------------
if [ "$SWAP_GB" != "0" ] && [ ! -f /swapfile ]; then
  fallocate -l "${SWAP_GB}G" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_GB * 1024))
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# --- UFW host firewall -----------------------------------------------------
# Note: Docker publishes container ports via its own iptables chain, which
# bypasses UFW. For Docker-based workloads (coolify/docker/dokploy) the Hetzner
# Cloud Firewall is the authoritative ingress gate; UFW hardens host services.
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming
ufw default allow outgoing
if [ -n "$ADMIN_CIDRS" ]; then
  for c in $ADMIN_CIDRS; do
    ufw allow from "$c" to any port "$SSH_PORT" proto tcp
  done
else
  ufw allow "${SSH_PORT}/tcp"
fi
for p in $WORKLOAD_PORTS; do
  if [ -n "$ADMIN_CIDRS" ]; then
    for c in $ADMIN_CIDRS; do
      ufw allow from "$c" to any port "$p" proto tcp
    done
  else
    ufw allow "${p}/tcp"
  fi
done
for p in $PUBLIC_PORTS; do
  ufw allow "${p}/tcp"
done

# --- Tailscale (optional) --------------------------------------------------
if [ "$ACCESS" = "tailscale" ]; then
  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  ufw allow in on tailscale0 || true
  if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
    tailscale up --ssh --authkey "$TAILSCALE_AUTHKEY" || log "tailscale up failed — run 'tailscale up --ssh' manually"
  fi
fi

ufw --force enable

# --- apply the SSH lockdown LAST (see note at the drop-in above) -----------
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
log "hardening complete (user=$ADMIN_USER access=$ACCESS admin='$WORKLOAD_PORTS' public='$PUBLIC_PORTS')"
