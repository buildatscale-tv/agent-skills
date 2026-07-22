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
 * The env-var prefix that parameterises harden.sh — NON-SECRET values only.
 * user_data (cloud-init) is readable via the Hetzner console/API and via the
 * box's metadata endpoint, so secrets must never appear in it. The one secret
 * harden.sh can consume (TAILSCALE_AUTHKEY) is appended only on the SSH
 * delivery paths — see withTailscaleKey below.
 */
export function hardenEnvBase(cfg: ForgeConfig, w: WorkloadSpec): string {
  const adminPorts = Array.from(new Set([...w.adminPorts, ...cfg.extraPorts]));
  const publicPorts = Array.from(new Set([...w.publicPorts, ...cfg.publicPorts]));
  return (
    `ADMIN_USER=${shq(cfg.adminUser)} ` +
    `ADMIN_SSH_PUBKEY=${shq(cfg.sshPublicKey)} ` +
    `TIMEZONE=${shq(cfg.timezone)} ` +
    `SWAP_GB=${shq(String(cfg.swapSizeGb))} ` +
    `ADMIN_CIDRS=${shq(cfg.adminCidrs.join(" "))} ` +
    `WORKLOAD_PORTS=${shq(adminPorts.join(" "))} ` +
    `PUBLIC_PORTS=${shq(publicPorts.join(" "))}`
  );
}

/**
 * hardenEnvBase + the Tailscale auth key. ONLY for delivery over SSH (the
 * image-based post-harden path), where the command travels encrypted and is
 * stored as a Pulumi secret. Never use this in user_data.
 */
export function withTailscaleKey(base: string, cfg: ForgeConfig): pulumi.Output<string> {
  if (cfg.access === "tailscale" && cfg.tailscaleAuthKey) {
    return pulumi.interpolate`${base} TAILSCALE_AUTHKEY=${cfg.tailscaleAuthKey.apply(shq)}`;
  }
  return pulumi.output(base);
}

/**
 * Env for a secret-bearing workload installer (opencode). Delivered over SSH
 * post-boot — never via cloud-init. Secret inputs keep the result encrypted
 * in Pulumi state. The opencode-go API key is optional; if omitted the
 * installer writes a placeholder auth.json and the user adds the key manually.
 */
export function installEnv(cfg: ForgeConfig): pulumi.Output<string> {
  const key = cfg.opencodeApiKey ?? pulumi.output("");
  const pass = cfg.opencodePassword ?? pulumi.output("");
  return pulumi.all([key, pass]).apply(([k, p]) => {
    let env = `ADMIN_USER=${shq(cfg.adminUser)} ACCESS=${shq(cfg.access)} `;
    env +=
      `OPENCODE_API_KEY=${shq(k)} OPENCODE_PORT=${shq(String(cfg.opencodePort))} ` +
      `OPENCODE_SERVER_USERNAME=${shq(cfg.opencodeUsername)} OPENCODE_SERVER_PASSWORD=${shq(p)} ` +
      `OPENCODE_MODEL=${shq(cfg.opencodeModel)} `;
    return env;
  });
}

/**
 * Env for the dev-setup.sh post-install script. Secrets (Trello token/key) are
 * delivered over SSH and stored in Pulumi state encrypted.
 */
export function devSetupEnv(cfg: ForgeConfig): pulumi.Output<string> {
  const token = cfg.trelloToken ?? pulumi.output("");
  const key = cfg.trelloApiKey ?? pulumi.output("");
  return pulumi.all([token, key]).apply(([t, k]) => {
    let env = `ADMIN_USER=${shq(cfg.adminUser)} `;
    if (cfg.gitUserName) env += `GIT_USER_NAME=${shq(cfg.gitUserName)} `;
    if (cfg.gitUserEmail) env += `GIT_USER_EMAIL=${shq(cfg.gitUserEmail)} `;
    if (t) env += `TRELLO_TOKEN=${shq(t)} `;
    if (k) env += `TRELLO_API_KEY=${shq(k)} `;
    return env;
  });
}

/**
 * Build the cloud-init user_data for the from-scratch path: harden.sh on first
 * boot, plus the workload installer ONLY when it needs no secrets (e.g.
 * dokploy). Secret-bearing installers (opencode) and the Tailscale auth key
 * are delivered over SSH after boot instead — user_data must stay secret-free.
 */
export function buildCloudInit(
  cfg: ForgeConfig,
  w: WorkloadSpec,
  hardenScript: string,
): string {
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

  const installInCloudInit = w.install && !w.installNeedsSecrets;
  if (installInCloudInit) {
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
    `  - ${hardenEnvBase(cfg, w)} bash /opt/hetzner-forge/harden.sh 2>&1 | tee /var/log/hetzner-forge-harden.log`,
  );
  if (installInCloudInit) {
    parts.push(
      `  - ADMIN_USER=${shq(cfg.adminUser)} bash /opt/hetzner-forge/install-workload.sh 2>&1 | tee /var/log/hetzner-forge-install.log`,
    );
  }

  return parts.join("\n") + "\n";
}
