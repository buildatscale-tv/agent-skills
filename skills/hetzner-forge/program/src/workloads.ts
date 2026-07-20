import * as fs from "fs";
import * as path from "path";
import { ForgeConfig } from "./config";

const opencodeInstall = fs.readFileSync(
  path.join(__dirname, "..", "scripts", "install-opencode.sh"),
  "utf8",
);

export interface WorkloadSpec {
  key: string;
  /** Official Hetzner app image. When set, we boot the image and harden over SSH. */
  hetznerImage?: string;
  /** From-scratch installer (bash), run after hardening in cloud-init. Used when no image exists. */
  install?: string;
  /** True when the installer needs secrets delivered over SSH (runs post-boot, never in user_data). */
  installNeedsSecrets?: boolean;
  /** Admin TCP ports (dashboards, control UIs) — reachable only from adminCidrs. */
  adminPorts: number[];
  /** Public TCP ports (web traffic the platform serves) — open to the world. */
  publicPorts: number[];
  /** Docs URL for the workload / install procedure. */
  docs: string;
  /** Human-facing hint about where the app lives once it's up. */
  ready: string;
}

// Built-in workloads. Verified against `hcloud image list --type app`:
//   - coolify, docker-ce  -> official images exist  (image + post-harden)
//   - dokploy             -> no image               (documented from-scratch)
// Port rule: dashboards/control UIs are adminPorts (you-only); the HTTP(S)
// traffic a platform serves to its users is publicPorts (world).
const REGISTRY: Record<string, Omit<WorkloadSpec, "key">> = {
  base: {
    adminPorts: [],
    publicPorts: [],
    docs: "",
    ready: "Plain hardened box — no workload installed.",
  },
  coolify: {
    hetznerImage: "coolify",
    adminPorts: [8000],
    publicPorts: [80, 443],
    docs: "https://coolify.io/docs",
    ready:
      "Coolify dashboard at http://<ipv4>:8000 (reachable only from your admin CIDRs) — " +
      "create the admin account on first visit. Deployed apps are served publicly on 80/443.",
  },
  docker: {
    hetznerImage: "docker-ce",
    adminPorts: [],
    publicPorts: [],
    docs: "https://docs.docker.com/engine/",
    ready:
      "Docker Engine preinstalled. Open app ports with `extraPorts` (you-only) or " +
      "`publicPorts` (world).",
  },
  dokploy: {
    install: "curl -sSL https://dokploy.com/install.sh | sh",
    adminPorts: [3000],
    publicPorts: [80, 443],
    docs: "https://docs.dokploy.com/docs/core/installation",
    ready:
      "Dokploy dashboard at http://<ipv4>:3000 (reachable only from your admin CIDRs). " +
      "Deployed apps are served publicly on 80/443.",
  },
  // OpenCode server: `opencode web` with native password auth, run as a dedicated
  // non-sudo `opencode` user. Reached privately over an SSH tunnel — no ports opened
  // at all. The install needs secrets (API key, web password), so it runs post-boot
  // over SSH, never in user_data. See scripts/install-opencode.sh.
  opencode: {
    install: opencodeInstall,
    installNeedsSecrets: true,
    adminPorts: [],
    publicPorts: [],
    docs: "https://opencode.ai/docs",
    ready:
      "OpenCode server with native web auth on :4096 (run as a non-sudo user). " +
      "Reach it via SSH tunnel: ssh -L 4096:localhost:4096 <adminUser>@<ipv4>, " +
      "then http://localhost:4096 and log in.",
  },
};

export function resolveWorkload(cfg: ForgeConfig): WorkloadSpec {
  if (cfg.workload === "custom") {
    if (!cfg.customImage && !cfg.customInstall) {
      throw new Error(
        "workload=custom requires either `customImage` (an official provider image) or " +
          "`customInstall` (a documented install command). See profiles/from-scratch.md.",
      );
    }
    return {
      key: "custom",
      hetznerImage: cfg.customImage,
      // Prefer the image; only run a from-scratch install when there is no image.
      install: cfg.customImage ? undefined : cfg.customInstall,
      adminPorts: cfg.customPorts,
      publicPorts: [],
      docs: cfg.customDocs ?? "",
      ready: cfg.customImage
        ? `Custom image '${cfg.customImage}' booted. Check the provider docs for the app URL.`
        : "Custom workload installed from a documented procedure. Check the provider docs for the app URL.",
    };
  }

  const spec = REGISTRY[cfg.workload];
  if (!spec) {
    throw new Error(
      `Unknown workload '${cfg.workload}'. Built-in: ${Object.keys(REGISTRY).join(", ")}, custom. ` +
        "For a provider with no built-in entry, use workload=custom (see profiles/from-scratch.md).",
    );
  }
  return { key: cfg.workload, ...spec };
}

/** Image-based deploys (official app image) harden over SSH; others harden via cloud-init. */
export function isImageBased(w: WorkloadSpec): boolean {
  return !!w.hetznerImage;
}
