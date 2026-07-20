import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import * as command from "@pulumi/command";

import { loadConfig } from "./src/config";
import { resolveWorkload, isImageBased } from "./src/workloads";
import { loadHardenScript, hardenEnv, buildCloudInit } from "./src/hardening";
import { networkZoneFor } from "./src/peripherals";

const cfg = loadConfig();
const workload = resolveWorkload(cfg);
const hardenScript = loadHardenScript();

const toNum = (id: pulumi.Output<string>) => id.apply((s) => parseInt(s, 10));
const expandTilde = (p: string) => (p.startsWith("~") ? path.join(os.homedir(), p.slice(1)) : p);

// --- SSH key ---------------------------------------------------------------
const sshKey = new hcloud.SshKey(`${cfg.name}-key`, {
  name: `${cfg.name}-key`,
  publicKey: cfg.sshPublicKey,
});

// --- Optional private network ---------------------------------------------
let network: hcloud.Network | undefined;
if (cfg.privateNetwork) {
  network = new hcloud.Network(`${cfg.name}-net`, {
    name: `${cfg.name}-net`,
    ipRange: cfg.networkIpRange,
  });
  new hcloud.NetworkSubnet(`${cfg.name}-subnet`, {
    networkId: toNum(network.id),
    type: "cloud",
    networkZone: networkZoneFor(cfg.location),
    ipRange: cfg.networkIpRange,
  });
}

// --- Optional primary IPv4 (survives server rebuilds) ----------------------
let primaryIp: hcloud.PrimaryIp | undefined;
if (cfg.primaryIpv4) {
  if (!cfg.primaryIpDatacenter) {
    throw new Error(
      "primaryIpv4=true requires `primaryIpDatacenter` (e.g. 'hil-dc1'). Run `hcloud datacenter list`.",
    );
  }
  primaryIp = new hcloud.PrimaryIp(`${cfg.name}-ipv4`, {
    name: `${cfg.name}-ipv4`,
    type: "ipv4",
    datacenter: cfg.primaryIpDatacenter,
    assigneeType: "server",
    autoDelete: false,
  });
}

// --- Hetzner Cloud Firewall (authoritative ingress gate) -------------------
const sshSources = cfg.sshSource === "0.0.0.0/0" ? ["0.0.0.0/0", "::/0"] : [cfg.sshSource];
const anywhere = ["0.0.0.0/0", "::/0"];
const openPorts = Array.from(new Set([...workload.ports, ...cfg.extraPorts]));

const rules: hcloud.types.input.FirewallRule[] = [
  { direction: "in", protocol: "tcp", port: "22", sourceIps: sshSources, description: "SSH" },
  { direction: "in", protocol: "icmp", sourceIps: anywhere, description: "ICMP" },
];
for (const p of openPorts) {
  rules.push({
    direction: "in",
    protocol: "tcp",
    port: String(p),
    sourceIps: anywhere,
    description: `workload:${p}`,
  });
}
if (cfg.access === "tailscale") {
  rules.push({
    direction: "in",
    protocol: "udp",
    port: "41641",
    sourceIps: anywhere,
    description: "Tailscale (WireGuard)",
  });
}

const firewall = new hcloud.Firewall(`${cfg.name}-fw`, { name: `${cfg.name}-fw`, rules });

// --- Server ----------------------------------------------------------------
const imageBased = isImageBased(workload);
const image = imageBased ? workload.hetznerImage! : cfg.baseImage;

// From-scratch bakes hardening + install into cloud-init; image-based boots the
// official image untouched and hardens over SSH afterwards (see below).
const userData = imageBased ? undefined : buildCloudInit(cfg, workload, hardenScript);

const publicNet: hcloud.types.input.ServerPublicNet = {
  ipv4Enabled: true,
  ipv6Enabled: true,
  ...(primaryIp ? { ipv4: toNum(primaryIp.id) } : {}),
};

const server = new hcloud.Server(
  cfg.name,
  {
    name: cfg.name,
    serverType: cfg.serverType,
    image,
    location: cfg.location,
    sshKeys: [sshKey.id],
    userData,
    publicNets: [publicNet],
    labels: { managed_by: "hetzner-forge", workload: workload.key },
  },
  { dependsOn: primaryIp ? [primaryIp] : [] },
);

// --- Attach firewall -------------------------------------------------------
const fwAttach = new hcloud.FirewallAttachment(`${cfg.name}-fw-attach`, {
  firewallId: toNum(firewall.id),
  serverIds: [toNum(server.id)],
});

// --- Attach to private network --------------------------------------------
if (network) {
  new hcloud.ServerNetwork(
    `${cfg.name}-net-attach`,
    { serverId: toNum(server.id), networkId: toNum(network.id) },
    { dependsOn: [server] },
  );
}

// --- Optional volume -------------------------------------------------------
if (cfg.volumeSizeGb > 0) {
  new hcloud.Volume(
    `${cfg.name}-vol`,
    {
      name: `${cfg.name}-vol`,
      size: cfg.volumeSizeGb,
      serverId: toNum(server.id),
      automount: true,
      format: "ext4",
    },
    { dependsOn: [server] },
  );
}

// --- Post-harden (image-based path only) -----------------------------------
// Official app images run their own first-boot setup, so we don't pass our own
// cloud-init. Instead we SSH in as root (Hetzner injected our key) once the box
// is up and run the same harden.sh.
if (imageBased) {
  const privateKey = fs.readFileSync(expandTilde(cfg.sshPrivateKeyPath), "utf8");
  new command.remote.Command(
    `${cfg.name}-postharden`,
    {
      connection: { host: server.ipv4Address, user: "root", privateKey },
      create: pulumi.interpolate`${hardenEnv(cfg, workload)} bash -s <<'FORGE_EOF'
${hardenScript}
FORGE_EOF`,
      triggers: [server.id],
    },
    { dependsOn: [server, fwAttach] },
  );
}

// --- Outputs ---------------------------------------------------------------
export const serverId = server.id;
export const ipv4 = server.ipv4Address;
export const ipv6 = server.ipv6Address;
export const status = server.status;
export const sshCommand = pulumi.interpolate`ssh ${cfg.adminUser}@${server.ipv4Address}`;
export const workloadKey = workload.key;
export const appHint = workload.ready;
export const nextSteps = pulumi.interpolate`
Box '${cfg.name}' (${cfg.serverType} @ ${cfg.location}) is up.

  IPv4:  ${server.ipv4Address}
  SSH:   ssh ${cfg.adminUser}@${server.ipv4Address}
  Logs:  ssh ${cfg.adminUser}@${server.ipv4Address} 'sudo tail -n 100 /var/log/hetzner-forge-harden.log'

Workload (${workload.key}): ${workload.ready}

Hardened with a non-root sudo user ('${cfg.adminUser}'), key-only SSH, root login
prohibit-password, UFW default-deny, fail2ban, and unattended security upgrades.
Ingress is gated by the Hetzner Cloud Firewall.
`;
