import * as fs from "fs";
import * as path from "path";
import * as pulumi from "@pulumi/pulumi";
import { ForgeConfig } from "./config";
import { WorkloadSpec } from "./workloads";

/** Read the canonical hardening script from scripts/harden.sh. */
export function loadHardenScript(): string {
  return fs.readFileSync(path.join(__dirname, "..", "scripts", "harden.sh"), "utf8");
}

/** Single-quote a value for safe use in a shell command. */
function shq(v: string): string {
  return `'${v.replace(/'/g, "'\\''")}'`;
}

function indent(s: string, n: number): string {
  const pad = " ".repeat(n);
  return s
    .split("\n")
    .map((line) => (line.length ? pad + line : line))
    .join("\n");
}

/**
 * Build the env-var prefix that parameterises harden.sh. Returns an Output
 * because the Tailscale auth key is a secret and must stay encrypted in state.
 */
export function hardenEnv(cfg: ForgeConfig, w: WorkloadSpec): pulumi.Output<string> {
  const ports = Array.from(new Set([...w.ports, ...cfg.extraPorts]));
  const base =
    `ADMIN_USER=${shq(cfg.adminUser)} ` +
    `ADMIN_SSH_PUBKEY=${shq(cfg.sshPublicKey)} ` +
    `ACCESS=${shq(cfg.access)} ` +
    `TIMEZONE=${shq(cfg.timezone)} ` +
    `SWAP_GB=${shq(String(cfg.swapSizeGb))} ` +
    `WORKLOAD_PORTS=${shq(ports.join(" "))}`;

  if (cfg.access === "tailscale" && cfg.tailscaleAuthKey) {
    return pulumi.interpolate`${base} TAILSCALE_AUTHKEY=${cfg.tailscaleAuthKey.apply(shq)}`;
  }
  return pulumi.output(base);
}

/**
 * Build the cloud-init user_data for the from-scratch path: writes harden.sh
 * (and an optional workload installer) and runs them on first boot, before the
 * box is meaningfully exposed.
 */
export function buildCloudInit(
  cfg: ForgeConfig,
  w: WorkloadSpec,
  hardenScript: string,
): pulumi.Output<string> {
  return hardenEnv(cfg, w).apply((envStr) => {
    const parts: string[] = [
      "#cloud-config",
      "package_update: true",
      "package_upgrade: true",
      "write_files:",
      "  - path: /opt/hetzner-forge/harden.sh",
      "    permissions: '0755'",
      "    content: |",
      indent(hardenScript, 6),
    ];

    if (w.install) {
      const installScript = "#!/usr/bin/env bash\nset -euo pipefail\n" + w.install + "\n";
      parts.push(
        "  - path: /opt/hetzner-forge/install-workload.sh",
        "    permissions: '0755'",
        "    content: |",
        indent(installScript, 6),
      );
    }

    parts.push(
      "runcmd:",
      `  - ${envStr} bash /opt/hetzner-forge/harden.sh 2>&1 | tee /var/log/hetzner-forge-harden.log`,
    );
    if (w.install) {
      parts.push(
        "  - bash /opt/hetzner-forge/install-workload.sh 2>&1 | tee /var/log/hetzner-forge-install.log",
      );
    }

    return parts.join("\n") + "\n";
  });
}
