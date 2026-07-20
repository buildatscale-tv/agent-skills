import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import * as command from "@pulumi/command";

import { loadConfig } from "./src/config";
import { resolveWorkload, isImageBased } from "./src/workloads";
import {
  loadHardenScript,
  hardenEnvBase,
  withTailscaleKey,
  installEnv,
  buildCloudInit,
} from "./src/hardening";
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
// Port policy: SSH and admin ports are reachable ONLY from cfg.adminCidrs;
// public ports (web traffic a platform serves) are world-open. Nothing else
// ingresses. There is no world-open-by-default anywhere in this program.
const anywhere = ["0.0.0.0/0", "::/0"];
const adminPorts = Array.from(new Set([...workload.adminPorts, ...cfg.extraPorts]));
const publicPorts = Array.from(new Set([...workload.publicPorts, ...cfg.publicPorts]));

const rules: hcloud.types.input.FirewallRule[] = [
  { direction: "in", protocol: "tcp", port: "22", sourceIps: cfg.adminCidrs, description: "SSH (admin only)" },
  { direction: "in", protocol: "icmp", sourceIps: anywhere, description: "ICMP" },
];
for (const p of adminPorts) {
  rules.push({
    direction: "in",
    protocol: "tcp",
    port: String(p),
    sourceIps: cfg.adminCidrs,
    description: `admin:${p}`,
  });
}
for (const p of publicPorts) {
  rules.push({
    direction: "in",
    protocol: "tcp",
    port: String(p),
    sourceIps: anywhere,
    description: `public:${p}`,
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

// From-scratch bakes hardening (and any secret-free installer) into cloud-init;
// image-based boots the official image untouched and hardens over SSH below.
// user_data NEVER carries secrets — see hardening.ts.
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
    // Attached at creation — there is no window where the box runs unfirewalled.
    firewallIds: [toNum(firewall.id)],
    labels: { managed_by: "hetzner-forge", workload: workload.key },
  },
  { dependsOn: primaryIp ? [primaryIp] : [] },
);

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

// --- Post-boot SSH steps ---------------------------------------------------
// Everything secret-bearing (Tailscale auth key, opencode credentials) and the
// image-based hardening run over SSH — never in user_data.
//
// - Image path: connect as root (fresh image allows root key login), run
//   harden.sh, which locks root SSH only as its LAST step. An established
//   session survives the restart.
// - From-scratch post-boot: connect as the admin user. harden.sh creates that
//   user and enables UFW inside cloud-init, so we retry the SSH dial long
//   enough for first-boot package upgrades and hardening to finish. Once the
//   admin user exists and UFW is configured, the install proceeds.
const waitForCloudInit = "cloud-init status --wait >/dev/null 2>&1 || true; ";
const needsTailscaleUp = !imageBased && cfg.access === "tailscale";
const needsSecretInstall = !imageBased && !!workload.install && !!workload.installNeedsSecrets;

if (imageBased || needsTailscaleUp || needsSecretInstall) {
  const privateKey = fs.readFileSync(expandTilde(cfg.sshPrivateKeyPath), "utf8");

  // Long retry windows avoid false failures while cloud-init installs packages,
  // creates the admin user, and configures UFW. Default 10x15s is too short.
  const rootConnection: command.types.input.remote.ConnectionArgs = {
    host: server.ipv4Address,
    user: "root",
    privateKey,
    dialErrorLimit: 60,
    perDialTimeout: 15,
  };
  const adminConnection: command.types.input.remote.ConnectionArgs = {
    host: server.ipv4Address,
    user: cfg.adminUser,
    privateKey,
    dialErrorLimit: 180,
    perDialTimeout: 15,
  };

  // Image path: the official image does its own first-boot setup; harden over SSH.
  if (imageBased) {
    new command.remote.Command(
      `${cfg.name}-postharden`,
      {
        connection: rootConnection,
        create: pulumi.interpolate`${waitForCloudInit}${withTailscaleKey(hardenEnvBase(cfg, workload), cfg)} bash -s <<'FORGE_EOF'
${hardenScript}
FORGE_EOF`,
        triggers: [server.id],
      },
      { dependsOn: [server] },
    );
  }

  // From-scratch + Tailscale: cloud-init installed Tailscale without the key;
  // bring the mesh up now as the admin user, with the key travelling only over SSH.
  if (needsTailscaleUp && cfg.tailscaleAuthKey) {
    new command.remote.Command(
      `${cfg.name}-tailscale-up`,
      {
        connection: adminConnection,
        create: pulumi.interpolate`${waitForCloudInit}sudo tailscale up --ssh --authkey ${cfg.tailscaleAuthKey}`,
        triggers: [server.id],
      },
      { dependsOn: [server] },
    );
  }

  // Secret-bearing installer (opencode): env carries the secrets over SSH.
  // `sudo env ... bash -s` bypasses sudo's environment filtering and ensures the
  // install script sees the credentials without ever touching user_data.
  if (needsSecretInstall) {
    new command.remote.Command(
      `${cfg.name}-install`,
      {
        connection: adminConnection,
        create: pulumi.interpolate`${waitForCloudInit}sudo env ${installEnv(cfg)} bash -s <<'FORGE_EOF' 2>&1 | sudo tee /var/log/hetzner-forge-install.log
${workload.install}
FORGE_EOF`,
        triggers: [server.id],
      },
      { dependsOn: [server] },
    );
  }
}

// --- Outputs ---------------------------------------------------------------
const projectDir = process.cwd();
const fmtPorts = (ps: number[]) => (ps.length ? ps.join(", ") : "none");
const opencodeApiKeyStatus = cfg.opencodeApiKey
  ? pulumi.output("provided as Pulumi secret")
  : pulumi.output("NOT provided — add manually via SSH before using OpenCode");

export const serverId = server.id;
export const serverName = server.name;
export const ipv4 = server.ipv4Address;
export const ipv6 = server.ipv6Address;
export const status = server.status;
export const serverTypeOut = pulumi.output(cfg.serverType);
export const serverLocation = pulumi.output(cfg.location);
export const baseImage = pulumi.output(image);
export const adminUserOut = pulumi.output(cfg.adminUser);
export const adminCidrsOut = pulumi.output(cfg.adminCidrs).apply((cs) => cs.join(", "));
export const sshCommand = pulumi.interpolate`ssh ${cfg.adminUser}@${server.ipv4Address}`;
export const sshKeyName = sshKey.name;
export const sshKeyFingerprint = sshKey.fingerprint;
export const firewallName = firewall.name;
export const adminPortsOut = pulumi.output(fmtPorts(adminPorts));
export const publicPortsOut = pulumi.output(fmtPorts(publicPorts));
export const workloadKey = workload.key;
export const appHint = workload.ready;
export const opencodeUsername = pulumi.output(cfg.opencodeUsername);
export const opencodePort = pulumi.output(cfg.opencodePort);
export const opencodeModel = pulumi.output(cfg.opencodeModel);
export const opencodeApiKeyStatusOut = opencodeApiKeyStatus;
export const opencodePassword = cfg.opencodePassword;
export const webUrl = pulumi.interpolate`http://localhost:${cfg.opencodePort}`;
export const sshTunnelCommand = pulumi.interpolate`ssh -N -L ${cfg.opencodePort}:localhost:${cfg.opencodePort} ${cfg.adminUser}@${server.ipv4Address}`;

// Helper for the summary line about the password. Kept separate so the summary
// itself does not become a Pulumi secret and is readable by default.
const passwordHint = pulumi.output(
  "stored as a Pulumi secret — run `pulumi stack output opencodePassword --show-secrets`",
);

export const nextSteps = pulumi.interpolate`
Box '${cfg.name}' (${cfg.serverType} @ ${cfg.location}) is up.

  IPv4:  ${server.ipv4Address}
  SSH:   ssh ${cfg.adminUser}@${server.ipv4Address}
  Logs:  ssh ${cfg.adminUser}@${server.ipv4Address} 'sudo tail -n 100 /var/log/hetzner-forge-harden.log'

Workload (${workload.key}): ${workload.ready}

Exposure: SSH + admin ports (${fmtPorts(adminPorts)}) reachable only from your
admin CIDRs (${cfg.adminCidrs.join(", ")}); public ports (${fmtPorts(publicPorts)})
open to the world. Gated by the Hetzner Cloud Firewall, attached at creation.

Hardened with a non-root sudo user ('${cfg.adminUser}'), key-only SSH, root login
disabled, UFW default-deny, fail2ban, and unattended security upgrades.
`;

// A human-friendly markdown summary of the entire box. It is NOT a secret by
// default, so it is readable with `pulumi stack output summary`. The generated
// web password is emitted as a separate secret output and retrieved with
// `pulumi stack output opencodePassword --show-secrets`.
export const summary = pulumi.interpolate`
## Infrastructure Summary

| Attribute | Value |
|---|---|
| Server name | ${cfg.name} |
| Server ID | ${server.id} |
| Status | ${server.status} |
| Server type | ${cfg.serverType} |
| Location | ${cfg.location} |
| Base image | ${image} |
| Public IPv4 | ${server.ipv4Address} |
| Public IPv6 | ${server.ipv6Address} |

## Network and Firewall

| Direction | Protocol | Port | Source | Description |
|---|---|---|---|---|
| Inbound | TCP | 22 | ${cfg.adminCidrs.join(", ")} | SSH (admin only) |
| Inbound | ICMP | any | 0.0.0.0/0, ::/0 | ICMP |

Admin ports: ${fmtPorts(adminPorts)}
Public ports: ${fmtPorts(publicPorts)}

## SSH Key

| Name | Fingerprint |
|---|---|
| ${sshKey.name} | ${sshKey.fingerprint} |

## Users and Access

| User | UID/GID | Purpose | Sudo | SSH |
|---|---|---|---|---|
| root | 0/0 | System root | no | disabled |
| ${cfg.adminUser} | 1000/1000 | Admin human user | NOPASSWD | key-only |
| opencode | 1001/1001 | OpenCode service user | no | no direct SSH |

SSH hardening: Port 22, PermitRootLogin no, PasswordAuthentication no, PubkeyAuthentication yes, AllowUsers ${cfg.adminUser}.

## OpenCode

| Attribute | Value |
|---|---|
| Service user | opencode |
| Bind address | 127.0.0.1:${cfg.opencodePort} |
| Web UI (via tunnel) | http://localhost:${cfg.opencodePort} |
| Web username | ${cfg.opencodeUsername} |
| Web password | ${passwordHint} |
| Default model | ${cfg.opencodeModel} |
| API key status | ${opencodeApiKeyStatus} |

## Connecting

SSH to the box:
  ssh ${cfg.adminUser}@${server.ipv4Address}

OpenCode via SSH tunnel:
  ${sshTunnelCommand}
  (add -f to run it in the background: ssh -f -N -L ${cfg.opencodePort}:localhost:${cfg.opencodePort} ${cfg.adminUser}@${server.ipv4Address})
  Then open http://localhost:${cfg.opencodePort} and log in as ${cfg.opencodeUsername}.

From your phone use an SSH client like Termius/iSH with the same tunnel.

## Management

Project directory (state, passphrase, stack config):
  ${projectDir}

If your IP changes:
  pulumi config set adminCidrs <new-ip>/32 && pulumi up

Teardown:
  pulumi destroy --yes
`;
