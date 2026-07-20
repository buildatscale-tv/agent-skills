#!/usr/bin/env bash
# Dokploy workload (no official Hetzner image — documented vendor installer).
# Runs on the box via cloud-init after harden.sh. Docs: https://docs.dokploy.com
set -euo pipefail
curl -sSL https://dokploy.com/install.sh | sh
echo "[forge] dokploy installed (dashboard on :3000)"
