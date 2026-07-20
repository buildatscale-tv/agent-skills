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
  /** Ingress TCP ports to open (besides SSH). */
  ports: number[];
  /** Docs URL for the workload / install procedure. */
  docs: string;
  /** Human-facing hint about where the app lives once it's up. */
  ready: string;
}

// Built-in workloads. Verified against `hcloud image list --type app`:
//   - coolify, docker-ce  -> official images exist  (image + post-harden)
//   - dokploy             -> no image               (documented from-scratch)
const REGISTRY: Record<string, Omit<WorkloadSpec, "key">> = {
  base: {
    ports: [],
    docs: "",
    ready: "Plain hardened box — no workload installed.",
  },
  coolify: {
    hetznerImage: "coolify",
    ports: [80, 443, 8000],
    docs: "https://coolify.io/docs",
    ready:
      "Coolify dashboard at http://<ipv4>:8000 — create the admin account on first visit. " +
      "Deployed apps are served through Coolify's proxy on 80/443.",
  },
  docker: {
    hetznerImage: "docker-ce",
    ports: [],
    docs: "https://docs.docker.com/engine/",
    ready: "Docker Engine preinstalled. Open application ports with `extraPorts`.",
  },
  dokploy: {
    install: "curl -sSL https://dokploy.com/install.sh | sh",
    ports: [80, 443, 3000],
    docs: "https://docs.dokploy.com/docs/core/installation",
    ready: "Dokploy dashboard at http://<ipv4>:3000. Deployed apps are served on 80/443.",
  },
  // OpenCode server: `opencode serve` behind nginx basic-auth, run as a dedicated
  // non-sudo `opencode` user. Reached privately over an SSH tunnel (ports stays empty
  // — no public exposure). Install env (ADMIN_USER, OPENCODE_*) is injected by
  // buildCloudInit. See scripts/install-opencode.sh.
  opencode: {
    install: opencodeInstall,
    ports: [],
    docs: "https://opencode.ai/docs",
    ready:
      "OpenCode behind nginx basic-auth on :4096 (opencode itself on 127.0.0.1:4097, run as a " +
      "non-sudo user). Reach it via SSH tunnel: ssh -L 4096:localhost:4096 <adminUser>@<ipv4>, " +
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
      ports: cfg.customPorts,
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
