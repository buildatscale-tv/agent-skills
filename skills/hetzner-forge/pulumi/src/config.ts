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
  sshSource: string;
  tailscaleAuthKey?: pulumi.Output<string>;
  timezone: string;

  extraPorts: number[];
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
  customPorts: number[];
  customDocs?: string;

  // OpenCode workload (workload === "opencode")
  opencodeApiKey?: pulumi.Output<string>;
  opencodeUser: string;          // nginx basic-auth web login username
  opencodePassword?: pulumi.Output<string>;
  opencodePort: number;
  opencodeModel: string;
}

function parsePorts(csv: string | undefined): number[] {
  if (!csv) return [];
  return csv
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
    .map((s) => {
      const n = parseInt(s, 10);
      if (isNaN(n) || n < 1 || n > 65535) {
        throw new Error(`Invalid port '${s}' — must be an integer 1-65535.`);
      }
      return n;
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
    sshSource: c.get("sshSource") ?? "0.0.0.0/0",
    tailscaleAuthKey: access === "tailscale" ? c.requireSecret("tailscaleAuthKey") : undefined,
    timezone: c.get("timezone") ?? "UTC",

    extraPorts: parsePorts(c.get("extraPorts")),
    swapSizeGb: c.getNumber("swapSizeGb") ?? 0,

    primaryIpv4: c.getBoolean("primaryIpv4") ?? false,
    primaryIpDatacenter: c.get("primaryIpDatacenter"),
    volumeSizeGb: c.getNumber("volumeSizeGb") ?? 0,
    privateNetwork: c.getBoolean("privateNetwork") ?? false,
    networkIpRange: c.get("networkIpRange") ?? "10.10.0.0/16",

    customImage: c.get("customImage"),
    customInstall: c.get("customInstall"),
    customPorts: parsePorts(c.get("customPorts")),
    customDocs: c.get("customDocs"),

    opencodeApiKey: workload === "opencode" ? c.requireSecret("opencodeApiKey") : undefined,
    opencodeUser: c.get("opencodeUser") ?? "opencode",
    opencodePassword: workload === "opencode" ? c.requireSecret("opencodePassword") : undefined,
    opencodePort: c.getNumber("opencodePort") ?? 4096,
    opencodeModel: c.get("opencodeModel") ?? "opencode-go/kimi-k3",
  };
}
