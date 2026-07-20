#!/usr/bin/env bash
# Workload registry. resolve_workload <name> sets: WL_IMAGE, WL_INSTALL, WL_PORTS, WL_READY.
# - WL_IMAGE   : official Hetzner app image to boot from (empty = from-scratch base image)
# - WL_INSTALL : path to an install script run in cloud-init after hardening (empty = none)
# - WL_PORTS   : space-separated TCP ports to open in the Cloud Firewall (besides SSH)
# Verified against `hcloud image list --type app`: coolify + docker-ce exist; dokploy does not.
resolve_workload() {
  local w="$1" here="$2"
  WL_IMAGE=""; WL_INSTALL=""; WL_PORTS=""; WL_READY=""
  case "$w" in
    base)
      WL_READY="Plain hardened box." ;;
    coolify)
      WL_IMAGE="coolify"; WL_PORTS="80 443 8000"
      WL_READY="Coolify UI at http://<ip>:8000 (proxy on 80/443)." ;;
    docker)
      WL_IMAGE="docker-ce"
      WL_READY="Docker Engine preinstalled (open ports via FORGE_EXTRA_PORTS)." ;;
    dokploy)
      WL_INSTALL="$here/lib/install-dokploy.sh"; WL_PORTS="80 443 3000"
      WL_READY="Dokploy UI at http://<ip>:3000." ;;
    opencode)
      WL_INSTALL="$here/lib/install-opencode.sh"; WL_PORTS=""
      WL_READY="OpenCode behind nginx basic-auth on :4096 (reach via SSH tunnel; opencode itself on 127.0.0.1:4097)." ;;
    *)
      echo "forge: unknown workload '$w' (base|coolify|docker|dokploy|opencode)" >&2
      return 1 ;;
  esac
}
