import * as pulumi from "@pulumi/pulumi";

export type AccessModel = "ssh" | "tailscale";

export interface ForgeConfig {
  name: string;
  location: string;
  serverType: string;
  baseImage: string;
  workload: string;
  access: AccessModel;

  adminUser: string;
  sshPublicKey: string;
  sshPrivateKeyPath: string;
  /** CIDRs allowed to reach SSH and admin ports. REQUIRED — there is no world-open default. */
  adminCidrs: string[];
  tailscaleAuthKey?: pulumi.Output<string>;
  timezone: string;

  /** Extra admin-scoped TCP ports (reachable only from adminCidrs). */
  extraPorts: number[];
  /** Explicitly world-open TCP ports (public web traffic). Registry workloads add their own. */
  publicPorts: number[];
  swapSizeGb: number;

  // Optional peripherals
  primaryIpv4: boolean;
  primaryIpDatacenter?: string;
  volumeSizeGb: number;
  privateNetwork: boolean;
  networkIpRange: string;

  // Custom workload (workload === "custom")
  customImage?: string;
  customInstall?: string;
  /** Admin-scoped ports for a custom workload (dashboards etc.). World-open ports go in publicPorts. */
  customPorts: number[];
  customDocs?: string;

  // OpenCode workload (workload === "opencode")
  opencodeApiKey?: pulumi.Output<string>;
  opencodeUsername: string;     // opencode web native auth username
  opencodePassword?: pulumi.Output<string>;
  opencodePort: number;
  opencodeModel: string;
}

function parsePorts(csv: string | undefined, key: string): number[] {
  if (!csv) return [];
  return csv
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
    .map((s) => {
      const n = parseInt(s, 10);
      if (isNaN(n) || n < 1 || n > 65535) {
        throw new Error(`Invalid port '${s}' in ${key} — must be an integer 1-65535.`);
      }
      return n;
    });
}

const V4_CIDR = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\/(\d{1,2})$/;
const V6_CIDR = /^[0-9a-fA-F:]+\/(\d{1,3})$/;

function parseCidrs(csv: string | undefined): string[] {
  if (!csv || !csv.trim()) {
    throw new Error(
      "adminCidrs is required — the box must not be open to the world. " +
        "Set a comma-separated list of your own CIDRs, e.g. " +
        "`pulumi config set adminCidrs \"$(curl -s https://api.ipify.org)/32\"`.",
    );
  }
  return csv
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
    .map((c) => {
      const v4 = V4_CIDR.exec(c);
      if (v4) {
        const octets = [v4[1], v4[2], v4[3], v4[4]].map(Number);
        const prefix = Number(v4[5]);
        if (octets.some((o) => o > 255) || prefix > 32) {
          throw new Error(`Invalid IPv4 CIDR '${c}' in adminCidrs.`);
        }
        return c;
      }
      const v6 = V6_CIDR.exec(c);
      if (v6 && Number(v6[1]) <= 128) {
        return c;
      }
      throw new Error(`Invalid CIDR '${c}' in adminCidrs — expected e.g. 203.0.113.7/32 or 2001:db8::1/128.`);
    });
}

export function loadConfig(): ForgeConfig {
  const c = new pulumi.Config();
  const access = (c.get("access") ?? "ssh") as AccessModel;
  if (access !== "ssh" && access !== "tailscale") {
    throw new Error(`Invalid access '${access}' — expected 'ssh' or 'tailscale'.`);
  }
  const workload = c.get("workload") ?? "base";

  return {
    name: c.get("name") ?? "forge",
    location: c.get("location") ?? "hil",
    serverType: c.get("serverType") ?? "cpx21",   // hil offers the cpxN1 line; cpx22 is EU-only
    baseImage: c.get("baseImage") ?? "ubuntu-24.04",
    workload,
    access,

    adminUser: c.get("adminUser") ?? "deploy",
    sshPublicKey: c.require("sshPublicKey"),
    sshPrivateKeyPath: c.get("sshPrivateKeyPath") ?? "~/.ssh/id_ed25519",
    adminCidrs: parseCidrs(c.get("adminCidrs")),
    tailscaleAuthKey: access === "tailscale" ? c.requireSecret("tailscaleAuthKey") : undefined,
    timezone: c.get("timezone") ?? "UTC",

    extraPorts: parsePorts(c.get("extraPorts"), "extraPorts"),
    publicPorts: parsePorts(c.get("publicPorts"), "publicPorts"),
    swapSizeGb: c.getNumber("swapSizeGb") ?? 0,

    primaryIpv4: c.getBoolean("primaryIpv4") ?? false,
    primaryIpDatacenter: c.get("primaryIpDatacenter"),
    volumeSizeGb: c.getNumber("volumeSizeGb") ?? 0,
    privateNetwork: c.getBoolean("privateNetwork") ?? false,
    networkIpRange: c.get("networkIpRange") ?? "10.10.0.0/16",

    customImage: c.get("customImage"),
    customInstall: c.get("customInstall"),
    customPorts: parsePorts(c.get("customPorts"), "customPorts"),
    customDocs: c.get("customDocs"),

    // The opencode-go API key is optional. By default, give it to the agent as a
    // Pulumi secret and it is delivered to the box over SSH (never via cloud-init).
    // Omit it for a higher-security, higher-friction flow where you add the key
    // manually over SSH after deploy. See profiles/opencode.md.
    opencodeApiKey: workload === "opencode" ? c.getSecret("opencodeApiKey") : undefined,
    opencodeUsername: c.get("opencodeUsername") ?? "opencode",
    opencodePassword: workload === "opencode" ? c.requireSecret("opencodePassword") : undefined,
    opencodePort: c.getNumber("opencodePort") ?? 4096,
    opencodeModel: c.get("opencodeModel") ?? "opencode-go/kimi-k3",
  };
}
